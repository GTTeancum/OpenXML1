#include "runtime_adapter.h"
#include "MiniTest.h"
#include "runtime/ps2_vu_compiled_state.h"
#include "runtime/ps2_memory.h"
#include "runtime/gs/gs_frontend.h"
#include <array>
#include <cstring>
#include <stdexcept>

namespace
{
constexpr uint32_t lowerNop = 0x8000033c, upperNop = 0x2ff, end = 0x40000000;
constexpr uint32_t budget = 1048576;
struct Fixture
{
    PS2Memory memory;
    GS gs;
    VU1Interpreter vu;
    uint8_t *code = nullptr, *data = nullptr;
    unsigned packets = 0;
    bool init()
    {
        if (!memory.initialize()) return false;
        gs.init(memory.getGSVRAM(), PS2_GS_VRAM_SIZE, &memory.gs());
        memory.setGifPacketCallback([this](const uint8_t *bytes, uint32_t size) {
            ++packets;
            gs.processGIFPacket(bytes, size);
        });
        code = memory.getVU1Code();
        data = memory.getVU1Data();
        std::memset(data, 0, 16384);
        for (uint32_t pc = 0; pc < 16384; pc += 8) pair(pc);
        return true;
    }
    void pair(uint32_t pc, uint32_t lower = lowerNop, uint32_t upper = upperNop)
    {
        memory.write64(PS2_VU1_CODE_BASE + pc, uint64_t(lower) | (uint64_t(upper) << 32));
    }
    void start(uint32_t cycles) { vu.execute(code, 16384, data, 16384, gs, &memory, 0, 7, 11, cycles); }
    void resume(uint32_t cycles) { vu.resume(code, 16384, data, 16384, gs, &memory, 7, 11, cycles); }
    bool compiled(std::string &reason, uint32_t cycles = budget)
    {
        return tryCompiledVuDrain(vu, code, 16384, data, 16384, gs, &memory, cycles, &reason);
    }
};

bool sameArchitecture(const VU1State &a, const VU1State &b)
{
    if (std::memcmp(a.vf, b.vf, sizeof(a.vf)) || std::memcmp(a.acc, b.acc, sizeof(a.acc)) ||
        std::memcmp(&a.q, &b.q, sizeof(float)) || std::memcmp(&a.p, &b.p, sizeof(float)) ||
        std::memcmp(&a.i, &b.i, sizeof(float)) || a.r != b.r || a.mac != b.mac ||
        a.status != b.status || a.clip != b.clip || a.pc != b.pc || a.cycles != b.cycles ||
        a.top != b.top || a.itop != b.itop || a.ebit != b.ebit ||
        a.haltAfterDelaySlot != b.haltAfterDelaySlot || a.branchPending != b.branchPending ||
        a.dBitEnabled != b.dBitEnabled || a.tBitEnabled != b.tBitEnabled ||
        a.stoppedByD != b.stoppedByD || a.stoppedByT != b.stoppedByT) return false;
    if (a.branchPending && (a.branchTarget != b.branchTarget || a.branchDelay != b.branchDelay)) return false;
    for (unsigned i = 0; i < 16; ++i)
        if (uint16_t(a.vi[i]) != uint16_t(b.vi[i])) return false;
    return true;
}

void signalProgram(Fixture &fx, unsigned tail)
{
    // Packed A+D SIGNAL, transmitted by XGKICK from qword four.
    const uint64_t packet[] = {0x1000000000008001ull, 0xe, 0xffffffff11223344ull, 0x60};
    std::memcpy(fx.data + 64, packet, sizeof(packet));
    fx.vu.state().vi[1] = 4;
    fx.pair(8, 0x80000efc);
    fx.pair(16, (1u << 25) | (15u << 21) | (3u << 11) | 8u); // SQ vf3,8(vi0)
    fx.vu.state().vf[3][0] = 123.0f;
    fx.pair((tail + 3) * 8, lowerNop, upperNop | end);
}
}

void register_compiled_vu_producer_tests()
{
    MiniTest::Case("PS2VU1CompiledProducer", [](TestCase &tc)
    {
#if defined(PS2X_TEST_COMPILED_VU_HOOK)
        tc.Run("Hybrid packet storage reuse matches full and sliced observable results", [](TestCase &t)
        {
            for (uint32_t slice : {4096u, 1u, 3u, 8u, 64u})
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                const uint32_t addresses[] = {0, 8192, 12288}, sizes[] = {4096, 32, 80};
                std::vector<std::vector<uint8_t>> expected, actual;
                for (auto *fx : {&fast, &reference})
                {
                    for (uint32_t i = 0; i < 3; ++i)
                    {
                        fx->vu.state().vi[i + 1] = addresses[i] / 16;
                        const uint64_t tag = (uint64_t(2) << 58) | 0x8000 | (sizes[i] / 16 - 1);
                        std::memcpy(fx->data + addresses[i], &tag, 8);
                        for (uint32_t byte = 16; byte < sizes[i]; ++byte)
                            fx->data[addresses[i] + byte] = uint8_t(byte * 13 + i * 71);
                        fx->pair(i * 8, 0x800006fcu | ((i + 1) << 11));
                    }
                    fx->pair(24, 0, upperNop | end);
                    fx->pair(32, 0);
                }
                fast.memory.setGifPacketCallback([&](const uint8_t *bytes, uint32_t size) {
                    actual.emplace_back(bytes, bytes + size);
                });
                reference.memory.setGifPacketCallback([&](const uint8_t *bytes, uint32_t size) {
                    expected.emplace_back(bytes, bytes + size);
                });
                const auto before = compiledVuCounters();
                {
                    ScopedCompiledVuMode enabled(true);
                    fast.start(4096);
                }
                t.Equals(compiledVuCounters().accepted, before.accepted + 1, "Packet workload really uses compiled engine");
                {
                    ScopedCompiledVuMode disabled(false);
                    reference.start(slice);
                    for (unsigned calls = 0; reference.vu.isRunning() && calls < 4096; ++calls)
                        reference.resume(slice);
                }
                t.IsTrue(!fast.vu.isRunning() && !reference.vu.isRunning(), "Both drains terminate");
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()),
                    "Packet reuse preserves every register and exact completion cycle across slice sizes");
                t.IsTrue(actual == expected && actual.size() == 3, "Packet bytes and boundaries match exactly");
                t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Packet workload data matches");
            }
        });
        tc.Run("Runtime execution hook is opt-in and scoped without changing fallback", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            signalProgram(fast, 0);
            signalProgram(reference, 0);
            const auto before = compiledVuCounters();
            const bool prior = compiledVuEnabled();
            {
                ScopedCompiledVuMode disabled(false);
                reference.start(budget);
                t.Equals(compiledVuCounters().attempted, before.attempted, "Disabled hook does not call producer");
                {
                    ScopedCompiledVuMode enabled(true);
                    fast.start(budget);
                    t.Equals(compiledVuCounters().accepted, before.accepted + 1, "Real run entry commits compiled work");
                    t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Hook result matches normal execution");
                    t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Hook memory matches");
                    t.Equals(fast.packets, 1u, "Hook publishes exactly once");
                    t.Equals(uint32_t(fast.memory.gs().siglblid), 0x11223344u, "Hook reaches real GS");
                }
                t.IsTrue(!compiledVuEnabled(), "Inner override restores disabled outer mode");
            }
            t.Equals(compiledVuEnabled(), prior, "Scoped test restores original mode");
        });
#endif
        tc.Run("Committed pending arithmetic resumes and consumes signed VI results", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            for (unsigned variant = 0; variant < 3; ++variant)
            {
                for (auto *fx : {&fast, &reference})
                {
                    fx->vu.reset();
                    std::memset(fx->data, 0, 16384);
                    fx->vu.state().vf[1][0] = 1.0f;
                    fx->vu.state().vf[2][0] = variant == 2 ? 4.0f : 2.0f;
                    fx->pair(0, lowerNop, (15u << 21) | (2u << 16) | (1u << 11) | (3u << 6) | 0x28);
                    // ILW.x vi5,10(vi0), followed after E by MFIR.x vf4,vi5.
                    fx->pair(8, (4u << 25) | (8u << 21) | (5u << 16) | 10u);
                    const uint32_t signedWord = variant == 2 ? 0xffff800cu : 0x00008000u;
                    std::memcpy(fx->data + 160, &signedWord, 4);
                    fx->pair(24, lowerNop, upperNop | end);
                    fx->pair(40, 0x800003fdu | (8u << 21) | (4u << 16) | (5u << 11));
                    fx->pair(56, lowerNop, upperNop | end);
                }
                fast.start(1);
                const auto entry = VUCompiledState::capture(fast.vu, budget);
                t.IsTrue(entry && entry->vfMask && entry->flagMask, "Real pending VF/flags enter producer");
                reference.start(budget);
                std::string reason;
                const bool accepted = fast.compiled(reason);
                t.IsTrue(accepted, "Producer commits: " + reason);
                if (!accepted) return;
                t.IsTrue(!fast.vu.isRunning() && sameArchitecture(fast.vu.state(), reference.vu.state()),
                    "Committed architectural state matches interpreter");
                t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Committed memory matches interpreter");
                fast.resume(1);
                reference.resume(1);
                const auto resumed = VUCompiledState::capture(fast.vu, budget);
                t.IsTrue(resumed.has_value(), "Runtime resumes with consistent pending queues");
                fast.resume(budget);
                reference.resume(budget);
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()),
                    "Interpreter continuation matches after compiled handoff");
                uint32_t moved = 0;
                std::memcpy(&moved, &fast.vu.state().vf[4][0], 4);
                t.Equals(moved, variant == 2 ? 0xffff800cu : 0xffff8000u, "MFIR observes signed 16-bit VI value");
            }
        });
        tc.Run("Compiled graphics and stores publish through the real runtime", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            signalProgram(fast, 0);
            signalProgram(reference, 0);
            fast.start(1);
            reference.start(budget);
            std::string reason;
            const bool accepted = fast.compiled(reason);
            t.IsTrue(accepted, "Graphics producer commits: " + reason);
            if (!accepted) return;
            t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Graphics drain state matches");
            t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Compiled store matches");
            t.Equals(uint32_t(fast.memory.gs().siglblid), 0x11223344u, "Published packet reaches GS");
            t.Equals(fast.memory.gs().siglblid, reference.memory.gs().siglblid, "GS side effect matches interpreter");
            t.Equals(fast.packets, 1u, "Compiled packet publishes exactly once");
            t.IsTrue((fast.memory.gs().csr & 1) != 0, "GS SIGNAL is raised");
        });
        tc.Run("Rejected producer leaves state memory graphics and continuation intact", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            signalProgram(fast, 80);
            signalProgram(reference, 80);
            fast.start(1);
            reference.start(1);
            const auto before = fast.vu.state();
            const auto entry = VUCompiledState::capture(fast.vu, budget);
            std::array<uint8_t, 16384> data;
            std::memcpy(data.data(), fast.data, data.size());
            for (uint32_t limit : {64u, 65u})
            {
                std::string reason;
                t.IsTrue(!fast.compiled(reason, limit) && !reason.empty(), "Short or exceeded budget rejects");
                t.IsTrue(!std::memcmp(&before, &fast.vu.state(), sizeof(before)) && fast.vu.isRunning(),
                    "Rejected producer preserves exact visible state and running status");
                const auto after = VUCompiledState::capture(fast.vu, budget);
                t.IsTrue(entry && after && entry->vfWrites == after->vfWrites && entry->flags == after->flags &&
                    entry->nextSequence == after->nextSequence && entry->vfReady == after->vfReady &&
                    entry->vfLatest == after->vfLatest, "Rejected producer preserves live pipeline metadata");
                t.IsTrue(!std::memcmp(data.data(), fast.data, data.size()), "Private stores never leak after rejection");
                t.Equals(uint32_t(fast.memory.gs().siglblid), 0u, "Staged SIGNAL never escapes after rejection");
                t.Equals(fast.packets, 0u, "Rejected output submits no packets");
                t.IsTrue((fast.memory.gs().csr & 1) == 0, "GS remains untouched");
            }
            fast.resume(budget);
            reference.resume(budget);
            t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Fallback continuation matches");
            t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Fallback data matches");
            t.Equals(uint32_t(fast.memory.gs().siglblid), 0x11223344u, "Fallback publishes the original packet");
            t.Equals(fast.packets, 1u, "Fallback publishes exactly once");
        });
        tc.Run("Publication exceptions propagate instead of requesting fallback", [](TestCase &t)
        {
            Fixture fx;
            if (!fx.init()) { t.Fail("Fixture initializes"); return; }
            signalProgram(fx, 0);
            fx.start(1);
            unsigned submissions = 0;
            fx.memory.setGifPacketCallback([&](const uint8_t *, uint32_t) {
                ++submissions;
                throw std::runtime_error("Synthetic graphics sink failure");
            });
            bool propagated = false;
            try
            {
                std::string reason;
                fx.compiled(reason);
            }
            catch (const std::runtime_error &e)
            {
                propagated = std::string(e.what()) == "Synthetic graphics sink failure";
            }
            t.IsTrue(propagated, "Post-commit exception is not converted to false/fallback");
            t.Equals(submissions, 1u, "Submission is not retried");
            t.IsTrue(!fx.vu.isRunning(), "Completed runtime state remains committed");
            float stored = 0;
            std::memcpy(&stored, fx.data + 128, 4);
            t.Equals(stored, 123.0f, "Committed memory proves why fallback would be unsafe");
        });
    });
}
