#include "fmac_emitter.h"
#include "fmac.h"
#include "compiled_session.h"
#include "MipsJitter.h"
#include "Jitter_CodeGenFactory.h"
#include "MemoryFunction.h"
#include "MemStream.h"
#include "ee/VUShared.h"
#include "VuAssembler.h"
#include <cstdio>
#include <cstring>
#include <xmmintrin.h>

namespace
{
uint32 fallbackCalls = 0;
uint32 countedFallback(CMIPS *cpu, uint32 opcode)
{
    ++fallbackCalls;
    return selectFmacRuntimeFused(opcode)(cpu, opcode);
}
}

bool directFmacTests()
{
    struct Scope {
        uint32 saved = _mm_getcsr();
        Scope() { _mm_setcsr((saved & ~0x603fu) | 0x6000u | 0x8040u | 0x1f80u); }
        ~Scope() { _mm_setcsr(saved); }
    } scope;
    CMIPS reference{MEMORYMAP_ENDIAN_LSBF}, direct{MEMORYMAP_ENDIAN_LSBF};
    direct.m_vuFmacCompiler = [](uint32) { return countedFallback; };
    for (uint32 opcode : {0x28u, 0x29u | (15u << 21), 0x2du | (15u << 21), 0x2eu | (15u << 21)})
        if (emitDirectFmac(&direct, nullptr, opcode, 0, 0)) return false;
    uint32 seed = 0x2756315;
    const auto next = [&] { seed = seed * 1664525u + 1013904223u; return seed; };
    uint32 cases = 0, fastCases = 0, slowCases = 0;
    for (uint32 fn : {0u,1u,2u,3u,4u,5u,6u,7u,0x18u,0x19u,0x1au,0x1bu,
        0x1cu,0x1eu,0x20u,0x22u,0x24u,0x26u,0x28u,0x2au,0x2cu})
    for (bool accumulator : {false,true})
    for (uint32 mask = 1; mask < 16; ++mask)
    for (uint32 fd : {0u,1u,2u,3u})
    {
        const uint32 opcode = (accumulator ? 0x3cu | (fn & 3) | ((fn & 0x7c) << 4) : fn | (fd << 6)) |
            (mask << 21) | (1u << 11) | (2u << 16);
        const uint32 hints = VUShared::COMPILEHINT_PACKED_STATUS;
        Framework::CMemStream baselineCode, directCode;
        CMipsJitter baselineJit(Jitter::CreateCodeGen()), directJit(Jitter::CreateCodeGen());
        baselineJit.SetStream(&baselineCode);
        baselineJit.Begin();
        baselineJit.PushCtx();
        baselineJit.PushCst(opcode);
        baselineJit.Call(reinterpret_cast<void *>(countedFallback), 2, Jitter::CJitter::RETURN_VALUE_32);
        VUShared::QueueFmacFlags(&baselineJit, 5, hints);
        baselineJit.End();
        directJit.SetStream(&directCode);
        directJit.Begin();
        if (!emitDirectFmac(&direct, &directJit, opcode, 5, hints)) return false;
        directJit.End();
        CMemoryFunction baselineFunction(baselineCode.GetBuffer(), baselineCode.GetSize());
        CMemoryFunction directFunction(directCode.GetBuffer(), directCode.GetSize());
        for (uint32 sample = 0; sample < 24; ++sample)
        {
            const auto word = [&] {
                if (sample == 0) return 0x3f800000u + (next() & 0xffff);
                if (sample == 1) return 0x7f7fffffu;
                if (sample == 2) return next() & 0x80000000u;
                if (sample < 8)
                {
                    constexpr uint32 edges[] = {0,1,0x80000001,0x007fffff,0x00800000,0x2f7fffff,
                        0x2f800000,0x2f800001,0x4f7fffff,0x4f800000,0x4f800001,0x7f800000,0x7fc12345};
                    return edges[next() % std::size(edges)] ^ (next() & 0x80000000u);
                }
                if (sample < 16) return next();
                return (next() & 0x807fffffu) | ((95u + next() % 65u) << 23);
            };
            MIPSSTATE initial{};
            for (auto &v : initial.nCOP2) for (auto &lane : v.nV) lane = word();
            for (auto &lane : initial.nCOP2A.nV) lane = word();
            initial.nCOP2[0] = {}; initial.nCOP2[0].nV3 = 0x3f800000;
            initial.nCOP2Q = word(); initial.nCOP2I = word();
            initial.pipeTime = 31;
            initial.pipeMac.index = next() & 7;
            initial.pipeSticky.index = next() & 7;
            for (auto &v : initial.pipeSticky.values) v = next();
            reference.m_State = direct.m_State = initial;
            reinterpret_cast<void (*)(CMIPS *)>(baselineFunction.GetCode())(&reference);
            fallbackCalls = 0;
            reinterpret_cast<void (*)(CMIPS *)>(directFunction.GetCode())(&direct);
            if (std::memcmp(&reference.m_State, &direct.m_State, sizeof(initial)) ||
                (sample == 0 && fallbackCalls != 0) || (sample == 1 && fallbackCalls != 1))
            {
                std::printf("[play-vu:direct-fmac-error] opcode=%08x sample=%u fallback=%u\n", opcode, sample, fallbackCalls);
                return false;
            }
            ++cases;
            if (fallbackCalls) ++slowCases; else ++fastCases;
        }
    }
    CompiledVuSession compiled{CompiledVuSession::Arithmetic::RuntimeFused, CompiledVuSession::Emission::Direct};
    CompiledVuSession helpers{CompiledVuSession::Arithmetic::RuntimeFused, CompiledVuSession::Emission::Helpers};
    std::array<uint8_t,16384> code{}, data{};
    CVuAssembler assembler(reinterpret_cast<uint32 *>(code.data()));
    assembler.Write(0x28u | (15u << 21) | (1u << 11) | (2u << 16) | (3u << 6), CVuAssembler::Lower::NOP());
    assembler.Write(0x29u | (15u << 21) | (3u << 11) | (2u << 16) | (1u << 6), CVuAssembler::Lower::NOP());
    assembler.Write(0x2au | (15u << 21) | (1u << 11) | (2u << 16) | (1u << 6), CVuAssembler::Lower::NOP());
    assembler.Write(CVuAssembler::Upper::NOP(), (1u << 25) | (15u << 21) | (1u << 11) | 8u);
    assembler.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
    assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    for (uint32 input : {0u,0x80000000u,1u,0x3f800000u,0x7f800000u,0x4f800001u})
    {
        MIPSSTATE initial{};
        initial.nDelayedJumpAddr = MIPS_INVALID_PC;
        initial.nCOP2[0].nV3 = 0x3f800000;
        initial.nCOP2[1].nV0 = input;
        initial.nCOP2[2].nV0 = 0x40000000;
        const auto a = helpers.run(code, data, initial, 1048576);
        const auto b = compiled.run(code, data, initial, 1048576);
        if (!a.executed || !b.executed || compiled.directInstructionsCompiled() != 2 || helpers.directInstructionsCompiled() ||
            a.drainedCycle != b.drainedCycle || a.scalarStatus != b.scalarStatus ||
            std::memcmp(&a.state, &b.state, sizeof(a.state)) || a.data != b.data || a.packets != b.packets) return false;
    }
    std::printf("[play-vu:direct-fmac] cases=%u fast=%u fallback=%u full-state=1 session-hook=1\n", cases, fastCases, slowCases);
    return true;
}
