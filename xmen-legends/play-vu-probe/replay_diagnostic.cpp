#define NOMINMAX
#include "replay_diagnostic.h"
#include "transfer_timeline.h"
#include "compiled_session.h"
#include "runtime_bridge.h"
#include "TestVm.h"
#include "VuAssembler.h"
#include "VUShared.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>

extern "C" void playVuCheckRegisters(void (*function)(void *), void *context,
    const uint32_t *sentinel, uint32_t *actual);

namespace
{
using Bytes = std::vector<uint8_t>;
struct Reader
{
    const Bytes &bytes;
    size_t offset = 0;
    uint64_t integer(size_t count)
    {
        if (count > 8 || offset > bytes.size() || count > bytes.size() - offset)
            throw std::runtime_error("Truncated replay integer");
        uint64_t result = 0;
        for (size_t i = 0; i < count; ++i)
            result |= uint64_t(bytes[offset++]) << (8 * i);
        return result;
    }
    uint32_t u32() { return static_cast<uint32_t>(integer(4)); }
    Bytes raw(size_t size)
    {
        if (offset > bytes.size() || size > bytes.size() - offset)
            throw std::runtime_error("Truncated replay blob");
        Bytes result(bytes.begin() + offset, bytes.begin() + offset + size);
        offset += size;
        return result;
    }
    Bytes blob() { return raw(u32()); }
    void finish() { if (offset != bytes.size()) throw std::runtime_error("Trailing replay bytes"); }
};

uint64_t at(const Bytes &bytes, size_t offset, size_t count = 4)
{
    Reader reader{bytes, offset};
    return reader.integer(count);
}

// VUR1 has no versioned state schema. Accept only the known inactive-PATH1 layout.
bool importable(const Bytes &state)
{
    if (state.size() != 4682 || state[0] != 1 || state[2271] != 0 || state[647] != 0 ||
        state[633] != 0 || state[634] != 0 || state[635] != 0 || state[636] != 0 ||
        state[637] != 0 || state[638] != 0 ||
        state[4678] != 0 || state[4679] != 1 ||
        state[4680] != 0 || state[4681] != 0)
        return false;
    for (size_t offset : {size_t(968), size_t(985), size_t(1002)})
        if (state[offset] != 0) return false;
    for (size_t offset : {size_t(2255), size_t(2263), size_t(2267)})
        if (at(state, offset) != 0) return false;
    // Reject inconsistent queue masks instead of silently dropping live entries.
    for (size_t slot = 0; slot < 8; ++slot)
        if (state[1003 + slot * 30 + 29] ||
            state[1803 + slot * 22 + 21] || state[1979 + slot * 34 + 33]) return false;
    if (state[4677] && state[4676] >= 16) return false;
    const uint64_t cycle = at(state, 4640, 8);
    for (size_t offset = 2272; offset < 3296; offset += 8)
        if (at(state, offset, 8) > cycle + 3) return false;
    for (size_t offset = 3296; offset < 3456; offset += 8)
        if (at(state, offset, 8) > cycle) return false;
    for (const auto &queue : {std::array<size_t, 5>{656, 37, 8, 32, 2251}, {1243, 35, 16, 34, 2259}})
    {
        uint32_t mask = 0;
        for (size_t slot = 0; slot < queue[2]; ++slot)
        {
            const size_t offset = queue[0] + slot * queue[1];
            if (!state[offset + queue[3]]) continue;
            mask |= 1u << slot;
            const uint64_t ready = at(state, offset, 8);
            if (ready <= cycle || ready > cycle + 3) return false;
        }
        if (mask != at(state, queue[4])) return false;
    }
    return at(state, 4656, 8) <= cycle;
}

void initializeFlags(FLAG_PIPELINE &pipeline, uint32_t value)
{
    pipeline = {};
    std::fill(std::begin(pipeline.values), std::end(pipeline.values), value);
}

VUCompiledState::Input typedInput(const Bytes &state, uint32_t budget)
{
    if (!importable(state)) throw std::runtime_error("Unsupported replay state for typed bridge");
    VUCompiledState::Input input{};
    auto &s = input.state;
    std::memcpy(s.vf, state.data() + 1, sizeof(s.vf));
    std::memcpy(s.vi, state.data() + 513, sizeof(s.vi));
    std::memcpy(s.acc, state.data() + 577, sizeof(s.acc));
    std::memcpy(&s.q, state.data() + 593, 4);
    std::memcpy(&s.p, state.data() + 597, 4);
    std::memcpy(&s.i, state.data() + 601, 4);
    s.r = static_cast<uint32_t>(at(state, 605));
    s.pc = static_cast<uint32_t>(at(state, 609));
    s.mac = static_cast<uint32_t>(at(state, 613));
    s.clip = static_cast<uint32_t>(at(state, 617));
    s.status = static_cast<uint32_t>(at(state, 621));
    s.cycles = at(state, 625, 8);
    s.top = static_cast<uint32_t>(at(state, 639));
    s.itop = static_cast<uint32_t>(at(state, 643));
    s.branchTarget = static_cast<uint32_t>(at(state, 648));
    s.branchDelay = static_cast<uint32_t>(at(state, 652));
    input.cycle = at(state, 4640, 8);
    input.nextSequence = at(state, 4648, 8);
    input.budget = budget;
    input.flagMask = static_cast<uint32_t>(at(state, 2251));
    input.vfMask = static_cast<uint32_t>(at(state, 2259));
    std::memcpy(&input.branchBackupValue, state.data() + 4672, 4);
    input.branchBackupReg = state[4676];
    input.branchBackupValid = state[4677] != 0;
    for (unsigned reg = 0; reg < 32; ++reg)
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            input.vfReady[reg][lane] = at(state, 2272 + (reg * 4 + lane) * 8, 8);
            input.vfLatest[reg][lane] = at(state, 3456 + (reg * 4 + lane) * 8, 8);
        }
    for (size_t slot = 0; slot < input.vfWrites.size(); ++slot)
    {
        const size_t offset = 1243 + slot * 35;
        if (!state[offset + 34]) continue;
        auto &e = input.vfWrites[slot];
        e.ready = at(state, offset, 8);
        e.sequence = at(state, offset + 8, 8);
        std::memcpy(e.words.data(), state.data() + offset + 16, 16);
        e.reg = state[offset + 32];
        e.lanes = state[offset + 33];
        e.valid = true;
    }
    for (size_t slot = 0; slot < input.flags.size(); ++slot)
    {
        const size_t offset = 656 + slot * 37;
        if (!state[offset + 32]) continue;
        input.flags[slot] = {at(state, offset, 8), at(state, offset + 8, 8),
            static_cast<uint32_t>(at(state, offset + 16)), static_cast<uint32_t>(at(state, offset + 20)),
            static_cast<uint32_t>(at(state, offset + 24)), static_cast<uint32_t>(at(state, offset + 28)),
            true, state[offset + 33] != 0, state[offset + 34] != 0, state[offset + 35] != 0, state[offset + 36] != 0};
    }
    return input;
}

void importScalars(MIPSSTATE &s, const Bytes &state)
{
    s.nCOP2Q = static_cast<uint32_t>(at(state, 593));
    s.nCOP2P = static_cast<uint32_t>(at(state, 597));
    // An idle Play! pipeline still republishes its held value on reads/waits.
    s.pipeQ = {0, s.nCOP2Q};
    s.pipeP = {0, s.nCOP2P};
}

struct DrainedControl
{
    uint64_t cycle;
    uint32_t q, p, mac, clip, status;
    static constexpr uint32_t statusMask = 0xe3;
    static constexpr uint32_t macMask = 0xff;
};

DrainedControl drainControl(const MIPSSTATE &s, uint64_t transferEnd)
{
    const auto end = compiledVuDrainCycle(s, transferEnd);
    const auto latest = [&](const FLAG_PIPELINE &pipe, uint32_t mirror) {
        for (unsigned i = 0; i < FLAG_PIPELINE_SLOTS; ++i)
        {
            const auto index = (pipe.index + i) & (FLAG_PIPELINE_SLOTS - 1);
            if (pipe.pipeTimes[index] <= end) mirror = pipe.values[index];
        }
        return mirror;
    };
    const uint32_t mac = latest(s.pipeMac, s.nCOP2MF) & DrainedControl::macMask;
    const uint32_t sticky = latest(s.pipeSticky, s.nCOP2SF);
    const uint32_t status = ((mac & 0xf) ? 1u : 0u) | ((mac & 0xf0) ? 2u : 0u) |
        ((sticky & 0xf) ? 0x40u : 0u) | ((sticky & 0xf0) ? 0x80u : 0u) | (s.nCOP2DF ? 0x20u : 0u);
    return {end, s.pipeQ.heldValue, s.pipeP.heldValue, mac,
        latest(s.pipeClip, s.nCOP2CF) & 0xffffffu, status};
}

void importPending(MIPSSTATE &s, const Bytes &state)
{
    const uint64_t cycle = at(state, 4640, 8);
    unsigned pendingVf = 0, pendingFlags = 0;
    uint32_t supportedLanes[32]{};
    for (size_t slot = 0; slot < 16; ++slot)
    {
        const size_t offset = 1243 + slot * 35;
        if (!state[offset + 34]) continue;
        ++pendingVf;
        const unsigned reg = state[offset + 32], lanes = state[offset + 33];
        if (reg == 0 || reg >= 32 || lanes == 0 || lanes > 15)
            throw std::runtime_error("Invalid pending VF write");
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            if (!(lanes & (8u >> lane))) continue;
            const uint64_t latest = at(state, 3456 + (reg * 4 + lane) * 8, 8);
            if (latest != at(state, offset + 8, 8)) continue;
            const uint64_t ready = at(state, 2272 + (reg * 4 + lane) * 8, 8);
            if (ready != at(state, offset, 8)) throw std::runtime_error("Pending VF readiness mismatch");
            // Play! stores completed arithmetic values early and delays reads
            // using per-lane FMAC hazard masks. This is not a CPU-visible snapshot.
            s.nCOP2[reg].nV[lane] = static_cast<uint32_t>(at(state, offset + 16 + lane * 4));
            supportedLanes[reg] |= 8u >> lane;
        }
    }
    for (unsigned reg = 1; reg < 32; ++reg)
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            const uint64_t ready = at(state, 2272 + (reg * 4 + lane) * 8, 8);
            if (ready <= cycle) continue;
            if (!(supportedLanes[reg] & (8u >> lane)))
                throw std::runtime_error("Future VF readiness has no importable value");
            for (unsigned remaining = 0; remaining < ready - cycle; ++remaining)
            {
                const unsigned bit = reg * 4 + 3 - lane;
                s.pipeFmacWrite[remaining].nV[bit / 32] |= 1u << (bit % 32);
            }
        }
    std::vector<size_t> flags;
    for (size_t slot = 0; slot < 8; ++slot)
        if (state[656 + slot * 37 + 32]) flags.push_back(656 + slot * 37);
    std::stable_sort(flags.begin(), flags.end(), [&](size_t a, size_t b) {
        return at(state, a, 8) < at(state, b, 8);
    });
    const auto queueFlag = [](FLAG_PIPELINE &pipe, uint32_t value, uint32_t ready) {
        pipe.values[pipe.index] = value;
        pipe.pipeTimes[pipe.index] = ready;
        pipe.index = (pipe.index + 1) & (FLAG_PIPELINE_SLOTS - 1);
    };
    uint32_t sticky = s.nCOP2SF;
    for (const size_t offset : flags)
    {
        ++pendingFlags;
        const auto ready = static_cast<uint32_t>(at(state, offset, 8) - cycle);
        if (state[offset + 33]) queueFlag(s.pipeMac, static_cast<uint32_t>(at(state, offset + 16)) & 0xffu, ready);
        if (state[offset + 34])
        {
            const uint32_t bits = static_cast<uint32_t>(at(state, offset + 20) | at(state, offset + 24));
            sticky |= ((bits & 1u) ? 0x0fu : 0u) | ((bits & 2u) ? 0xf0u : 0u);
            queueFlag(s.pipeSticky, sticky, ready);
        }
        if (state[offset + 35])
        {
            const auto status = static_cast<uint32_t>(at(state, offset + 20));
            sticky = ((status & 0x40u) ? 0x0fu : 0u) | ((status & 0x80u) ? 0xf0u : 0u);
            queueFlag(s.pipeSticky, sticky, ready);
        }
        if (state[offset + 36]) queueFlag(s.pipeClip, static_cast<uint32_t>(at(state, offset + 28)), ready);
    }
    std::printf("[play-vu:import] pending-vf=%u pending-flags=%u short-slices-supported=0\n", pendingVf, pendingFlags);
}

Bytes readPacket(const uint8_t *memory, uint32_t qword)
{
    Bytes packet;
    uint32_t address = (qword & 1023u) * 16u;
    for (unsigned tags = 0; tags < 4096; ++tags)
    {
        std::array<uint8_t, 16> tag{};
        for (unsigned i = 0; i < 16; ++i) tag[i] = memory[(address + i) & 16383u];
        uint64_t lo = 0;
        std::memcpy(&lo, tag.data(), 8);
        const auto loops = static_cast<uint32_t>(lo & 0x7fffu);
        const auto format = static_cast<uint32_t>((lo >> 58) & 3u);
        uint32_t registers = static_cast<uint32_t>(lo >> 60);
        if (!registers) registers = 16;
        const uint32_t payload = format == 0 ? loops * registers * 16u :
            format == 1 ? ((loops * registers + 1u) / 2u) * 16u : loops * 16u;
        if (packet.size() + 16u + payload > 65536u)
            throw std::runtime_error("Diagnostic GIF packet exceeds 64 KiB");
        for (uint32_t i = 0; i < 16u + payload; ++i)
            packet.push_back(memory[(address + i) & 16383u]);
        address = (address + 16u + payload) & 16383u;
        if (lo & 0x8000u) return packet;
    }
    throw std::runtime_error("Diagnostic GIF chain did not terminate");
}

unsigned differences(const uint8_t *actual, const Bytes &expected)
{
    unsigned count = 0;
    for (size_t i = 0; i < expected.size(); ++i)
        count += actual[i] != expected[i];
    return count;
}
}

bool pendingImportTests()
{
    {
        MIPSSTATE s{};
        s.pipeTime = 10;
        s.nCOP2Q = s.nCOP2P = 0;
        s.pipeQ = {13, 0x3f000000};
        s.pipeP = {19, 0x3e800000};
        initializeFlags(s.pipeMac, 0xff);
        initializeFlags(s.pipeSticky, 0);
        initializeFlags(s.pipeClip, 0);
        s.pipeMac.index = s.pipeSticky.index = s.pipeClip.index = 1;
        s.pipeMac.pipeTimes[0] = 14;
        s.pipeMac.values[0] = 0x20;
        s.pipeSticky.pipeTimes[0] = 14;
        s.pipeSticky.values[0] = 0xff;
        s.pipeClip.pipeTimes[0] = 12;
        s.pipeClip.values[0] = 0x123456;
        s.nCOP2DF = 1;
        s.pipeFmacWrite[2].nV0 = 0x800;
        const MIPSSTATE before = s;
        const auto actual = drainControl(s, 11);
        const bool passed = actual.cycle == 19 && actual.q == 0x3f000000 && actual.p == 0x3e800000 &&
            actual.mac == 0x20 && actual.clip == 0x123456 && actual.status == 0xe2 &&
            !std::memcmp(&before, &s, sizeof(s)) && DrainedControl::statusMask == 0xe3;
        std::printf("[play-vu:drain-test] passed=%u cycle=%llu status=%03x known-mask=%03x\n",
            unsigned(passed), static_cast<unsigned long long>(actual.cycle), actual.status, DrainedControl::statusMask);
        if (!passed) return false;
        s.pipeQ.counter = s.pipeP.counter = 0;
        for (auto *pipe : {&s.pipeMac, &s.pipeSticky, &s.pipeClip}) initializeFlags(*pipe, 0);
        if (drainControl(s, 11).cycle != 13 || drainControl(s, 17).cycle != 17) return false;
    }
    {
        Bytes scalarState(4682);
        const uint32_t q = 0x3f000000, p = 0x3e800000;
        std::memcpy(scalarState.data() + 593, &q, 4);
        std::memcpy(scalarState.data() + 597, &p, 4);
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        auto &s = vm->m_cpu.m_State;
        importScalars(s, scalarState);
        s.nCOP2[1].nV0 = 0x3f800000;
        {
            CVuAssembler a(reinterpret_cast<uint32 *>(vm->m_microMem));
            a.Write(CVuAssembler::Upper::MULq(CVuAssembler::DEST_X, CVuAssembler::VF2,
                CVuAssembler::VF1), CVuAssembler::Lower::NOP());
            a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::WAITQ());
            a.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::WAITP());
            a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
        }
        vm->ExecuteTest(0);
        const bool passed = s.nCOP2[2].nV0 == q && s.nCOP2Q == q && s.nCOP2P == p && s.pipeTime == 4;
        std::printf("[play-vu:scalar-import-test] passed=%u vf=%08x q=%08x p=%08x\n",
            unsigned(passed), s.nCOP2[2].nV0, s.nCOP2Q, s.nCOP2P);
        if (!passed) return false;
    }
    Bytes state(4682);
    const auto put = [&](size_t offset, uint64_t value, size_t bytes = 4) {
        for (size_t byte = 0; byte < bytes; ++byte) state.at(offset + byte) = static_cast<uint8_t>(value >> (8 * byte));
    };
    state[0] = 1;
    state[4679] = 1;
    put(4640, 100, 8);
    put(2259, 3);
    for (unsigned slot = 0; slot < 2; ++slot)
    {
        const size_t offset = 1243 + slot * 35;
        put(offset, slot == 0 ? 101 : 103, 8);
        put(offset + 8, slot + 1, 8);
        put(offset + 16, slot == 0 ? 0x40000000 : 0x3f800000);
        put(offset + 24, 0x40000000);
        state[offset + 32] = 2;
        state[offset + 33] = slot == 0 ? 0xa : 0x8;
        state[offset + 34] = 1;
    }
    put(2272 + 8 * 8, 103, 8); // VF2.x: latest write is the younger slot.
    put(2272 + 10 * 8, 101, 8); // VF2.z: the older slot still owns this lane.
    put(3456 + 8 * 8, 2, 8);
    put(3456 + 10 * 8, 1, 8);
    put(2251, 7);
    for (unsigned slot = 0; slot < 3; ++slot)
    {
        const size_t offset = 656 + slot * 37;
        put(offset, 101 + slot, 8);
        state[offset + 32] = 1;
        if (slot < 2)
        {
            put(offset + 16, slot == 0 ? 0x8 : 0x80);
            put(offset + 20, slot == 0 ? 1 : 2);
            state[offset + 33] = state[offset + 34] = 1;
        }
        else
        {
            put(offset + 28, 0x123456);
            state[offset + 35] = state[offset + 36] = 1;
        }
    }
    if (!importable(state)) return false;
    auto vm = std::make_unique<CTestVm>();
    vm->Reset();
    auto &s = vm->m_cpu.m_State;
    initializeFlags(s.pipeMac, 0);
    initializeFlags(s.pipeSticky, 0);
    initializeFlags(s.pipeClip, 0);
    importPending(s, state);
    if (s.nCOP2[2].nV0 != 0x3f800000 || s.nCOP2[2].nV2 != 0x40000000 ||
        s.pipeFmacWrite[0].nV0 != 0xa00 || s.pipeFmacWrite[1].nV0 != 0x800 ||
        s.pipeFmacWrite[2].nV0 != 0x800) return false;
    for (unsigned cycle = 0; cycle < 4; ++cycle)
    {
        VUShared::CheckFlagPipelineImmediate(VUShared::g_pipeInfoMac, &vm->m_cpu, cycle);
        VUShared::CheckFlagPipelineImmediate(VUShared::g_pipeInfoSticky, &vm->m_cpu, cycle);
        VUShared::CheckFlagPipelineImmediate(VUShared::g_pipeInfoClip, &vm->m_cpu, cycle);
        const uint32_t expectedMac[] = {0, 0x8, 0x80, 0x80};
        const uint32_t expectedSticky[] = {0, 0xf, 0xff, 0};
        if (s.nCOP2MF != expectedMac[cycle] || s.nCOP2SF != expectedSticky[cycle] ||
            s.nCOP2CF != (cycle == 3 ? 0x123456 : 0)) return false;
    }
    {
        CVuAssembler assembler(reinterpret_cast<uint32 *>(vm->m_microMem));
        assembler.Write(CVuAssembler::Upper::MULAbc(CVuAssembler::DEST_X, CVuAssembler::VF2,
            CVuAssembler::VF0, CVuAssembler::BC_W), CVuAssembler::Lower::NOP());
        assembler.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
        assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    }
    vm->ExecuteTest(0);
    if (s.pipeTime != 6 || s.nCOP2A.nV0 != 0x3f800000) return false;
    put(2259, 1);
    if (importable(state)) return false;
    put(2259, 3);
    put(2272 + 8 * 8, 104, 8);
    if (importable(state)) return false;
    put(2272 + 8 * 8, 103, 8);
    state[1243 + 32] = 0;
    bool rejected = false;
    try { importPending(s, state); }
    catch (const std::runtime_error &) { rejected = true; }
    std::printf("[play-vu:pending-import-test] passed=%u delayed-read-cycles=%u\n", unsigned(rejected), s.pipeTime);
    return rejected;
}

int replayDiagnostic(const char *path)
{
    CompiledVuSession detachedSession;
    PlayVuRuntimeBridge runtimeBridge;
    unsigned memoryTraceCase = 64;
    if (const char *value = std::getenv("PS2X_VU_REPLAY_MEMORY_TRACE_CASE"))
    {
        char *end = nullptr;
        const auto parsed = std::strtoul(value, &end, 10);
        if (end == value || *end || parsed >= 64) throw std::runtime_error("Invalid VU memory trace case");
        memoryTraceCase = static_cast<unsigned>(parsed);
    }
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("Cannot open private replay");
    const auto length = input.tellg();
    if (length < 0 || length > 4 * 1024 * 1024) throw std::runtime_error("Replay exceeds 4 MiB");
    Bytes file(static_cast<size_t>(length));
    input.seekg(0);
    if (!input.read(reinterpret_cast<char*>(file.data()), file.size()))
        throw std::runtime_error("Cannot read private replay");
    Reader records{file};
    unsigned index = 0, eligible = 0;
    while (records.offset < file.size())
    {
        if (index >= 64 || records.u32() != 0x31525556u) throw std::runtime_error("Invalid VUR1 header");
        const uint32_t size = records.u32();
        if (size > 1024u * 1024u) throw std::runtime_error("Replay record exceeds 1 MiB");
        const Bytes body = records.raw(size);
        Reader record{body};
        const uint32_t budget = record.u32();
        record.integer(8);
        const Bytes code = record.blob(), data = record.blob(), before = record.blob();
        const Bytes afterData = record.blob(), after = record.blob(), expectedGifs = record.blob();
        record.finish();
        if (code.size() != 16384 || data.size() != 16384 || afterData.size() != 16384 || after.size() < 4682)
            throw std::runtime_error("Invalid replay dimensions");
        const unsigned current = index++;
        if (budget <= 64 || !importable(before) || after[after.size() - 3] != 0) continue;
        ++eligible;
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        std::memcpy(vm->m_microMem, code.data(), code.size());
        std::memcpy(vm->m_vuMem, data.data(), data.size());
        auto &s = vm->m_cpu.m_State;
        std::memcpy(s.nCOP2, before.data() + 1, 512);
        std::memcpy(s.nCOP2VI, before.data() + 513, 64);
        std::memcpy(&s.nCOP2A, before.data() + 577, 16);
        importScalars(s, before);
        s.nCOP2I = static_cast<uint32_t>(at(before, 601));
        s.nCOP2R = static_cast<uint32_t>(at(before, 605));
        s.nPC = static_cast<uint32_t>(at(before, 609));
        s.nCOP2MF = static_cast<uint32_t>(at(before, 613)) & 0xffu;
        s.nCOP2CF = static_cast<uint32_t>(at(before, 617));
        const uint32_t status = static_cast<uint32_t>(at(before, 621));
        s.nCOP2SF = ((status & 0x40u) ? 0x0fu : 0u) | ((status & 0x80u) ? 0xf0u : 0u);
        s.nCOP2DF = (status & 0x20u) ? 1u : 0u;
        initializeFlags(s.pipeMac, s.nCOP2MF);
        initializeFlags(s.pipeSticky, s.nCOP2SF);
        initializeFlags(s.pipeClip, s.nCOP2CF);
        importPending(s, before);
        if (before[4677])
        {
            s.savedNextBlockIntRegIdx = before[4676];
            s.savedNextBlockIntRegVal = static_cast<uint32_t>(at(before, 4672));
        }
        std::vector<Bytes> actualPackets, expectedPackets;
        std::string callbackError;
        TransferTimeline timeline(vm->m_vuMem);
        std::string timelineError;
        bool traceMemory = current == memoryTraceCase;
        auto previousData = traceMemory ? data : Bytes{};
        unsigned traceWrites = 0;
        vm->m_cpu.m_vuMemoryObserver = [&](CMIPS *cpu, uint32 pc, uint32 cycle, uint32 phase) {
            if (!timelineError.empty()) return;
            try {
                ++timeline.events;
                if (phase == 2) timeline.kick(cpu->m_State.xgkickAddress, cycle);
                else timeline.advance(cycle);
                if (traceMemory && (phase == 1 || phase == 3))
                    for (unsigned offset = 0; offset < 16384; offset += 16)
                    {
                        if (!std::memcmp(vm->m_vuMem + offset, previousData.data() + offset, 16)) continue;
                        if (++traceWrites > 4096) throw std::runtime_error("VU memory trace exceeds its output limit");
                        uint32_t words[4];
                        std::memcpy(words, vm->m_vuMem + offset, sizeof(words));
                        std::memcpy(previousData.data() + offset, words, sizeof(words));
                        std::printf("[vu-memory] pc=%04x cycle=%u offset=%04x words=%08x,%08x,%08x,%08x\n",
                            pc, cycle, offset, words[0], words[1], words[2], words[3]);
                    }
            } catch (const std::exception &e) {
                timelineError = std::string(e.what()) + " pc=" + std::to_string(pc) +
                    " cycle=" + std::to_string(cycle) + " phase=" + std::to_string(phase);
            }
        };
        vm->m_cpu.m_vuXgkickWait = [&](CMIPS *, uint32 pc, uint32 cycle) -> uint32 {
            if (!timelineError.empty()) return 0;
            try {
                timeline.finish(cycle);
                return static_cast<uint32>(timeline.time - cycle);
            } catch (const std::exception &e) {
                timelineError = std::string(e.what()) + " wait-pc=" + std::to_string(pc);
                return 0;
            }
        };
        vm->m_cpu.m_pMemoryMap->InsertReadMap(0x8400u, 0x8423u,
            [&](uint32_t address, uint32_t) -> uint32_t {
                if (address == 0x8400u) return static_cast<uint32_t>(at(before, 639));
                if (address == 0x8420u) return static_cast<uint32_t>(at(before, 643));
                return 0u;
            }, 1u);
        vm->m_cpu.m_pMemoryMap->InsertWriteMap(0x8410u, 0x8413u,
            [&](uint32_t, uint32_t address) -> uint32_t {
                try {
                    if (actualPackets.size() >= 1024) throw std::runtime_error("Too many diagnostic packets");
                    actualPackets.push_back(readPacket(vm->m_vuMem, address));
                } catch (const std::exception &e) { callbackError = e.what(); }
                return 0u;
            }, 1u);
        Reader gifs{expectedGifs};
        std::vector<uint64_t> expectedCompletionCycles;
        while (gifs.offset < expectedGifs.size())
        {
            const auto cycle = gifs.integer(8);
            const auto initialCycle = at(before, 4640, 8);
            if (cycle < initialCycle) throw std::runtime_error("Invalid GIF completion time");
            expectedCompletionCycles.push_back(cycle - initialCycle);
            expectedPackets.push_back(gifs.blob());
        }
        std::printf("[play-vu:replay] case=%u start=0x%x unsupported-status=0x%x diagnostic-only=1\n",
            current, s.nPC, status & ~0xe3u);
        std::fflush(stdout);
        const MIPSSTATE initial = s;
        const auto runtimeInput = typedInput(before, budget);
        const auto initialScalar = PlayVuRuntimeBridge::importScalarFlags(runtimeInput);
        ScalarFlags directScalar;
        directScalar.reset(initialScalar);
        vm->m_cpu.m_vuStatusObserver = [&](CMIPS *context, uint32 opcode, uint32 cycle, uint32 value) {
            if (!timelineError.empty()) return value;
            try { return directScalar.observe(context, opcode, cycle, value); }
            catch (const std::exception &e) { timelineError = e.what(); return value; }
        };
        const auto typedInitial = PlayVuRuntimeBridge::importState(runtimeInput);
        if (std::memcmp(&typedInitial, &initial, sizeof(initial)))
            throw std::runtime_error("Typed runtime import diverged from recorded-state importer");
        alignas(16) const uint32_t sentinel[] = {0x3f123456, 0x40123456, 0x41123456, 0x42123456};
        uint32_t actualRegisters[40]{};
        playVuCheckRegisters([](void *context) {
            static_cast<CTestVm *>(context)->m_executor.Execute(2 * 1048576);
        }, vm.get(), sentinel, actualRegisters);
        unsigned corruptMask = 0;
        for (unsigned reg = 0; reg < 10; ++reg)
            if (std::memcmp(actualRegisters + reg * 4, sentinel, sizeof(sentinel)))
                corruptMask |= 1u << reg;
        std::printf("[play-vu:windows-abi] xmm6-through-xmm15-corrupt-mask=0x%x\n", corruptMask);
        if (corruptMask) throw std::runtime_error("JIT clobbered Windows nonvolatile SIMD registers");
        if (!timelineError.empty()) throw std::runtime_error(timelineError);
        timeline.finish(s.pipeTime);
        const MIPSSTATE coldFinal = s;
        traceMemory = false;
        const Bytes coldData(vm->m_vuMem, vm->m_vuMem + 16384);
        const auto coldPackets = actualPackets;
        const auto coldStreamingPackets = timeline.packets;
        const auto coldCompletionCycles = timeline.completionCycles;
        std::array<uint8_t, 16384> bridgeCode{}, bridgeData{};
        std::memcpy(bridgeCode.data(), code.data(), code.size());
        std::memcpy(bridgeData.data(), data.data(), data.size());
        const auto detached = detachedSession.run(bridgeCode, bridgeData, initial, budget,
            static_cast<uint32_t>(at(before, 639)), static_cast<uint32_t>(at(before, 643)), &initialScalar);
        const bool detachedMatches = detached.executed &&
            !std::memcmp(&detached.state, &coldFinal, sizeof(coldFinal)) &&
            !std::memcmp(detached.data.data(), coldData.data(), coldData.size()) &&
            detached.packets == coldStreamingPackets && detached.completionCycles == coldCompletionCycles &&
            detached.transferEnd == timeline.time;
        std::printf("[play-vu:detached-session] case=%u match=%u reason=%s runtime-accepted=0\n",
            current, unsigned(detachedMatches), detached.reason.c_str());
        if (!detachedMatches) throw std::runtime_error("Detached session diverged from direct compiled diagnostic");
        const auto drained = drainControl(s, timeline.time);
        const auto runtimeOutput = PlayVuRuntimeBridge::exportState(runtimeInput, detached);
        const bool exportMatches = !std::memcmp(runtimeOutput.state.vf, s.nCOP2, sizeof(runtimeOutput.state.vf)) &&
            !std::memcmp(runtimeOutput.state.vi, s.nCOP2VI, sizeof(runtimeOutput.state.vi)) &&
            !std::memcmp(runtimeOutput.state.acc, &s.nCOP2A, sizeof(runtimeOutput.state.acc)) &&
            !std::memcmp(&runtimeOutput.state.q, &drained.q, 4) && !std::memcmp(&runtimeOutput.state.p, &drained.p, 4) &&
            runtimeOutput.elapsed == drained.cycle && runtimeOutput.state.cycles == runtimeInput.cycle + drained.cycle &&
            runtimeOutput.state.mac == drained.mac && runtimeOutput.state.clip == drained.clip &&
            (runtimeOutput.state.status & 0xc3) == (drained.status & 0xc3) &&
            runtimeOutput.statusMask == 0xcf3 && runtimeOutput.macMask == DrainedControl::macMask &&
            runtimeOutput.data == detached.data && runtimeOutput.packets.size() == detached.packets.size();
        if (!exportMatches) throw std::runtime_error("Typed runtime export diverged from completed-state diagnostic");
        for (size_t i = 0; i < runtimeOutput.packets.size(); ++i)
            if (runtimeOutput.packets[i].bytes != detached.packets[i] ||
                runtimeOutput.packets[i].cycle != detached.completionCycles[i])
                throw std::runtime_error("Typed runtime export changed staged graphics");
        std::printf("[play-vu:typed-bridge] case=%u import-match=1 export-match=1 runtime-accepted=0\n", current);
        const auto sameExport = [&](const PlayVuRuntimeBridge::Result &r) {
            if (!r.evaluated) return false;
            const auto &a = r.output;
            const auto &b = runtimeOutput;
            if (a.elapsed != b.elapsed || a.macMask != b.macMask || a.statusMask != b.statusMask ||
                a.data != b.data || a.packets.size() != b.packets.size() ||
                std::memcmp(a.state.vf, b.state.vf, sizeof(a.state.vf)) ||
                std::memcmp(a.state.vi, b.state.vi, sizeof(a.state.vi)) ||
                std::memcmp(a.state.acc, b.state.acc, sizeof(a.state.acc)) ||
                std::memcmp(&a.state.q, &b.state.q, 4) || std::memcmp(&a.state.p, &b.state.p, 4) ||
                std::memcmp(&a.state.i, &b.state.i, 4) || a.state.r != b.state.r || a.state.pc != b.state.pc ||
                a.state.cycles != b.state.cycles || a.state.mac != b.state.mac ||
                a.state.status != b.state.status || a.state.clip != b.state.clip ||
                a.state.top != b.state.top || a.state.itop != b.state.itop ||
                a.state.ebit || a.state.haltAfterDelaySlot || a.state.branchPending) return false;
            for (size_t i = 0; i < a.packets.size(); ++i)
                if (a.packets[i].bytes != b.packets[i].bytes || a.packets[i].cycle != b.packets[i].cycle) return false;
            return true;
        };
        const auto typedCold = runtimeBridge.evaluate(runtimeInput, bridgeCode, bridgeData);
        if (!sameExport(typedCold)) throw std::runtime_error("Combined typed bridge changed the cold result: " + typedCold.reason);
        constexpr unsigned bridgeRepeats = 256;
        int64_t bridgeNs = 0;
        for (unsigned repeat = 0; repeat < bridgeRepeats; ++repeat)
        {
            const auto begin = std::chrono::steady_clock::now();
            const auto result = runtimeBridge.evaluate(runtimeInput, bridgeCode, bridgeData);
            bridgeNs += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - begin).count();
            if (!sameExport(result)) throw std::runtime_error("Typed bridge changed a warm result: " + result.reason);
        }
        std::printf("[play-vu:typed-timing] case=%u repeats=%u complete-call-ms=%.6f mean-us=%.6f "
            "repeatable=1 includes-import-export-copy-fp=1 runtime-commit-included=0 runtime-accepted=0\n",
            current, bridgeRepeats, bridgeNs / 1.0e6, bridgeNs / (1.0e3 * bridgeRepeats));
        const uint64_t expectedEnd = at(after, 625, 8) - at(before, 625, 8);
        const auto expectedMac = static_cast<uint32_t>(at(after, 613));
        const auto expectedStatus = static_cast<uint32_t>(at(after, 621));
        const auto actualScalar = directScalar.finish(std::max(drained.cycle, directScalar.deadline()));
        if (actualScalar != detached.scalarStatus) throw std::runtime_error("Detached scalar status diverged");
        std::printf("[play-vu:scalar-status] case=%u match=%u flags=%03x/%03x coverage=cf3\n", current,
            unsigned((expectedStatus & 0xc30) == actualScalar), actualScalar, expectedStatus & 0xc30);
        const bool controlMatches = drained.cycle == expectedEnd && drained.q == at(after, 593) &&
            drained.p == at(after, 597) && drained.mac == (expectedMac & DrainedControl::macMask) &&
            drained.clip == at(after, 617) && drained.status == (expectedStatus & DrainedControl::statusMask);
        std::printf("[play-vu:drained-control] case=%u match=%u cycle=%llu/%llu mac=%04x/%04x "
            "status=%03x/%03x known-status-mask=%03x full-state-accepted=0\n", current, unsigned(controlMatches),
            static_cast<unsigned long long>(drained.cycle), static_cast<unsigned long long>(expectedEnd),
            drained.mac, expectedMac, drained.status, expectedStatus, DrainedControl::statusMask);
        if (!callbackError.empty()) throw std::runtime_error(callbackError);
        if (s.nHasException != MIPS_EXCEPTION_VU_EBIT)
            throw std::runtime_error("Diagnostic did not terminate at E bit");
        // This measures only the isolated hot executor, not a timing-correct bridge.
        constexpr unsigned repeats = 256;
        int64_t elapsedNs = 0;
        for (unsigned repeat = 0; repeat < repeats; ++repeat)
        {
            s = initial;
            std::memcpy(vm->m_vuMem, data.data(), data.size());
            actualPackets.clear();
            callbackError.clear();
            timeline.reset();
            directScalar.reset(initialScalar);
            timelineError.clear();
            const auto start = std::chrono::steady_clock::now();
            vm->m_executor.Execute(2 * 1048576);
            if (!timelineError.empty()) throw std::runtime_error(timelineError);
            timeline.finish(s.pipeTime);
            elapsedNs += std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start).count();
            if (!callbackError.empty() || actualPackets != coldPackets ||
                timeline.packets != coldStreamingPackets || timeline.completionCycles != coldCompletionCycles ||
                std::memcmp(vm->m_vuMem, coldData.data(), coldData.size()) ||
                std::memcmp(&s, &coldFinal, sizeof(s)))
                throw std::runtime_error("Warm execution diverged from cold diagnostic");
        }
        std::printf("[play-vu:diagnostic-timing] case=%u repeats=%u execute-ms=%.6f "
            "per-run-us=%.3f repeatable=1 compatibility-accepted=0 stream-observer=1\n",
            current, repeats, elapsedNs / 1.0e6, elapsedNs / (1.0e3 * repeats));
        unsigned streamingBytes = 0, completionDiffs = 0;
        for (size_t packet = 0; packet < std::min(timeline.packets.size(), expectedPackets.size()); ++packet)
        {
            const auto &actual = timeline.packets[packet];
            const auto &expected = expectedPackets[packet];
            for (size_t offset = 0; offset < std::min(actual.size(), expected.size()); ++offset)
                streamingBytes += actual[offset] != expected[offset];
            if (timeline.completionCycles[packet] != expectedCompletionCycles[packet])
            {
                ++completionDiffs;
                std::printf("[play-vu:transfer-cycle-diff] packet=%zu actual=%llu expected=%llu\n", packet,
                    static_cast<unsigned long long>(timeline.completionCycles[packet]),
                    static_cast<unsigned long long>(expectedCompletionCycles[packet]));
            }
        }
        std::printf("[play-vu:transfer-result] packets=%zu/%zu bytes-equal=%u shared-byte-diffs=%u "
            "cycles-equal=%u completion-diffs=%u finish=%llu events=%u\n",
            timeline.packets.size(), expectedPackets.size(), unsigned(timeline.packets == expectedPackets),
            streamingBytes, unsigned(timeline.completionCycles == expectedCompletionCycles), completionDiffs,
            static_cast<unsigned long long>(timeline.time), timeline.events);
        unsigned auxiliaryDiff = 0;
        const auto compareWord = [&](const char *name, uint32_t actual, size_t offset) {
            const auto expected = static_cast<uint32_t>(at(after, offset));
            auxiliaryDiff += actual != expected;
            std::printf("[play-vu:register] name=%s actual=%08x expected=%08x equal=%u\n",
                name, actual, expected, static_cast<unsigned>(actual == expected));
        };
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            const char *names[] = {"ACC.x", "ACC.y", "ACC.z", "ACC.w"};
            compareWord(names[lane], s.nCOP2A.nV[lane], 577 + lane * 4);
        }
        compareWord("Q", s.nCOP2Q, 593);
        compareWord("P", s.nCOP2P, 597);
        compareWord("I", s.nCOP2I, 601);
        compareWord("R", s.nCOP2R, 605);
        compareWord("PC", s.nPC, 609);
        // Flag mirrors may lag the queued values; report both without pretending
        // either is a complete architectural-state conversion.
        for (const auto &entry : {std::pair<const char *, FLAG_PIPELINE *>{"MAC", &s.pipeMac},
                                 {"sticky", &s.pipeSticky}, {"CLIP", &s.pipeClip}})
        {
            const auto &pipe = *entry.second;
            const auto latest = (pipe.index - 1) & (FLAG_PIPELINE_SLOTS - 1);
            std::printf("[play-vu:flag-pipeline] name=%s latest=%08x ready=%u end-time=%u\n",
                entry.first, pipe.values[latest], pipe.pipeTimes[latest], s.pipeTime);
        }
        std::printf("[play-vu:unmapped-state] mac-mirror=%08x expected-mac=%08x "
            "clip-mirror=%08x expected-clip=%08x sticky-mirror=%08x division=%08x "
            "expected-status=%08x expected-state-cycles=%llu auxiliary-diffs=%u\n",
            s.nCOP2MF, static_cast<uint32_t>(at(after, 613)), s.nCOP2CF,
            static_cast<uint32_t>(at(after, 617)), s.nCOP2SF, s.nCOP2DF,
            static_cast<uint32_t>(at(after, 621)),
            static_cast<unsigned long long>(at(after, 625, 8) - at(before, 625, 8)), auxiliaryDiff);
        const unsigned memoryDiff = differences(vm->m_vuMem, afterData);
        unsigned vfDiff = 0, viDiff = 0;
        for (unsigned reg = 0; reg < 32; ++reg)
            for (unsigned lane = 0; lane < 4; ++lane)
            {
                const auto expected = static_cast<uint32_t>(at(after, 1 + reg * 16 + lane * 4));
                if (s.nCOP2[reg].nV[lane] != expected)
                {
                    ++vfDiff;
                    if (vfDiff <= 8)
                        std::printf("[play-vu:vf-diff] reg=%u lane=%u actual=%08x expected=%08x\n",
                            reg, lane, s.nCOP2[reg].nV[lane], expected);
                }
            }
        for (unsigned reg = 0; reg < 16; ++reg)
            viDiff += (s.nCOP2VI[reg] & 0xffffu) != (at(after, 513 + reg * 4) & 0xffffu);
        unsigned memoryWords = 0, packetBytes = 0;
        for (size_t offset = 0; offset < afterData.size(); offset += 4)
        {
            uint32_t actual = 0;
            std::memcpy(&actual, vm->m_vuMem + offset, 4);
            const auto expected = static_cast<uint32_t>(at(afterData, offset));
            if (actual != expected && ++memoryWords <= 16)
                std::printf("[play-vu:memory-diff] offset=0x%zx actual=%08x expected=%08x\n", offset, actual, expected);
        }
        for (size_t packet = 0; packet < std::min(actualPackets.size(), expectedPackets.size()); ++packet)
        {
            const auto &actual = actualPackets[packet];
            const auto &expected = expectedPackets[packet];
            if (actual.size() != expected.size())
                std::printf("[play-vu:packet-size] packet=%zu actual=%zu expected=%zu\n", packet, actual.size(), expected.size());
            for (size_t offset = 0; offset < std::min(actual.size(), expected.size()); ++offset)
                if (actual[offset] != expected[offset] && ++packetBytes <= 16)
                    std::printf("[play-vu:packet-diff] packet=%zu offset=0x%zx actual=%02x expected=%02x\n",
                        packet, offset, actual[offset], expected[offset]);
        }
        std::printf("[play-vu:diff-summary] memory-words=%u packet-bytes=%u\n", memoryWords, packetBytes);
        std::printf("[play-vu:replay-result] case=%u memory-byte-diffs=%u vf-word-diffs=%u vi-diffs=%u "
            "packets=%zu/%zu packet-bytes-equal=%u slice-timing-unverified=1 pipe=%u pc=0x%x exception=0x%x error=%s\n",
            current, memoryDiff, vfDiff, viDiff, actualPackets.size(), expectedPackets.size(),
            static_cast<unsigned>(actualPackets == expectedPackets), s.pipeTime, s.nPC, s.nHasException,
            callbackError.c_str());
    }
    std::printf("[play-vu:replay-summary] records=%u eligible=%u accepted=0 diagnostic-only=1\n", index, eligible);
    return eligible ? 0 : 4;
}
