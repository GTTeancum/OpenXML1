#include "runtime_adapter.h"
#include "MiniTest.h"
#include "runtime/ps2_vu_compiled_state.h"
#include "runtime/ps2_vu1_replay.h"
#include "runtime_bridge.h"
#include "runtime/ps2_memory.h"
#include "runtime/gs/gs_frontend.h"
#include <array>
#include <cstring>
#include <stdexcept>
#include <sstream>
#include <cstdio>
#include <cfenv>
#include <cstdlib>

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
        tc.Run("Bounded compiled retry preserves prefix effects budgets and rounding", [](TestCase &t)
        {
            const bool retry = std::getenv("PS2X_VU_COMPILED_RETRY") != nullptr;
            for (unsigned variant = 0; variant < 4; ++variant)
            for (uint32_t slice : {1u, 64u, 65u, 72u, 73u, 128u, 4096u})
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                for (auto* fx : {&fast, &reference})
                {
                    fx->vu.state().vf[1][0] = 8.0f;
                    fx->vu.state().vf[2][0] = 4.0f;
                    fx->vu.state().vf[3][0] = 123.0f;
                    fx->pair(96, lowerNop, (8u << 21) | (1u << 11) | (4u << 6) | 0x1c);
                    fx->pair(160, (1u << 25) | (15u << 21) | (3u << 11) | 12u);
                    fx->pair(176, lowerNop, upperNop | end);
                    if (variant == 0) fx->pair(8, 0x80020bbc); // Pending DIV.
                    if (variant == 1)
                    {
                        const uint64_t packet[] = {0x1000000000008001ull, 0xe, 0xffffffff11223344ull, 0x60};
                        std::memcpy(fx->data + 64, packet, sizeof(packet));
                        fx->vu.state().vi[1] = 4;
                        fx->pair(8, 0x80000efc);
                        fx->pair(128, 0x80000efc);
                    }
                    if (variant == 2) fx->pair(8, 0x40000002); // Pending branch.
                    if (variant == 3) fx->pair(8, lowerNop, upperNop | end);
                }
                { ScopedCompiledVuMode disabled(false); fast.start(2); reference.start(2); reference.resume(slice); }
                const auto before = compiledVuCounters();
                struct RestoreRounding
                {
                    int mode = std::fegetround();
                    ~RestoreRounding() { if (mode != -1) std::fesetround(mode); }
                } restoreRounding;
                t.IsTrue(std::fesetround(FE_UPWARD) == 0, "Test rounding mode is available");
                { ScopedCompiledVuMode enabled(true); fast.resume(slice); }
                const bool roundingPreserved = std::fegetround() == FE_UPWARD;
                const auto after = compiledVuCounters();
                t.IsTrue(roundingPreserved, "Retry restores the caller's rounding mode");
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Prefix and compiled tail preserve architecture and elapsed cycles");
                t.IsTrue(!std::memcmp(fast.data, reference.data, 16384), "Prefix and tail memory effects match");
                t.Equals(fast.packets, reference.packets, "Prefix packets are neither lost nor duplicated");
                t.Equals(after.accepted - before.accepted, uint64_t(retry && slice > 72 && variant < 3),
                    "Only supported long slices retry after retiring pending work");
                t.IsTrue(after.attempted - before.attempted <= 2, "Retry count remains bounded");
            }
        });
        tc.Run("FTOI saturates positive overflow without changing masks or flags", [](TestCase &t)
        {
            for (unsigned scale : {0u, 4u, 12u, 15u})
            for (unsigned mask : {1u, 5u, 10u, 15u})
            {
                const uint32_t threshold = 0x4f000000u - (scale << 23);
                for (uint32_t value : {threshold - 1, threshold, threshold + 1,
                    threshold | 0x80000000u, 0x7f7fffffu, 0xff7fffffu, 0x7f800000u,
                    0xff800000u, 0x7fc12345u, 0xffc12345u, 1u, 0x80000001u})
                {
                    Fixture fast, reference;
                    if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                    for (auto *fx : {&fast, &reference})
                    {
                        for (unsigned lane = 0; lane < 4; ++lane)
                        {
                            const uint32_t bits = value ^ ((lane & 1) ? 0x80000000u : 0u);
                            std::memcpy(&fx->vu.state().vf[1][lane], &bits, 4);
                            fx->vu.state().vf[2][lane] = float(lane + 1);
                        }
                        const unsigned variant = scale == 0 ? 0 : scale == 4 ? 1 : scale == 12 ? 2 : 3;
                        fx->pair(8, lowerNop, (mask << 21) | (2u << 16) | (1u << 11) | 0x17c | variant);
                        fx->pair(64, lowerNop, upperNop | end);
                    }
                    { ScopedCompiledVuMode disabled(false); fast.start(1); reference.start(budget); }
                    std::string reason;
                    t.IsTrue(fast.compiled(reason), "Conversion uses compiled producer");
                    t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "All lanes, masks, flags and cycles match");
                }
            }
        });
        tc.Run("Immediate storage uses the runtime finite operand rules", [](TestCase &t)
        {
            for (uint32_t bits : {0u, 0x80000000u, 1u, 0x800003bfu, 0x007fffffu,
                0x00800000u, 0x3f800001u, 0x7f7fffffu, 0x7f800000u, 0xff800000u, 0x7fc12345u, 0xffc12345u})
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                for (auto *fx : {&fast, &reference})
                {
                    fx->pair(8, bits, upperNop | 0x80000000u);
                    fx->pair(16, lowerNop, (8u << 21) | (3u << 6) | 0x22);
                    fx->pair(64, lowerNop, upperNop | end);
                }
                { ScopedCompiledVuMode disabled(false); fast.start(1); reference.start(budget); }
                std::string reason;
                t.IsTrue(fast.compiled(reason), "Immediate uses compiled producer");
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Immediate storage and arithmetic match bitwise");
            }
        });
        tc.Run("Paired immediate loads preserve the old I value for upper arithmetic", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            for (auto *fx : {&fast, &reference})
            {
                fx->pair(8, 0x3f800001, upperNop | 0x80000000u);
                fx->pair(16, 0x3f800000, (4u << 21) | (25u << 6) | 0x22 | 0x80000000u);
                fx->pair(24, lowerNop, (8u << 21) | (25u << 6) | 0x22);
                fx->pair(64, lowerNop, upperNop | end);
            }
            { ScopedCompiledVuMode disabled(false); fast.start(1); reference.start(budget); }
            std::string reason;
            t.IsTrue(fast.compiled(reason), "Paired I workload uses compiled producer");
            t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Old and new I values match reference");
            t.Equals(fast.vu.state().vf[25][1], reference.vu.state().vf[25][1], "Paired ADDi reads previous immediate");
        });
        tc.Run("Q waits preserve scalar visibility and elapsed execution time", [](TestCase &t)
        {
            for (unsigned operation = 0; operation < 3; ++operation)
            for (unsigned gap : {0u, 2u, 6u, 12u})
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                for (auto *fx : {&fast, &reference})
                {
                    fx->vu.state().vf[1][0] = 8.0f;
                    fx->vu.state().vf[2][0] = 4.0f;
                    fx->pair(8, 0x800003bcu | operation | (operation == 1 ? 0u : (1u << 11)) | (2u << 16));
                    fx->pair(16 + gap * 8, 0x800003bf); // WAITQ
                    fx->pair(24 + gap * 8, lowerNop, (8u << 21) | (1u << 11) | (3u << 6) | 0x1c); // MULq vf3.x,vf1.x
                    fx->pair(64 + gap * 8, lowerNop, upperNop | end);
                }
                { ScopedCompiledVuMode disabled(false); fast.start(1); reference.start(budget); }
                std::string reason;
                t.IsTrue(fast.compiled(reason), "Scalar wait uses compiled producer");
                if (!sameArchitecture(fast.vu.state(), reference.vu.state()))
                    std::printf("[q-wait-diff] op=%u gap=%u cycles=%llu/%llu q=%.9g/%.9g\n",
                        operation, gap, static_cast<unsigned long long>(fast.vu.state().cycles),
                        static_cast<unsigned long long>(reference.vu.state().cycles), fast.vu.state().q, reference.vu.state().q);
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Q values, flags and completion time match");
            }
        });
        tc.Run("Q stalls age pending writes and guard arithmetic delay slots", [](TestCase &t)
        {
            for (unsigned variant = 0; variant < 5; ++variant)
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                const uint32_t add3 = (8u << 21) | (1u << 11) | (3u << 6) | 0x28;
                for (auto *fx : {&fast, &reference})
                {
                    fx->vu.state().vf[1][0] = 8.0f;
                    fx->vu.state().vf[2][0] = 4.0f;
                    fx->pair(8, 0x80020bbc, variant == 0 ? add3 : upperNop);
                    fx->pair(16, 0x800003bf, variant == 1 ?
                        ((8u << 21) | (1u << 11) | (3u << 6) | 0x1c) : upperNop);
                    if (variant == 2 || variant == 3)
                    {
                        fx->pair(16, 0x40000002, variant == 3 ? add3 : upperNop); // B 40
                        fx->pair(24, 0x800003bf);
                    }
                    if (variant == 4) fx->pair(16, 0x800003bf, upperNop | 0x80000000u);
                    fx->pair(40, lowerNop, (8u << 21) | (3u << 11) | (4u << 6) | 0x28);
                    fx->pair(80, lowerNop, upperNop | end);
                }
                { ScopedCompiledVuMode disabled(false); fast.start(1); reference.start(budget); }
                const auto initial = fast.vu.state();
                std::string reason;
                const bool accepted = fast.compiled(reason);
                t.Equals(accepted, variant != 3, "Only busy Q after local delay-slot arithmetic falls back");
                if (!accepted)
                {
                    t.IsTrue(sameArchitecture(initial, fast.vu.state()), "Rejected private work is not published");
                    ScopedCompiledVuMode disabled(false);
                    fast.resume(budget);
                }
                if (!sameArchitecture(fast.vu.state(), reference.vu.state()))
                    std::printf("[q-edge-diff] variant=%u cycles=%llu/%llu q=%.9g/%.9g vf3=%.9g/%.9g vf4=%.9g/%.9g\n",
                        variant, static_cast<unsigned long long>(fast.vu.state().cycles),
                        static_cast<unsigned long long>(reference.vu.state().cycles), fast.vu.state().q, reference.vu.state().q,
                        fast.vu.state().vf[3][0], reference.vu.state().vf[3][0], fast.vu.state().vf[4][0], reference.vu.state().vf[4][0]);
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Wait, paired upper and incoming VF results match");
            }
        });
        tc.Run("An incoming register wait ages the other pending register writes", [](TestCase &t)
        {
            const unsigned orders[][3] = {{0,1,2}, {0,2,1}, {1,0,2}, {1,2,0}, {2,0,1}, {2,1,0}};
            for (unsigned first : {7u, 9u, 15u, 23u})
            for (const auto &order : orders)
            for (unsigned gap = 0; gap < 3; ++gap)
            {
                Fixture fast, reference;
                if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
                for (auto *fx : {&fast, &reference})
                {
                    for (unsigned reg = 1; reg <= 3; ++reg)
                    {
                        fx->vu.state().vf[reg][0] = float(reg);
                        fx->vu.state().vf[reg][3] = 1.0f;
                        fx->pair((reg - 1) * 8, lowerNop,
                            (15u << 21) | (reg << 11) | ((first + reg - 1) << 6) | 0x28);
                    }
                    unsigned pc = 24;
                    for (unsigned read : order)
                    {
                        const auto reg = first + read;
                        fx->pair(pc, lowerNop, (15u << 21) | (reg << 16) | (reg << 11) | 0x1ff);
                        pc += 8 * (gap + 1);
                    }
                    fx->pair(pc, lowerNop, upperNop | end);
                }
                { ScopedCompiledVuMode disabled(false); fast.start(3); reference.start(3); reference.resume(budget); }
                std::string reason;
                t.IsTrue(fast.compiled(reason), "Pending triple write uses compiled producer");
                t.Equals(fast.vu.state().cycles, reference.vu.state().cycles, "Wait time is charged once, not once per reader");
                t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "All completed registers and flags match");
            }
        });
        tc.Run("Unsupported EFU matrix work falls back without publishing partial results", [](TestCase &t)
        {
            Fixture fast, reference;
            if (!fast.init() || !reference.init()) { t.Fail("Fixtures initialize"); return; }
            for (auto *fx : {&fast, &reference})
            {
                for (unsigned row = 1; row <= 4; ++row) fx->vu.state().vf[row][row - 1] = 1.0f;
                fx->vu.state().vf[8][0] = 3.0f;
                fx->vu.state().vf[8][1] = 4.0f;
                fx->vu.state().vf[8][3] = 1.0f;
                fx->pair(0, lowerNop, 0x01e809bc); // MULAx ACC,vf1,vf8
                fx->pair(8, lowerNop, 0x01e810bd); // MADDAy ACC,vf2,vf8
                fx->pair(16, lowerNop, 0x01e818be); // MADDAz ACC,vf3,vf8
                fx->pair(24, lowerNop, 0x01e020bf); // MADDAw ACC,vf4,vf0
                fx->pair(32, lowerNop, 0x01c06bcb); // MADDw vf15,vf13,vf0
                fx->pair(40, lowerNop, 0x01c00229); // MADD vf8,vf0,vf0
                fx->pair(64, 0x81c07f3f); // ERLENG vf15
                fx->pair(72, 0x800007bf); // WAITP
                fx->pair(80, 0x81ec067c); // MFP vf12
                fx->pair(88, lowerNop, upperNop | end);
            }
            { ScopedCompiledVuMode disabled(false); reference.start(budget); }
            const auto before = compiledVuCounters();
            { ScopedCompiledVuMode enabled(true); fast.start(budget); }
            t.Equals(compiledVuCounters().accepted, before.accepted, "EFU workload remains on reference engine");
            if (!sameArchitecture(fast.vu.state(), reference.vu.state()))
            {
                const auto &a = fast.vu.state(); const auto &b = reference.vu.state();
                std::printf("[matrix-diff] cycles=%llu/%llu p=%.9g/%.9g mac=%x/%x status=%x/%x pc=%x/%x\n",
                    static_cast<unsigned long long>(a.cycles), static_cast<unsigned long long>(b.cycles),
                    a.p, b.p, a.mac, b.mac, a.status, b.status, a.pc, b.pc);
                for (unsigned r = 0; r < 32; ++r) for (unsigned lane = 0; lane < 4; ++lane)
                    if (std::memcmp(&a.vf[r][lane], &b.vf[r][lane], sizeof(float)))
                        std::printf("[matrix-vf] reg=%u lane=%u value=%.9g/%.9g\n", r, lane, a.vf[r][lane], b.vf[r][lane]);
            }
            t.IsTrue(sameArchitecture(fast.vu.state(), reference.vu.state()), "Matrix and scalar results match reference");
            t.Equals(fast.vu.state().vf[8][0], 3.0f, "Accumulator x survives chained operations");
            t.Equals(fast.vu.state().vf[8][1], 4.0f, "Accumulator y survives chained operations");
            t.IsTrue(fast.vu.state().p > 0.19f && fast.vu.state().p < 0.21f, "Reciprocal vector length is one fifth");
        });
        tc.Run("Shadow audit detects wrong state memory and timed packets without live publication", [](TestCase &t)
        {
            Fixture fx;
            if (!fx.init()) { t.Fail("Fixture initializes"); return; }
            signalProgram(fx, 0);
            { ScopedCompiledVuMode disabled(false); fx.start(1); }
            const auto input = VUCompiledState::capture(fx.vu, budget);
            if (!input) { t.Fail("Pending program captured"); return; }
            std::array<uint8_t, 16384> code, data;
            std::memcpy(code.data(), fx.code, code.size());
            std::memcpy(data.data(), fx.data, data.size());
            PlayVuRuntimeBridge bridge;
            const auto result = bridge.evaluate(*input, code, data);
            if (!result.evaluated || result.output.packets.empty()) { t.Fail("Producer staged packet"); return; }
            const auto initial = fx.vu.state();
            for (unsigned variant = 0; variant < 5; ++variant)
            {
                auto altered = result.output;
                if (variant == 1) altered.state.vf[3][0] += 1.0f;
                if (variant == 2) altered.data[128] ^= 1;
                if (variant == 3) altered.packets[0].bytes[16] ^= 1;
                if (variant == 4) ++altered.packets[0].cycle;
                std::ostringstream failure(std::ios::binary);
                std::string reason;
                const bool valid = VUReplay::verifyCompiledDrain(fx.vu, *input, altered,
                    fx.code, fx.data, fx.gs, 123, &failure, reason);
                t.Equals(valid, variant == 0, "Audit accepts correct output and rejects corruption");
                t.Equals(failure.str().empty(), variant == 0, "Only mismatch writes replay");
                t.IsTrue(sameArchitecture(initial, fx.vu.state()), "Live state unchanged");
                t.IsTrue(!std::memcmp(data.data(), fx.data, data.size()), "Live memory unchanged");
                t.Equals(fx.packets, 0u, "No packet reaches live GS");
                if (variant != 0)
                {
                    std::istringstream replay(failure.str(), std::ios::binary);
                    const auto verification = VUReplay::replay(replay, 1);
                    t.IsTrue(verification.error.empty() && verification.cases == 1,
                        "Saved baseline failure record independently replays");
                }
            }
        });
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
