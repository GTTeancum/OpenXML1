#include "compiled_session.h"
#include "VuAssembler.h"
#include "TestVm.h"
#include <cstdio>
#include <cstring>

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
