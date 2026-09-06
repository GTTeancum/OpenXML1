#define NOMINMAX
#include "compiled_session.h"
#include "fmac.h"
#include "transfer_timeline.h"
#include "ee/MA_VU.h"
#include "ee/VuExecutor.h"
#include <algorithm>
#include <cfenv>
#include <cstring>
#include <stdexcept>
#include <xmmintrin.h>

namespace
{
class FloatingPointScope
{
public:
    FloatingPointScope() : csr(_mm_getcsr())
    {
        if (std::feholdexcept(&saved)) throw std::runtime_error("Cannot preserve floating-point environment");
        if (std::fesetround(FE_TOWARDZERO))
        {
            std::fesetenv(&saved);
            _mm_setcsr(csr);
            throw std::runtime_error("Cannot set VU floating-point rounding");
        }
        _mm_setcsr(_mm_getcsr() | 0x8040u); // Flush-to-zero and denormals-are-zero.
    }
    ~FloatingPointScope() { std::fesetenv(&saved); _mm_setcsr(csr); }
private:
    std::fenv_t saved{};
    unsigned csr;
};
}

struct CompiledVuSession::Impl
{
    alignas(16) std::array<uint8_t, 16384> code{}, data{};
    CMIPS cpu{MEMORYMAP_ENDIAN_LSBF};
    CMA_VU architecture{16383};
    CVuExecutor executor{cpu, 16384};
    TransferTimeline timeline{data.data()};
    ScalarFlags scalarFlags;
    bool codeLoaded = false;
    uint32_t top = 0, itop = 0;
    std::string error;

    Impl()
    {
        cpu.m_vuFmacCompiler = selectFmac;
        cpu.m_pMemoryMap->InsertReadMap(0, 16383, data.data(), 0);
        cpu.m_pMemoryMap->InsertWriteMap(0, 16383, data.data(), 0);
        cpu.m_pMemoryMap->InsertInstructionMap(0, 16383, code.data(), 1);
        cpu.m_pArch = &architecture;
        cpu.m_pAddrTranslator = CMIPS::TranslateAddress64;
        cpu.m_vuMem = data.data();
        cpu.m_pMemoryMap->InsertReadMap(0x8400, 0x8423, [this](uint32 address, uint32) {
            if (address == 0x8400) return top;
            if (address == 0x8420) return itop;
            error = "Unsupported VU peripheral read";
            return 0u;
        }, 1);
        cpu.m_pMemoryMap->InsertWriteMap(0x8400, 0x8423, [this](uint32 address, uint32) {
            // The timestamped observer stages PATH1; the legacy callback must not submit it twice.
            if (address != 0x8410) error = "Unsupported VU peripheral write";
            return 0u;
        }, 1);
        cpu.m_vuMemoryObserver = [this](CMIPS *context, uint32, uint32 cycle, uint32 phase) {
            if (!error.empty()) return;
            try
            {
                if (phase == 2) timeline.kick(context->m_State.xgkickAddress, cycle);
                else timeline.advance(cycle);
            }
            catch (const std::exception &e) { error = e.what(); }
        };
        cpu.m_vuXgkickWait = [this](CMIPS *, uint32, uint32 cycle) {
            if (!error.empty()) return 0u;
            try
            {
                timeline.finish(cycle);
                return static_cast<uint32>(timeline.time - cycle);
            }
            catch (const std::exception &e) { error = e.what(); return 0u; }
        };
        cpu.m_vuStatusObserver = [this](CMIPS *context, uint32 opcode, uint32 cycle, uint32 value) {
            if (!error.empty()) return value;
            try { return scalarFlags.observe(context, opcode, cycle, value); }
            catch (const std::exception &e) { error = e.what(); return value; }
        };
    }
};

CompiledVuSession::CompiledVuSession() : impl(std::make_unique<Impl>()) {}
CompiledVuSession::~CompiledVuSession() = default;

uint64_t compiledVuDrainCycle(const MIPSSTATE &s, uint64_t transferEnd)
{
    uint64_t end = std::max<uint64_t>(s.pipeTime, transferEnd);
    end = std::max<uint64_t>(end, std::max(s.pipeQ.counter, s.pipeP.counter));
    for (const auto *pipe : {&s.pipeMac, &s.pipeSticky, &s.pipeClip})
        for (const auto ready : pipe->pipeTimes) end = std::max<uint64_t>(end, ready);
    for (unsigned remaining = 0; remaining < 3; ++remaining)
        for (const auto mask : s.pipeFmacWrite[remaining].nV)
            if (mask) end = std::max<uint64_t>(end, uint64_t(s.pipeTime) + remaining + 1);
    if (end - s.pipeTime > 1048576) throw std::runtime_error("VU drain exceeds diagnostic cycle limit");
    return end;
}

CompiledVuSession::Result CompiledVuSession::run(const std::array<uint8_t, 16384> &code,
    const std::array<uint8_t, 16384> &data, const MIPSSTATE &state, uint32_t budget,
    uint32_t top, uint32_t itop, const ScalarFlags::State *scalarState)
{
    Result result;
    if (budget <= 64 || budget > 1048576 || state.pipeTime || state.nHasException ||
        state.nPC >= 16384 || (state.nPC & 7))
    {
        result.reason = "Unsupported compiled drain entry";
        return result;
    }
    try
    {
        FloatingPointScope floatingPoint;
        auto &vm = *impl;
        if (!vm.codeLoaded || vm.code != code)
        {
            vm.executor.Reset();
            vm.code = code;
            vm.codeLoaded = true;
        }
        vm.data = data;
        vm.cpu.m_State = state;
        vm.top = top;
        vm.itop = itop;
        vm.error.clear();
        vm.timeline.reset();
        ScalarFlags::State initialScalar{};
        initialScalar.status = state.nCOP2DF ? 0x20 : 0;
        vm.scalarFlags.reset(scalarState ? *scalarState : initialScalar);
        vm.executor.Execute(static_cast<int>(budget * 2));
        if (!vm.error.empty()) throw std::runtime_error(vm.error);
        if (vm.cpu.m_State.nHasException != MIPS_EXCEPTION_VU_EBIT)
            throw std::runtime_error("Compiled drain did not reach E-bit termination");
        vm.timeline.finish(vm.cpu.m_State.pipeTime);
        const auto scalarEnd = vm.scalarFlags.deadline();
        const auto drainedCycle = std::max(compiledVuDrainCycle(vm.cpu.m_State, vm.timeline.time), scalarEnd);
        if (drainedCycle > budget) throw std::runtime_error("Compiled drain exceeded elapsed-cycle budget");
        result.state = vm.cpu.m_State;
        result.data = vm.data;
        result.packets = vm.timeline.packets;
        result.completionCycles = vm.timeline.completionCycles;
        result.transferEnd = vm.timeline.time;
        result.drainedCycle = drainedCycle;
        result.scalarStatus = vm.scalarFlags.finish(drainedCycle);
        result.scalarEnd = scalarEnd;
        result.scalarFlagsValid = true;
        result.executed = true;
    }
    catch (const std::exception &e)
    {
        result = {};
        result.reason = e.what();
        impl->executor.Reset();
        impl->codeLoaded = false;
    }
    return result;
}
