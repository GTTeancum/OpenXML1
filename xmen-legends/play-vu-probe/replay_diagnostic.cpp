#define NOMINMAX
#include "replay_diagnostic.h"
#include "transfer_timeline.h"
#include "TestVm.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
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
bool quiescent(const Bytes &state)
{
    if (state.size() != 4682 || state[0] != 1 || state[2271] != 0 || state[647] != 0 ||
        state[633] != 0 || state[634] != 0 || state[635] != 0 || state[636] != 0 ||
        state[637] != 0 || state[638] != 0 ||
        state[4678] != 0 || state[4679] != 1 ||
        state[4680] != 0 || state[4681] != 0)
        return false;
    for (size_t offset : {size_t(968), size_t(985), size_t(1002)})
        if (state[offset] != 0) return false;
    for (size_t offset = 2251; offset < 2271; offset += 4)
        if (at(state, offset) != 0) return false;
    // Reject inconsistent queue masks instead of silently dropping live entries.
    for (size_t slot = 0; slot < 8; ++slot)
        if (state[656 + slot * 37 + 32] || state[1003 + slot * 30 + 29] ||
            state[1803 + slot * 22 + 21] || state[1979 + slot * 34 + 33]) return false;
    for (size_t slot = 0; slot < 16; ++slot)
        if (state[1243 + slot * 35 + 34]) return false;
    if (state[4677] && state[4676] >= 16) return false;
    const uint64_t cycle = at(state, 4640, 8);
    for (size_t offset = 2272; offset < 3456; offset += 8)
        if (at(state, offset, 8) > cycle) return false;
    return at(state, 4656, 8) <= cycle;
}

void initializeFlags(FLAG_PIPELINE &pipeline, uint32_t value)
{
    pipeline = {};
    std::fill(std::begin(pipeline.values), std::end(pipeline.values), value);
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

int replayDiagnostic(const char *path)
{
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
        if (budget <= 64 || !quiescent(before)) continue;
        ++eligible;
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        std::memcpy(vm->m_microMem, code.data(), code.size());
        std::memcpy(vm->m_vuMem, data.data(), data.size());
        auto &s = vm->m_cpu.m_State;
        std::memcpy(s.nCOP2, before.data() + 1, 512);
        std::memcpy(s.nCOP2VI, before.data() + 513, 64);
        std::memcpy(&s.nCOP2A, before.data() + 577, 16);
        s.nCOP2Q = static_cast<uint32_t>(at(before, 593));
        s.nCOP2P = static_cast<uint32_t>(at(before, 597));
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
        if (before[4677])
        {
            s.savedNextBlockIntRegIdx = before[4676];
            s.savedNextBlockIntRegVal = static_cast<uint32_t>(at(before, 4672));
        }
        std::vector<Bytes> actualPackets, expectedPackets;
        std::string callbackError;
        TransferTimeline timeline(vm->m_vuMem);
        std::string timelineError;
        vm->m_cpu.m_vuMemoryObserver = [&](CMIPS *cpu, uint32 pc, uint32 cycle, uint32 phase) {
            if (!timelineError.empty()) return;
            try {
                ++timeline.events;
                if (phase == 2) timeline.kick(cpu->m_State.xgkickAddress, cycle);
                else timeline.advance(cycle);
            } catch (const std::exception &e) {
                timelineError = std::string(e.what()) + " pc=" + std::to_string(pc) +
                    " cycle=" + std::to_string(cycle) + " phase=" + std::to_string(phase);
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
        const Bytes coldData(vm->m_vuMem, vm->m_vuMem + 16384);
        const auto coldPackets = actualPackets;
        const auto coldStreamingPackets = timeline.packets;
        const auto coldCompletionCycles = timeline.completionCycles;
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
