#include "runtime_bridge.h"
#include <algorithm>
#include <bit>
#include <limits>
#include <stdexcept>

namespace
{
constexpr uint32_t statusMask = 0xfff, macMask = 0xffff;

uint32_t fmacLanes(uint32_t bits)
{
    return ((bits & 1) ? 0xfu : 0u) | ((bits & 2) ? 0xf0u : 0u) |
        ((bits & 4) ? 0xf00u : 0u) | ((bits & 8) ? 0xf000u : 0u);
}

void initializeFlags(FLAG_PIPELINE &pipe, uint32_t value)
{
    std::fill(std::begin(pipe.values), std::end(pipe.values), value);
}

uint32_t latestFlag(const FLAG_PIPELINE &pipe, uint32_t mirror, uint64_t end)
{
    if (pipe.index >= FLAG_PIPELINE_SLOTS) throw std::runtime_error("Invalid compiled flag cursor");
    for (unsigned i = 0; i < FLAG_PIPELINE_SLOTS; ++i)
    {
        const auto index = (pipe.index + i) & (FLAG_PIPELINE_SLOTS - 1);
        if (pipe.pipeTimes[index] <= end) mirror = pipe.values[index];
    }
    return mirror;
}
}

MIPSSTATE PlayVuRuntimeBridge::importState(const VUCompiledState::Input &input)
{
    const auto &v = input.state;
    constexpr uint32_t vf0[] = {0, 0, 0, 0x3f800000};
    if (input.budget <= 64 || input.budget > 1048576 ||
        input.cycle > std::numeric_limits<uint64_t>::max() - input.budget || v.cycles != input.cycle ||
        v.pc >= 16384 || (v.pc & 7) || v.ebit || v.haltAfterDelaySlot || v.branchPending ||
        v.dBitEnabled || v.tBitEnabled || v.stoppedByD || v.stoppedByT ||
        v.vi[0] || std::memcmp(v.vf[0], vf0, sizeof(vf0)) ||
        (v.mac & ~0xffffu) || (v.status & ~0xfffu) || (v.clip & ~0xffffffu) ||
        (input.branchBackupValid && input.branchBackupReg >= 16))
        throw std::runtime_error("Unsupported typed VU entry");
    MIPSSTATE s{};
    // Match CMIPS::Reset without constructing another emulator instance.
    s.nDelayedJumpAddr = MIPS_INVALID_PC;
    s.nFCSR = 0x01000001;
    std::memcpy(s.nCOP2, v.vf, sizeof(v.vf));
    std::memcpy(s.nCOP2VI, v.vi, sizeof(v.vi));
    std::memcpy(&s.nCOP2A, v.acc, sizeof(v.acc));
    s.nCOP2Q = std::bit_cast<uint32_t>(v.q);
    s.nCOP2P = std::bit_cast<uint32_t>(v.p);
    s.pipeQ = {0, s.nCOP2Q};
    s.pipeP = {0, s.nCOP2P};
    s.nCOP2I = std::bit_cast<uint32_t>(v.i);
    s.nCOP2R = v.r;
    s.nPC = v.pc;
    s.nCOP2MF = v.mac;
    s.nCOP2CF = v.clip;
    s.nCOP2SF = fmacLanes(v.status >> 6) | (fmacLanes(v.status) << 16);
    s.nCOP2DF = (v.status & 0x20) ? 1u : 0u;
    initializeFlags(s.pipeMac, s.nCOP2MF);
    initializeFlags(s.pipeClip, s.nCOP2CF);
    initializeFlags(s.pipeSticky, s.nCOP2SF);
    if (input.branchBackupValid)
    {
        s.savedNextBlockIntRegIdx = input.branchBackupReg;
        s.savedNextBlockIntRegVal = std::bit_cast<uint32_t>(input.branchBackupValue);
    }

    uint32_t vfMask = 0, flagMask = 0;
    std::array<uint8_t, 32> importedLanes{};
    for (size_t slot = 0; slot < input.vfWrites.size(); ++slot)
    {
        const auto &e = input.vfWrites[slot];
        if (!e.valid) continue;
        vfMask |= 1u << slot;
        if (!e.reg || e.reg >= 32 || !e.lanes || e.lanes > 15 ||
            e.ready <= input.cycle || e.ready > input.cycle + 3)
            throw std::runtime_error("Invalid typed pending VF write");
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            const uint8_t bit = 8u >> lane;
            if (!(e.lanes & bit) || input.vfLatest[e.reg][lane] != e.sequence) continue;
            if (input.vfReady[e.reg][lane] != e.ready || (importedLanes[e.reg] & bit))
                throw std::runtime_error("Inconsistent typed VF ownership/readiness");
            s.nCOP2[e.reg].nV[lane] = e.words[lane];
            importedLanes[e.reg] |= bit;
        }
    }
    if (vfMask != input.vfMask) throw std::runtime_error("Typed VF queue mask mismatch");
    for (unsigned reg = 0; reg < 32; ++reg)
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            const auto ready = input.vfReady[reg][lane];
            if (ready <= input.cycle) continue;
            if (!reg || ready > input.cycle + 3 || !(importedLanes[reg] & (8u >> lane)))
                throw std::runtime_error("Typed VF deadline has no supported pending value");
            for (unsigned remaining = 0; remaining < ready - input.cycle; ++remaining)
            {
                const unsigned bit = reg * 4 + 3 - lane;
                s.pipeFmacWrite[remaining].nV[bit / 32] |= 1u << (bit % 32);
            }
        }
    std::array<size_t, 8> order{};
    size_t count = 0;
    for (size_t slot = 0; slot < input.flags.size(); ++slot)
    {
        const auto &e = input.flags[slot];
        if (!e.valid) continue;
        flagMask |= 1u << slot;
        if (e.ready <= input.cycle || e.ready > input.cycle + 3)
            throw std::runtime_error("Unsupported typed flag deadline");
        order[count++] = slot;
    }
    if (flagMask != input.flagMask) throw std::runtime_error("Typed flag queue mask mismatch");
    std::stable_sort(order.begin(), order.begin() + count, [&](size_t a, size_t b) {
        return input.flags[a].ready < input.flags[b].ready;
    });
    unsigned macCount = 0, clipCount = 0, stickyCount = 0;
    const auto queue = [](FLAG_PIPELINE &pipe, unsigned &entries, uint32_t value, uint32_t ready) {
        if (++entries > FLAG_PIPELINE_SLOTS) throw std::runtime_error("Typed flag import exceeds pipeline capacity");
        pipe.values[pipe.index] = value;
        pipe.pipeTimes[pipe.index] = ready;
        pipe.index = (pipe.index + 1) & (FLAG_PIPELINE_SLOTS - 1);
    };
    uint32_t sticky = s.nCOP2SF;
    for (size_t i = 0; i < count; ++i)
    {
        const auto &e = input.flags[order[i]];
        const auto ready = static_cast<uint32_t>(e.ready - input.cycle);
        if (e.writesMac) queue(s.pipeMac, macCount, e.mac & 0xffff, ready);
        if (e.writesStatus)
        {
            sticky = (sticky & 0xffffu) | (fmacLanes(e.status) << 16);
            const auto bits = e.status | e.extraSticky;
            sticky |= fmacLanes(bits);
            queue(s.pipeSticky, stickyCount, sticky, ready);
        }
        if (e.writesSticky)
        {
            sticky = (sticky & 0xffff0000u) | fmacLanes(e.status >> 6);
            queue(s.pipeSticky, stickyCount, sticky, ready);
        }
        if (e.writesClip) queue(s.pipeClip, clipCount, e.clip, ready);
    }
    return s;
}

VUCompiledState::Output PlayVuRuntimeBridge::exportState(const VUCompiledState::Input &input,
    CompiledVuSession::Result result)
{
    const auto &s = result.state;
    if (!result.executed || !result.scalarFlagsValid || s.nHasException != MIPS_EXCEPTION_VU_EBIT ||
        !result.drainedCycle || result.drainedCycle > input.budget ||
        input.cycle > std::numeric_limits<uint64_t>::max() - result.drainedCycle ||
        result.drainedCycle != std::max(compiledVuDrainCycle(s, result.transferEnd), result.scalarEnd) ||
        (result.scalarStatus & ~0xc30u) ||
        result.packets.size() != result.completionCycles.size() ||
        s.nPC >= 16384 || (s.nPC & 7))
        throw std::runtime_error("Incomplete compiled result cannot be exported");
    VUCompiledState::Output output{};
    auto &v = output.state;
    std::memcpy(v.vf, s.nCOP2, sizeof(v.vf));
    std::memcpy(v.vi, s.nCOP2VI, sizeof(v.vi));
    std::memcpy(v.acc, &s.nCOP2A, sizeof(v.acc));
    v.q = std::bit_cast<float>(s.pipeQ.heldValue);
    v.p = std::bit_cast<float>(s.pipeP.heldValue);
    v.i = std::bit_cast<float>(s.nCOP2I);
    v.r = s.nCOP2R;
    v.pc = s.nPC;
    v.cycles = input.cycle + result.drainedCycle;
    v.top = input.state.top;
    v.itop = input.state.itop;
    v.mac = latestFlag(s.pipeMac, s.nCOP2MF, result.drainedCycle) & macMask;
    v.clip = latestFlag(s.pipeClip, s.nCOP2CF, result.drainedCycle) & 0xffffff;
    const auto sticky = latestFlag(s.pipeSticky, s.nCOP2SF, result.drainedCycle);
    v.status = ((sticky & 0xf0000) ? 1u : 0u) | ((sticky & 0xf00000) ? 2u : 0u) |
        ((sticky & 0xf000000) ? 4u : 0u) | ((sticky & 0xf0000000) ? 8u : 0u) |
        ((sticky & 0xf) ? 0x40u : 0u) | ((sticky & 0xf0) ? 0x80u : 0u) |
        ((sticky & 0xf00) ? 0x100u : 0u) | ((sticky & 0xf000) ? 0x200u : 0u) | (result.scalarStatus & 0xc30u);
    output.elapsed = result.drainedCycle;
    output.statusMask = statusMask;
    output.macMask = macMask;
    output.data = result.data;
    output.packets.reserve(result.packets.size());
    for (size_t i = 0; i < result.packets.size(); ++i)
    {
        if (!result.completionCycles[i] || result.completionCycles[i] > result.drainedCycle ||
            (i && result.completionCycles[i] < result.completionCycles[i - 1]))
            throw std::runtime_error("Invalid compiled packet completion time");
        output.packets.push_back({result.completionCycles[i], std::move(result.packets[i])});
    }
    return output;
}

PlayVuRuntimeBridge::Result PlayVuRuntimeBridge::evaluate(const VUCompiledState::Input &input,
    const std::array<uint8_t, 16384> &code, const std::array<uint8_t, 16384> &data)
{
    Result result;
    try
    {
        const auto imported = importState(input);
        const auto scalar = importScalarFlags(input);
        auto compiled = session.run(code, data, imported, input.budget, input.state.top, input.state.itop, &scalar);
        if (!compiled.executed)
        {
            result.reason = std::move(compiled.reason);
            return result;
        }
        result.output = exportState(input, std::move(compiled));
        result.evaluated = true;
    }
    catch (const std::exception &e)
    {
        result = {};
        result.reason = e.what();
    }
    return result;
}

ScalarFlags::State PlayVuRuntimeBridge::importScalarFlags(const VUCompiledState::Input &input)
{
    ScalarFlags::State state{};
    state.status = input.state.status & 0xc30;
    size_t count = 0;
    for (const auto &e : input.flags)
        if (e.valid && e.writesSticky)
        {
            if (e.ready <= input.cycle || e.ready > input.cycle + 3)
                throw std::runtime_error("Unsupported incoming FSSET deadline");
            state.events[count++] = {e.ready - input.cycle, e.status & 0xc00, true, true};
        }
    return state;
}
