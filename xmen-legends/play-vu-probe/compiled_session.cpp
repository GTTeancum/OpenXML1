#define NOMINMAX
#include "compiled_session.h"
#include "efu_math.h"
#include "fmac.h"
#include "fmac_emitter.h"
#include "transfer_timeline.h"
#include "ee/MA_VU.h"
#include "ee/VuExecutor.h"
#include <algorithm>
#include <bitset>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <xmmintrin.h>

namespace
{
class UnsupportedEfu : public std::runtime_error
{
public:
    UnsupportedEfu() : std::runtime_error("EFU arithmetic remains on the reference engine") {}
};

class GuardedVuExecutor : public CVuExecutor
{
public:
    using CVuExecutor::CVuExecutor;
    CompiledVuSession::CacheStatistics statistics;
    bool boundedCache = false;
    void Reset() override
    {
        CVuExecutor::Reset();
        statistics.bytes = statistics.blocks = 0;
        ++statistics.clears;
    }
    void invalidate(bool retain)
    {
        if (retain) ClearActiveBlocksInRange(0, 16384, false);
        else Reset();
    }
protected:
    BasicBlockPtr BlockFactory(CMIPS &cpu, uint32 begin, uint32 end) override
    {
        for (uint32 pc = begin; pc <= end; pc += 8)
        {
            const auto lower = cpu.m_pMemoryMap->GetInstruction(pc);
            const auto upper = cpu.m_pMemoryMap->GetInstruction(pc + 4);
            const auto function = (lower & 3) | ((lower >> 4) & 0x7c);
            if (!cpu.m_vuEfuObserver && !(upper & 0x80000000u) &&
                (lower >> 25) == 0x40 && (lower & 63) >= 0x3c &&
                function >= 0x70 && function <= 0x7d && function != 0x7b)
                throw UnsupportedEfu();
        }
        const auto before = m_cachedBlocks.size();
        auto block = CVuExecutor::BlockFactory(cpu, begin, end);
        if (m_cachedBlocks.size() != before)
        {
            ++statistics.compiled;
            statistics.bytes += block->GetCompiledSize();
        }
        else ++statistics.hits;
        statistics.blocks = m_cachedBlocks.size();
        if (boundedCache && (statistics.blocks > CompiledVuSession::cacheBlockLimit ||
            statistics.bytes > CompiledVuSession::cacheByteLimit))
            throw std::runtime_error("Compiled VU code cache capacity exceeded");
        return block;
    }
};

class FloatingPointScope
{
public:
    FloatingPointScope() noexcept : csr(_mm_getcsr())
    {
        // Play's x64 VU JIT emits SSE operations. Avoid the much more expensive
        // process-wide C fenv calls on every short stream slice.
        constexpr unsigned kExceptionFlags = 0x003Fu;
        constexpr unsigned kExceptionMasks = 0x1F80u;
        constexpr unsigned kRoundingMode = 0x6000u;
        constexpr unsigned kFlushModes = 0x8040u;
        _mm_setcsr((csr & ~(kExceptionFlags | kRoundingMode)) |
                   kExceptionMasks | kRoundingMode | kFlushModes);
    }
    ~FloatingPointScope() { _mm_setcsr(csr); }
private:
    unsigned csr;
};

class EfuTimeline
{
public:
    void reset(uint32_t initial)
    {
        current = initial;
        resourceReady = time = 0;
        pending.clear();
    }

    uint32_t observe(CMIPS *context, uint32_t opcode, uint32_t cycle, uint32_t event)
    {
        if (cycle < time) throw std::runtime_error("EFU observer time moved backwards");
        advance(cycle);
        if (event == 0)
        {
            if (cycle < resourceReady) throw std::runtime_error("EFU issued before its resource was available");
            std::array<uint32_t, 4> source{};
            const auto fs = (opcode >> 11) & 31;
            std::copy(std::begin(context->m_State.nCOP2[fs].nV),
                std::end(context->m_State.nCOP2[fs].nV), source.begin());
            const auto function = (opcode & 3) | ((opcode >> 4) & 0x7c);
            const auto result = CompiledEfu::evaluateRuntimeFused(
                function, (opcode >> 21) & 3, source);
            const uint32_t ready = cycle + result.latency;
            pending.push_back({ready, result.bits});
            resourceReady = ready - 1;
            return 0;
        }

        uint32_t target = cycle;
        if (event == 2) target = std::max(target, resourceReady);
        else if (event == 3 && !pending.empty()) target = std::max(target, pending.back().ready);
        else if (event != 1) throw std::runtime_error("Invalid EFU observer event");
        advance(target);
        context->m_State.nCOP2P = current;
        return target - cycle;
    }

    uint32_t finish(uint32_t cycle)
    {
        if (!pending.empty()) cycle = std::max(cycle, pending.back().ready);
        advance(cycle);
        return current;
    }

    uint32_t deadline() const { return pending.empty() ? time : pending.back().ready; }

private:
    struct Pending { uint32_t ready, bits; };
    void advance(uint32_t cycle)
    {
        while (!pending.empty() && pending.front().ready <= cycle)
        {
            current = pending.front().bits;
            pending.pop_front();
        }
        time = cycle;
    }

    std::deque<Pending> pending;
    uint32_t current = 0, resourceReady = 0, time = 0;
};
}

struct CompiledVuSession::Impl
{
    alignas(16) std::array<uint8_t, 16384> code{}, data{};
    CMIPS cpu{MEMORYMAP_ENDIAN_LSBF};
    CMA_VU architecture{16383};
    GuardedVuExecutor executor{cpu, 16384};
    TransferTimeline timeline{data.data()};
    EfuTimeline efuTimeline;
    ScalarFlags scalarFlags;
    bool codeLoaded = false;
    std::optional<uint64_t> codeGeneration;
    std::bitset<2048> referenceEntries;
    uint32_t top = 0, itop = 0;
    std::string error;
    uint64_t directInstructions = 0;
    bool retainBlocks = false;
    bool efuEnabled = false;
    bool streamActive = false;
    bool streamEnded = false;
    bool streamTraceBlocks = false;
    uint8_t *streamData = nullptr;
    uint32_t streamEntry = 0;
    std::vector<uint64_t> streamBlockEnds;
    std::vector<uint32_t> streamBlockPcs;
    std::vector<uint32_t> streamBlockStatePcs;

    explicit Impl(Arithmetic arithmetic, Emission emission, Cache cache)
    {
        const char *cacheValue = std::getenv("PS2X_VU_RETAIN_BLOCK_CACHE");
        retainBlocks = cache == Cache::Retain || (cache == Cache::Environment &&
            cacheValue && !std::strcmp(cacheValue, "1"));
        const char *efuValue = std::getenv("PS2X_VU_COMPILED_EFU");
        efuEnabled = efuValue && !std::strcmp(efuValue, "1");
        executor.boundedCache = retainBlocks;
        // Play's lookup storage requires initialization before range invalidation.
        executor.Reset();
        executor.statistics = {};
        cpu.m_vuFmacCompiler = arithmetic == Arithmetic::RuntimeFused ? selectFmacRuntimeFused : selectFmac;
        if (emission == Emission::Direct || (emission == Emission::Environment && std::getenv("PS2X_VU_DIRECT_FMAC")))
            cpu.m_vuFmacEmitter = [this](CMIPS *context, CMipsJitter *jitter, uint32 opcode, uint32 cycle, uint32 hints) {
                if (!emitDirectFmac(context, jitter, opcode, cycle, hints)) return false;
                ++directInstructions;
                return true;
            };
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
        cpu.m_vuMemoryObserver = [this](CMIPS *context, uint32 pc, uint32 cycle, uint32 phase) {
            if (!error.empty()) return;
            try
            {
                if (streamActive && streamTraceBlocks && phase == 3)
                {
                    streamBlockEnds.push_back(cycle);
                    streamBlockPcs.push_back(pc);
                    streamBlockStatePcs.push_back(context->m_State.nPC);
                }
                if (phase == 2) timeline.kick(context->m_State.xgkickAddress, cycle);
                else timeline.advance(cycle);
            }
            catch (const std::exception &e) { error = e.what(); }
        };
        cpu.m_vuObserveBlockEnds = false;
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
        if (efuEnabled)
            cpu.m_vuEfuObserver = [this](CMIPS *context, uint32 opcode, uint32 cycle, uint32 event) {
                if (!error.empty()) return 0u;
                try { return efuTimeline.observe(context, opcode, cycle, event); }
                catch (const std::exception &e) { error = e.what(); return 0u; }
            };
    }
};

CompiledVuSession::CompiledVuSession(Arithmetic arithmetic, Emission emission, Cache cache)
    : impl(std::make_unique<Impl>(arithmetic, emission, cache)) {}
CompiledVuSession::~CompiledVuSession() = default;
uint64_t CompiledVuSession::directInstructionsCompiled() const { return impl->directInstructions; }
CompiledVuSession::CacheStatistics CompiledVuSession::cacheStatistics() const { return impl->executor.statistics; }

void CompiledVuSession::setStreamMaximumBlockSize(uint32_t bytes)
{
    if (impl->streamActive) throw std::runtime_error("Cannot change compiled VU block size while a stream is active");
    if (bytes < 8 || bytes > impl->executor.MAX_BLOCK_SIZE || (bytes & 7))
        throw std::runtime_error("Invalid compiled VU stream block size");
    impl->executor.SetMaximumBlockSize(bytes);
}

uint64_t compiledVuDrainCycle(const MIPSSTATE &s, uint64_t transferEnd)
{
    uint64_t end = std::max<uint64_t>(s.pipeTime, transferEnd);
    end = std::max<uint64_t>(end, s.pipeLsuEnd);
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
        if (vm.streamActive) throw std::runtime_error("Compiled VU stream is active");
        vm.cpu.m_vuMem = vm.data.data();
        vm.timeline.setMemory(vm.data.data());
        vm.executor.SetMaximumBlockSize(vm.executor.MAX_BLOCK_SIZE);
        if (!vm.codeLoaded || vm.code != code)
        {
            vm.executor.invalidate(vm.retainBlocks);
            ++vm.executor.statistics.codeChanges;
            vm.code = code;
            vm.codeLoaded = true;
            vm.referenceEntries.reset();
        }
        if (vm.referenceEntries.test(state.nPC / 8))
        {
            result.reason = "EFU arithmetic remains on the reference engine";
            return result;
        }
        vm.data = data;
        vm.cpu.m_State = state;
        vm.top = top;
        vm.itop = itop;
        vm.error.clear();
        vm.timeline.reset();
        vm.efuTimeline.reset(state.nCOP2P);
        ScalarFlags::State initialScalar{};
        initialScalar.status = state.nCOP2DF ? 0x20 : 0;
        vm.scalarFlags.reset(scalarState ? *scalarState : initialScalar);
        vm.executor.Execute(static_cast<int>(budget * 2));
        if (!vm.error.empty()) throw std::runtime_error(vm.error);
        if (vm.cpu.m_State.nHasException != MIPS_EXCEPTION_VU_EBIT)
            throw std::runtime_error("Compiled drain did not reach E-bit termination");
        vm.timeline.finish(vm.cpu.m_State.pipeTime);
        const auto scalarEnd = vm.scalarFlags.deadline();
        const auto efuEnd = vm.efuTimeline.deadline();
        const auto drainedCycle = std::max({compiledVuDrainCycle(vm.cpu.m_State, vm.timeline.time),
            scalarEnd, static_cast<uint64_t>(efuEnd)});
        if (drainedCycle > budget) throw std::runtime_error("Compiled drain exceeded elapsed-cycle budget");
        if (efuEnd)
        {
            vm.cpu.m_State.nCOP2P = vm.efuTimeline.finish(static_cast<uint32_t>(drainedCycle));
            vm.cpu.m_State.pipeP = {0, vm.cpu.m_State.nCOP2P};
        }
        result.state = vm.cpu.m_State;
        result.data = vm.data;
        result.packets = std::move(vm.timeline.packets);
        result.completionCycles = std::move(vm.timeline.completionCycles);
        result.transferEnd = vm.timeline.time;
        result.drainedCycle = drainedCycle;
        result.scalarStatus = vm.scalarFlags.finish(drainedCycle);
        result.scalarEnd = scalarEnd;
        result.efuEnd = efuEnd;
        result.scalarFlagsValid = true;
        result.executed = true;
    }
    catch (const UnsupportedEfu &e)
    {
        result = {};
        result.reason = e.what();
        impl->referenceEntries.set(state.nPC / 8);
        impl->executor.invalidate(impl->retainBlocks);
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

bool CompiledVuSession::beginStream(const std::array<uint8_t, 16384> &code,
    const std::array<uint8_t, 16384> &data, const MIPSSTATE &state,
    uint32_t top, uint32_t itop, const ScalarFlags::State *scalarState,
    std::string *reason)
{
    return beginStreamInternal(code, &data, nullptr, state, top, itop, scalarState, reason,
        std::nullopt);
}

bool CompiledVuSession::beginStreamLive(const std::array<uint8_t, 16384> &code,
    uint8_t *data, size_t dataSize, const MIPSSTATE &state,
    uint32_t top, uint32_t itop, const ScalarFlags::State *scalarState,
    std::string *reason, std::optional<uint64_t> codeGeneration)
{
    if (!data || dataSize != 16384)
    {
        if (reason) *reason = "Unsupported live VU memory shape";
        return false;
    }
    return beginStreamInternal(code, nullptr, data, state, top, itop, scalarState, reason,
        codeGeneration);
}

bool CompiledVuSession::beginStreamInternal(const std::array<uint8_t, 16384> &code,
    const std::array<uint8_t, 16384> *ownedData, uint8_t *liveData,
    const MIPSSTATE &state, uint32_t top, uint32_t itop,
    const ScalarFlags::State *scalarState, std::string *reason,
    std::optional<uint64_t> codeGeneration)
{
    if (reason) reason->clear();
    auto reject = [&](const char *message) {
        if (reason) *reason = message;
        return false;
    };
    auto &vm = *impl;
    if (vm.streamActive) return reject("Compiled VU stream is already active");
    if (state.pipeTime || state.nHasException || state.nPC >= 16384 || (state.nPC & 7))
        return reject("Unsupported compiled stream entry");
    try
    {
        FloatingPointScope floatingPoint;
        const bool codeChanged = codeGeneration ?
            (!vm.codeLoaded || vm.codeGeneration != codeGeneration) :
            (!vm.codeLoaded || vm.code != code);
        if (codeChanged)
        {
            vm.executor.invalidate(vm.retainBlocks);
            ++vm.executor.statistics.codeChanges;
            vm.code = code;
            vm.codeLoaded = true;
            vm.referenceEntries.reset();
        }
        vm.codeGeneration = codeGeneration;
        if (vm.referenceEntries.test(state.nPC / 8))
            return reject("EFU arithmetic remains on the reference engine");
        if (ownedData) vm.data = *ownedData;
        vm.streamData = liveData ? liveData : vm.data.data();
        vm.cpu.m_vuMem = vm.streamData;
        vm.timeline.setMemory(vm.streamData);
        vm.cpu.m_State = state;
        vm.top = top;
        vm.itop = itop;
        vm.error.clear();
        vm.timeline.reset();
        vm.efuTimeline.reset(state.nCOP2P);
        ScalarFlags::State initialScalar{};
        initialScalar.status = state.nCOP2DF ? 0x20 : 0;
        vm.scalarFlags.reset(scalarState ? *scalarState : initialScalar);
        vm.streamActive = true;
        vm.streamEnded = false;
        vm.streamEntry = state.nPC;
        return true;
    }
    catch (const std::exception &e)
    {
        vm.executor.Reset();
        vm.codeLoaded = false;
        vm.streamActive = false;
        vm.streamEnded = false;
        vm.streamData = nullptr;
        vm.cpu.m_vuMem = vm.data.data();
        vm.timeline.setMemory(vm.data.data());
        return reject(e.what());
    }
}

void CompiledVuSession::setStreamRegisters(uint32_t top, uint32_t itop)
{
    if (!impl->streamActive) throw std::runtime_error("Compiled VU stream is not active");
    impl->top = top;
    impl->itop = itop;
}

CompiledVuSession::StreamSlice CompiledVuSession::runStreamSlice(
    uint32_t budget, bool collectBlockTrace)
{
    StreamSlice slice;
    auto &vm = *impl;
    if (!vm.streamActive)
    {
        slice.reason = "Compiled VU stream is not active";
        return slice;
    }
    if (vm.streamEnded)
    {
        slice.reason = "Compiled VU stream has ended";
        return slice;
    }
    if (!budget || budget > 1048576)
    {
        slice.reason = "Invalid compiled VU stream budget";
        return slice;
    }
    slice.beginCycle = vm.cpu.m_State.pipeTime;
    slice.beginPc = vm.cpu.m_State.nPC;
    vm.streamBlockEnds.clear();
    vm.streamBlockPcs.clear();
    vm.streamBlockStatePcs.clear();
    vm.streamTraceBlocks = collectBlockTrace;
    try
    {
        FloatingPointScope floatingPoint;
        slice.quotaRemaining = vm.executor.Execute(static_cast<int>(budget * 2));
        if (!vm.error.empty()) throw std::runtime_error(vm.error);
        const uint32_t exception = vm.cpu.m_State.nHasException;
        if (exception != MIPS_EXCEPTION_NONE && exception != MIPS_EXCEPTION_VU_EBIT)
            throw std::runtime_error("Compiled VU stream stopped on an unsupported exception");
        slice.endCycle = vm.cpu.m_State.pipeTime;
        slice.endPc = vm.cpu.m_State.nPC;
        if (collectBlockTrace)
        {
            slice.blockEnds = vm.streamBlockEnds;
            slice.blockPcs = vm.streamBlockPcs;
            slice.blockStatePcs = vm.streamBlockStatePcs;
        }
        if (slice.endCycle <= slice.beginCycle)
            throw std::runtime_error("Compiled VU stream made no progress");
        vm.timeline.advance(slice.endCycle);
        slice.packets = std::move(vm.timeline.packets);
        slice.completionCycles = std::move(vm.timeline.completionCycles);
        vm.timeline.packets.clear();
        vm.timeline.completionCycles.clear();
        slice.advanced = true;
        slice.ended = exception == MIPS_EXCEPTION_VU_EBIT;
        vm.streamEnded = slice.ended;
    }
    catch (const UnsupportedEfu &e)
    {
        slice = {};
        slice.reason = e.what();
        vm.referenceEntries.set(vm.streamEntry / 8);
        vm.executor.invalidate(vm.retainBlocks);
        vm.streamActive = false;
    }
    catch (const std::exception &e)
    {
        slice = {};
        slice.reason = e.what();
        vm.executor.Reset();
        vm.codeLoaded = false;
        vm.streamActive = false;
    }
    vm.streamTraceBlocks = false;
    return slice;
}

CompiledVuSession::Result CompiledVuSession::finishStream()
{
    Result result;
    auto &vm = *impl;
    if (!vm.streamActive || !vm.streamEnded)
    {
        result.reason = "Compiled VU stream has not ended";
        return result;
    }
    try
    {
        FloatingPointScope floatingPoint;
        vm.timeline.finish(vm.cpu.m_State.pipeTime);
        const auto scalarEnd = vm.scalarFlags.deadline();
        const auto efuEnd = vm.efuTimeline.deadline();
        const auto drainedCycle = std::max({compiledVuDrainCycle(vm.cpu.m_State, vm.timeline.time),
            scalarEnd, static_cast<uint64_t>(efuEnd)});
        if (efuEnd)
        {
            vm.cpu.m_State.nCOP2P = vm.efuTimeline.finish(static_cast<uint32_t>(drainedCycle));
            vm.cpu.m_State.pipeP = {0, vm.cpu.m_State.nCOP2P};
        }
        result.state = vm.cpu.m_State;
        result.dataIsLive = vm.streamData != vm.data.data();
        if (!result.dataIsLive)
            std::memcpy(result.data.data(), vm.streamData, result.data.size());
        result.packets = std::move(vm.timeline.packets);
        result.completionCycles = std::move(vm.timeline.completionCycles);
        result.transferEnd = vm.timeline.time;
        result.drainedCycle = drainedCycle;
        result.scalarStatus = vm.scalarFlags.finish(drainedCycle);
        result.scalarEnd = scalarEnd;
        result.efuEnd = efuEnd;
        result.scalarFlagsValid = true;
        result.executed = true;
    }
    catch (const std::exception &e)
    {
        result = {};
        result.reason = e.what();
        vm.executor.Reset();
        vm.codeLoaded = false;
    }
    vm.streamActive = false;
    vm.streamEnded = false;
    vm.streamData = nullptr;
    vm.cpu.m_vuMem = vm.data.data();
    vm.timeline.setMemory(vm.data.data());
    return result;
}

void CompiledVuSession::cancelStream()
{
    impl->streamActive = false;
    impl->streamEnded = false;
    impl->streamData = nullptr;
    impl->cpu.m_vuMem = impl->data.data();
    impl->timeline.setMemory(impl->data.data());
    impl->error.clear();
}
