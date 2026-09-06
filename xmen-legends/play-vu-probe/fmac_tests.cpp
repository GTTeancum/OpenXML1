#include "compiled_session.h"
#include "fmac.h"
#include "VuAssembler.h"
#include <cstdio>
#include <cstring>
#include <xmmintrin.h>

static bool fmacVectorParity()
{
    struct Scope {
        unsigned saved = _mm_getcsr();
        Scope() { _mm_setcsr((saved & ~0x603fu) | 0x6000u | 0x8040u | 0x1f80u); }
        ~Scope() { _mm_setcsr(saved); }
    } scope;
    constexpr uint32 edges[] = {0,0x80000000,1,0x80000001,0x007fffff,0x807fffff,0x00800000,0x80800000,
        0x00800001,0x80800001,0x3f800000,0xbf800000,0x3f000000,0x40000000,0x7f7fffff,0xff7fffff,
        0x7f800000,0xff800000,0x7fc00001,0xffc00001};
    uint32 seed = 0x527632;
    const auto next = [&] { seed = seed * 1664525u + 1013904223u; return seed; };
    CMIPS scalar{MEMORYMAP_ENDIAN_LSBF}, vector{MEMORYMAP_ENDIAN_LSBF};
    unsigned cases = 0;
    for (unsigned accumulator = 0; accumulator < 2; ++accumulator)
    for (unsigned function = 0; function < 0x30; ++function)
    for (unsigned mask = 0; mask < 16; ++mask)
    {
        const uint32 base = accumulator ? (0x3c | (function & 3) | ((function & 0x7c) << 4)) : function;
        const uint32 opcode = base | (mask << 21) | (1u << 11) | (2u << 16) | (accumulator ? 0 : ((mask & 3) << 6));
        const auto a = selectFmacScalar(opcode), b = selectFmac(opcode);
        if (bool(a) != bool(b)) return false;
        if (!a) continue;
        MIPSSTATE initial{};
        for (auto &reg : initial.nCOP2) for (auto &word : reg.nV) word = edges[next() % std::size(edges)];
        for (auto &word : initial.nCOP2A.nV) word = edges[next() % std::size(edges)];
        initial.nCOP2[0] = {};
        initial.nCOP2[0].nV3 = 0x3f800000;
        initial.nCOP2Q = edges[next() % std::size(edges)];
        initial.nCOP2I = edges[next() % std::size(edges)];
        scalar.m_State = vector.m_State = initial;
        const auto left = a(&scalar,opcode), right = b(&vector,opcode);
        if (left != right || std::memcmp(&scalar.m_State,&vector.m_State,sizeof(initial)))
        {
            std::printf("[play-vu:fmac-parity-error] opcode=%08x scalar=%08x vector=%08x\n",opcode,left,right);
            return false;
        }
        ++cases;
    }
    std::printf("[play-vu:fmac-parity] passed=1 cases=%u avx2=%u masks=1 aliases=1 vf0=1\n",cases,unsigned(fmacAvx2Available()));
    return true;
}

bool fmacTests()
{
    if (!fmacVectorParity()) return false;
    struct Case { uint32 opcode, left[4], right[4], acc[4], result[4], mac, status; bool accumulator; };
    constexpr uint32 one = 0x3f800000, max = 0x7f7fffff;
    const Case cases[] = {
        {0x28, {0x00800001,0x80800001,max,one}, {0x80800000,0x00800000,max,0xbf800000}, {},
            {0,0x80000000,max,0}, 0x2c4d, 0x3cf, false},
        {0x2c, {0x00800001,0x80800001,max,one}, {0x00800000,0x80800000,0xff7fffff,one}, {},
            {0,0x80000000,max,0}, 0x2c4d, 0x3cf, false},
        {0x2a, {0x00800000,0x80800000,max,0}, {0x3f000000,0x3e800000,0x40000000,one}, {},
            {0,0x80000000,max,0}, 0x2c4d, 0x3cf, false},
        {0x29, {0x00800000,0x80800000,max,0}, {0x3f000000,0x3e800000,0x40000000,one}, {one,one,0,one},
            {one,one,max,one}, 0x2000, 0x3c8, false},
        {0x2be, {0x00800000,0x80800000,max,0}, {0x3f000000,0x3e800000,0x40000000,one}, {},
            {0,0x80000000,max,0}, 0x2c4d, 0x3cf, true},
        {0x2bc, {one,one,one,one}, {one,one,one,one}, {},
            {0x40000000,0x40000000,0x40000000,0x40000000}, 0, 0, true}
    };
    CompiledVuSession session;
    unsigned index = 0;
    for (const auto &test : cases)
    {
        alignas(16) std::array<uint8_t,16384> code{}, data{};
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        for (unsigned cycle = 0; cycle < 13; ++cycle)
        {
            uint32 upper = CVuAssembler::Upper::NOP(), lower = CVuAssembler::Lower::NOP();
            if (cycle == 0) upper = test.opcode | (15u << 21) | (2u << 16) | (1u << 11) | (test.accumulator ? 0 : (3u << 6));
            if (cycle == 3) lower = CVuAssembler::Lower::FMAND(CVuAssembler::VI1, CVuAssembler::VI15);
            if (cycle == 4) lower = CVuAssembler::Lower::FMAND(CVuAssembler::VI2, CVuAssembler::VI15);
            if (cycle == 5) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI3, 0xfff);
            if (cycle == 6) lower = 0x2a000000;
            if (cycle == 7) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI4, 0xfff);
            if (cycle == 10) lower = CVuAssembler::Lower::FSAND(CVuAssembler::VI5, 0xfff);
            if (cycle == 11) upper |= CVuAssembler::Upper::E_BIT;
            a.Write(upper, lower);
        }
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = one;
        initial.nCOP2VI[15] = 0xffff;
        std::memcpy(initial.nCOP2[1].nV, test.left, 16);
        std::memcpy(initial.nCOP2[2].nV, test.right, 16);
        std::memcpy(initial.nCOP2A.nV, test.acc, 16);
        const auto result = session.run(code, data, initial, 1048576);
        const auto &s = result.state;
        const auto &value = test.accumulator ? s.nCOP2A : s.nCOP2[3];
        const bool passed = result.executed && !std::memcmp(value.nV, test.result, 16) &&
            !s.nCOP2VI[1] && s.nCOP2VI[2] == test.mac && s.nCOP2VI[3] == test.status &&
            s.nCOP2VI[4] == test.status && s.nCOP2VI[5] == (test.status & 0x3f);
        std::printf("[play-vu:fmac-range] case=%u passed=%u mac=%04x/%04x status=%03x/%03x reset=%03x values=%08x,%08x,%08x,%08x reason=%s\n",
            index++, unsigned(passed), s.nCOP2VI[2], test.mac, s.nCOP2VI[3], test.status, s.nCOP2VI[5],
            value.nV0,value.nV1,value.nV2,value.nV3,result.reason.c_str());
        if (!passed) return false;
    }
    return true;
}
