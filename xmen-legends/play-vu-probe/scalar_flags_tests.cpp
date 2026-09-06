#include "compiled_session.h"
#include "VuAssembler.h"
#include "TestVm.h"
#include <cstdio>
#include <cstring>
#include <xmmintrin.h>

static bool rsqrtQuotientTests(CompiledVuSession &session)
{
    struct Scope {
        unsigned saved = _mm_getcsr();
        Scope() { _mm_setcsr((saved & ~0x603fu) | 0x6000u | 0x8040u | 0x1f80u); }
        ~Scope() { _mm_setcsr(saved); }
    } scope;
    unsigned cases = 0;
    const float inputs[][2] = {{3.0f,2.0f}, {7.0f,3.0f}, {11.0f,5.0f}, {2.0f,0.125f}};
    for (const auto &input : inputs)
    for (unsigned signs = 0; signs < 4; ++signs)
    for (unsigned fsf = 0; fsf < 4; ++fsf)
    for (unsigned ftf = 0; ftf < 4; ++ftf)
    {
        const float numerator = (signs & 1) ? -input[0] : input[0];
        const float denominator = (signs & 2) ? -input[1] : input[1];
        const auto quotient = _mm_div_ss(_mm_set_ss(numerator), _mm_sqrt_ss(_mm_set_ss(input[1])));
        float expected = _mm_cvtss_f32(quotient);
        uint32_t expectedBits;
        std::memcpy(&expectedBits, &expected, sizeof(expectedBits));
        alignas(16) std::array<uint8_t, 16384> code{}, data{};
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        for (unsigned cycle = 0; cycle < 17; ++cycle)
        {
            auto upper = CVuAssembler::Upper::NOP(), lower = CVuAssembler::Lower::NOP();
            if (cycle == 0) lower = 0x800003be | (1u << 11) | (2u << 16) | (fsf << 21) | (ftf << 23);
            if (cycle == 12 || cycle == 13)
                upper = CVuAssembler::Upper::MULq(CVuAssembler::DEST_W,
                    cycle == 12 ? CVuAssembler::VF3 : CVuAssembler::VF4, CVuAssembler::VF0);
            if (cycle == 13) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI1, 0xc30);
            if (cycle == 15) upper |= CVuAssembler::Upper::E_BIT;
            a.Write(upper, lower);
        }
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = initial.nCOP2Q = initial.pipeQ.heldValue = 0x3f800000;
        std::memcpy(&initial.nCOP2[1].nV[fsf], &numerator, sizeof(numerator));
        std::memcpy(&initial.nCOP2[2].nV[ftf], &denominator, sizeof(denominator));
        const auto result = session.run(code, data, initial, 1048576);
        if (!result.executed || result.state.nCOP2[3].nV3 != 0x3f800000 ||
            result.state.nCOP2[4].nV3 != expectedBits || result.state.nCOP2Q != expectedBits ||
            result.state.nCOP2VI[1] != ((signs & 2) ? 0x410u : 0u))
        {
            std::printf("[play-vu:rsqrt-quotient-error] signs=%u fsf=%u ftf=%u before=%08x after=%08x expected=%08x status=%03x reason=%s\n",
                signs, fsf, ftf, result.state.nCOP2[3].nV3, result.state.nCOP2[4].nV3,
                expectedBits, result.state.nCOP2VI[1], result.reason.c_str());
            return false;
        }
        ++cases;
    }
    std::printf("[play-vu:rsqrt-quotient] passed=1 cases=%u latency=13 components=1 signs=1\n", cases);
    return true;
}

static bool stickyResetTests(CompiledVuSession &session)
{
    for (uint32_t reset : {0u, 0x40u, 0x80u, 0xc0u})
    for (bool laterArithmetic : {false, true})
    {
        alignas(16) std::array<uint8_t, 16384> code{}, data{};
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        for (unsigned cycle = 0; cycle < 9; ++cycle)
        {
            auto upper = CVuAssembler::Upper::NOP();
            auto lower = CVuAssembler::Lower::NOP();
            if (cycle == 0 || (cycle == 2 && laterArithmetic))
                upper = CVuAssembler::Upper::ADDbc(CVuAssembler::DEST_X, CVuAssembler::VF4,
                    cycle == 0 ? CVuAssembler::VF1 : CVuAssembler::VF2,
                    CVuAssembler::VF0, CVuAssembler::BC_X);
            if (cycle == 1) lower = 0x2a000000 | reset;
            if (cycle >= 2 && cycle <= 6)
                lower = CVuAssembler::Lower::FSAND(static_cast<CVuAssembler::VI_REGISTER>(cycle - 1), 0xc3);
            if (cycle == 7) upper |= CVuAssembler::Upper::E_BIT;
            a.Write(upper, lower);
        }
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = 0x3f800000;
        initial.nCOP2[2].nV0 = 0xbf800000;
        const auto result = session.run(code, data, initial, 1048576);
        const uint32_t expected[] = {0, 0, 0x41, reset | 1,
            laterArithmetic ? (reset | 0x82) : (reset | 1)};
        bool passed = result.executed;
        for (unsigned i = 0; i < 5; ++i) passed &= result.state.nCOP2VI[i + 1] == expected[i];
        std::printf("[play-vu:sticky-reset] reset=%02x later=%u passed=%u reads=%02x,%02x,%02x,%02x,%02x\n",
            reset, unsigned(laterArithmetic), unsigned(passed), result.state.nCOP2VI[1],
            result.state.nCOP2VI[2], result.state.nCOP2VI[3], result.state.nCOP2VI[4], result.state.nCOP2VI[5]);
        if (!passed) return false;
    }
    return true;
}

static bool pairedStatusTests(CompiledVuSession &session)
{
    for (uint32_t reset : {0u, 0x40u, 0x80u, 0xc0u})
    for (bool laterArithmetic : {false, true})
    for (bool immediatePayload : {false, true})
    {
        alignas(16) std::array<uint8_t, 16384> code{}, data{};
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        for (unsigned cycle = 0; cycle < 13; ++cycle)
        {
            auto upper = CVuAssembler::Upper::NOP();
            auto lower = CVuAssembler::Lower::NOP();
            if (cycle == 0 || cycle == 1 || (cycle == 3 && laterArithmetic))
                upper = CVuAssembler::Upper::ADDbc(CVuAssembler::DEST_X, CVuAssembler::VF4,
                    cycle == 0 ? CVuAssembler::VF0 : CVuAssembler::VF1,
                    CVuAssembler::VF0, CVuAssembler::BC_X);
            if (cycle == 1) lower = 0x2a000000 | reset;
            if (cycle == 1 && immediatePayload) upper |= CVuAssembler::Upper::I_BIT;
            if (cycle == 4 || cycle == 5 || cycle == 7)
                lower = CVuAssembler::Lower::FSAND(static_cast<CVuAssembler::VI_REGISTER>(cycle - 3), 0xc3);
            if (cycle == 6) lower = CVuAssembler::Lower::FMAND(CVuAssembler::VI3, CVuAssembler::VI15);
            if (cycle == 11) upper |= CVuAssembler::Upper::E_BIT;
            a.Write(upper, lower);
        }
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = 0x3f800000;
        initial.nCOP2[1].nV0 = 0xbf800000;
        initial.nCOP2VI[15] = 0xffff;
        const auto result = session.run(code, data, initial, 1048576);
        const auto &s = result.state;
        const uint32_t atReset = immediatePayload ? 0xc2 : (reset | 1);
        const uint32_t after = immediatePayload ? 0xc2 : (laterArithmetic ? (reset | 0x82) : (reset | 1));
        const bool passed = result.executed && s.nCOP2[4].nV0 == 0xbf800000 &&
            s.nCOP2VI[1] == 0x41 && s.nCOP2VI[2] == atReset && s.nCOP2VI[3] == 0x80 && s.nCOP2VI[4] == after &&
            (!immediatePayload || s.nCOP2I == (0x2a000000 | reset));
        std::printf("[play-vu:paired-status] reset=%02x later=%u immediate=%u passed=%u before=%02x at=%02x mac=%02x after=%02x\n",
            reset, unsigned(laterArithmetic), unsigned(immediatePayload), unsigned(passed), s.nCOP2VI[1], s.nCOP2VI[2], s.nCOP2VI[3], s.nCOP2VI[4]);
        if (!passed) return false;
    }
    return true;
}

bool scalarFlagTests()
{
    struct Case { uint32_t instruction, numerator, denominator, flags; };
    constexpr Case cases[] = {
        {0x800003bc, 0, 0, 0x10}, {0x800003bc, 0x3f800000, 0, 0x20},
        {0x800003bc, 0x80000000, 0x80000000, 0x10},
        {0x800003bc, 0x3f800000, 1, 0x20}, {0x800003bc, 1, 0, 0x10},
        {0x800003bd, 0, 0xc0800000, 0x10}, {0x800003bd, 0, 0x80000000, 0},
        {0x800003bd, 0, 0x80000001, 0}, {0x800003bd, 0, 0x40800000, 0},
        {0x800003be, 0x3f800000, 0xc0800000, 0x10},
        {0x800003be, 0x3f800000, 0, 0x20}, {0x800003be, 0, 0, 0x30},
        {0x800003be, 0x3f800000, 0x40800000, 0}
    };
    CompiledVuSession session;
    if (!rsqrtQuotientTests(session)) return false;
    if (!stickyResetTests(session)) return false;
    if (!pairedStatusTests(session)) return false;
    unsigned index = 0;
    for (const auto &test : cases)
    {
        const unsigned latency = test.instruction == 0x800003be ? 13 : 7;
        alignas(16) std::array<uint8_t, 16384> code{}, data{};
        {
            CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
            for (unsigned cycle = 0; cycle < latency + 8; ++cycle)
            {
                uint32_t lower = CVuAssembler::Lower::NOP();
                if (cycle == 0) lower = test.instruction | (1u << 11) | (2u << 16);
                if (cycle == 1) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI1, 0xc30);
                if (cycle == latency - 1) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI2, 0xc30);
                if (cycle == latency) lower = 0x2e030000; // FSOR VI3, 0.
                if (cycle == latency + 1) lower = 0x2a000000; // FSSET 0.
                if (cycle == latency + 2) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI4, 0xc30);
                if (cycle == latency + 5) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI5, 0xc30);
                a.Write(CVuAssembler::Upper::NOP() | (cycle == latency + 6 ? CVuAssembler::Upper::E_BIT : 0), lower);
            }
        }
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = 0x3f800000;
        initial.nCOP2[1].nV0 = test.numerator;
        initial.nCOP2[2].nV0 = test.denominator;
        const auto result = session.run(code, data, initial, 1048576);
        const uint32_t sticky = test.flags | (test.flags << 6);
        const bool passed = result.executed && result.scalarFlagsValid &&
            !result.state.nCOP2VI[1] && !result.state.nCOP2VI[2] &&
            (result.state.nCOP2VI[3] & 0xc30) == sticky && result.state.nCOP2VI[4] == sticky &&
            result.state.nCOP2VI[5] == test.flags && result.scalarStatus == test.flags;
        std::printf("[play-vu:scalar-flags] case=%u passed=%u before=%03x at=%03x reset=%03x expected=%03x reason=%s\n",
            index++, unsigned(passed), result.state.nCOP2VI[2], result.state.nCOP2VI[3],
            result.state.nCOP2VI[5], test.flags, result.reason.c_str());
        if (!passed) return false;
        if (index == 1)
        {
            CTestVm old;
            old.Reset();
            std::memcpy(old.m_microMem, code.data(), code.size());
            old.m_cpu.m_State = initial;
            old.ExecuteTest(0);
            if (old.m_cpu.m_State.nCOP2VI[1] == 0 && old.m_cpu.m_State.nCOP2VI[3] == sticky) return false;
            std::printf("[play-vu:scalar-flags-baseline] rejected=1 early=%03x complete=%03x expected=%03x\n",
                old.m_cpu.m_State.nCOP2VI[1], old.m_cpu.m_State.nCOP2VI[3], sticky);
        }
    }
    ScalarFlags flags;
    ScalarFlags::State initial{};
    initial.status = 0xc30;
    initial.events[0] = {7, 0x10, false, true};
    initial.events[1] = {7, 0, true, true};
    flags.reset(initial);
    if (flags.finish(7) != 0x410) return false;
    initial = {};
    initial.events[0] = {3, 0x800, true, true};
    alignas(16) std::array<uint8_t, 16384> code{}, data{};
    {
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        a.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
        a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    }
    MIPSSTATE s{};
    s.nCOP2[0].nV3 = 0x3f800000;
    auto tail = session.run(code, data, s, 1048576, 0, 0, &initial);
    if (!tail.executed || tail.drainedCycle != 3 || tail.scalarEnd != 3 || tail.scalarStatus != 0x800) return false;
    initial.events[0].ready = 66;
    const auto rejected = session.run(code, data, s, 65, 0, 0, &initial);
    if (rejected.executed || !rejected.packets.empty() || rejected.data != std::array<uint8_t, 16384>{}) return false;
    std::printf("[play-vu:scalar-flag-contracts] passed=1 same-cycle-order=1 pending-tail=1 late-budget-rejection=1\n");
    return true;
}
