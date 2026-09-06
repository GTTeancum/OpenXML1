#define NOMINMAX
#include <windows.h>
#include "VuAssembler.h"
#include "replay_diagnostic.h"
#include "compiled_session.h"
#include "fmac.h"
#include "runtime_bridge.h"
#include "FpUtils.h"
#include "AddTest.h"
#include "BranchTest.h"
#include "DynamicStallTest.h"
#include "DynamicStallTest2.h"
#include "FdivEfuMixTest.h"
#include "FlagsTest.h"
#include "FlagsTest2.h"
#include "FlagsTest3.h"
#include "FlagsTest4.h"
#include "IntBranchDelayTest.h"
#include "IntBranchDelayTest2.h"
#include "IntBranchDelayTest3.h"
#include "MinMaxTest.h"
#include "MinMaxFlagsTest.h"
#include "StallTest.h"
#include "StallTest2.h"
#include "StallTest3.h"
#include "StallTest4.h"
#include "StallTest5.h"
#include "StallTest6.h"
#include "TriAceTest.h"
#include <cstdio>
#include <cfenv>
#include <cstring>
#include "Jitter.h"
#include "Jitter_CodeGenFactory.h"
#include "MemStream.h"
#include "MemoryFunction.h"

extern "C" void playVuCheckRegisters(void (*function)(void *), void *context,
    const uint32_t *sentinel, uint32_t *actual);
bool runTransferTests();

static void mutateContext(uint32_t *context)
{
    context[1] = context[0];
    context[0] = 0x40900000;
}

static bool checkContextCalls()
{
    bool passed = true;
    for (unsigned variant = 0; variant < 2; ++variant)
    {
        alignas(16) uint32_t context[4]{};
        Framework::CMemStream stream;
        Jitter::CJitter jitter(Jitter::CreateCodeGen());
        jitter.SetStream(&stream);
        jitter.Begin();
        jitter.PushCst(0x3f800001);
        jitter.PullRel(0);
        jitter.PushCtx();
        jitter.Call(reinterpret_cast<void*>(&mutateContext), 1, Jitter::CJitter::RETURN_VALUE_NONE);
        if (variant == 0) jitter.PushCst(0x3f800000);
        else jitter.PushRel(0);
        jitter.PullRel(variant == 0 ? 0 : 8);
        jitter.End();
        CMemoryFunction function(stream.GetBuffer(), stream.GetSize());
        reinterpret_cast<void (*)(void *)>(function.GetCode())(context);
        const bool match = context[1] == 0x3f800001 &&
            (variant == 0 ? context[0] == 0x3f800000 : context[2] == 0x40900000);
        passed &= match;
        std::printf("[play-vu:context-call] variant=%u passed=%u observed=%08x after=%08x\n",
            variant, unsigned(match), context[1], context[variant == 0 ? 0 : 2]);
    }
    return passed;
}

static void mutateWideContext(uint32_t *context)
{
    for (unsigned i = 0; i < 4; ++i) context[i] ^= 0xffffffffu;
}

static bool checkWideContextCalls()
{
    bool passed = true;
    for (unsigned words : {1u, 2u, 4u})
    {
        alignas(16) uint32_t context[16]{};
        for (unsigned i = 0; i < 4; ++i) context[i] = 0x12340000 + i;
        Framework::CMemStream stream;
        Jitter::CJitter jitter(Jitter::CreateCodeGen());
        jitter.SetStream(&stream);
        jitter.Begin();
        for (unsigned stage = 0; stage < 2; ++stage)
        {
            const unsigned offset = 32 + stage * 16;
            if (words == 1) { jitter.PushRel(0); jitter.PullRel(offset); }
            if (words == 2) { jitter.PushRel64(0); jitter.PullRel64(offset); }
            if (words == 4) { jitter.MD_PushRel(0); jitter.MD_PullRel(offset); }
            if (stage == 0)
            {
                jitter.PushCtx();
                jitter.Call(reinterpret_cast<void*>(&mutateWideContext), 1, Jitter::CJitter::RETURN_VALUE_NONE);
            }
        }
        jitter.End();
        CMemoryFunction function(stream.GetBuffer(), stream.GetSize());
        reinterpret_cast<void (*)(void *)>(function.GetCode())(context);
        bool match = true;
        for (unsigned i = 0; i < words; ++i)
            match &= context[8 + i] == (0x12340000u + i) && context[12 + i] == ~(0x12340000u + i);
        passed &= match;
        std::printf("[play-vu:context-wide] words=%u passed=%u\n", words, unsigned(match));
    }
    return passed;
}

static bool checkWindowsAbi()
{
    alignas(16) uint32_t context[25][4]{};
    Framework::CMemStream stream;
    Jitter::CJitter jitter(Jitter::CreateCodeGen());
    jitter.SetStream(&stream);
    jitter.Begin();
    for (unsigned vector = 0; vector < 12; ++vector)
    {
        jitter.MD_PushRel(vector * 16);
        jitter.MD_PushRel(12 * 16);
        jitter.MD_AddW();
    }
    for (int vector = 11; vector >= 0; --vector)
        jitter.MD_PullRel((13 + vector) * 16);
    jitter.End();
    for (unsigned vector = 0; vector < 13; ++vector)
        for (unsigned lane = 0; lane < 4; ++lane)
            context[vector][lane] = 0x12340000u + vector * 4 + lane;
    CMemoryFunction function(stream.GetBuffer(), stream.GetSize());
    alignas(16) const uint32_t sentinel[] = {0x3f123456, 0x40123456, 0x41123456, 0x42123456};
    uint32_t actual[40]{};
    playVuCheckRegisters(reinterpret_cast<void (*)(void *)>(function.GetCode()), context, sentinel, actual);
    unsigned corruptMask = 0, outputErrors = 0;
    for (unsigned reg = 0; reg < 10; ++reg)
        if (std::memcmp(actual + reg * 4, sentinel, sizeof(sentinel))) corruptMask |= 1u << reg;
    for (unsigned vector = 0; vector < 12; ++vector)
        for (unsigned lane = 0; lane < 4; ++lane)
            outputErrors += context[13 + vector][lane] != context[vector][lane] + context[12][lane];
    std::printf("[play-vu:synthetic-abi] xmm-corrupt-mask=0x%x output-errors=%u\n", corruptMask, outputErrors);
    return corruptMask == 0 && outputErrors == 0;
}

#define VU_TEST(Name) {#Name, []() -> CTest* { return new C##Name(); }}
static const struct { const char *name; CTest *(*create)(); } tests[] = {
    VU_TEST(AddTest), VU_TEST(BranchTest), VU_TEST(DynamicStallTest), VU_TEST(DynamicStallTest2),
    VU_TEST(FdivEfuMixTest), VU_TEST(FlagsTest), VU_TEST(FlagsTest2), VU_TEST(FlagsTest3),
    VU_TEST(FlagsTest4), VU_TEST(IntBranchDelayTest), VU_TEST(IntBranchDelayTest2),
    VU_TEST(IntBranchDelayTest3), VU_TEST(MinMaxTest), VU_TEST(MinMaxFlagsTest),
    VU_TEST(StallTest), VU_TEST(StallTest2), VU_TEST(StallTest3), VU_TEST(StallTest4),
    VU_TEST(StallTest5), VU_TEST(StallTest6), VU_TEST(TriAceTest)
};
#undef VU_TEST

int main(int argc, const char **argv)
{
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc > 2)
    {
        std::fprintf(stderr, "Usage: play_vu_probe [private-replay.bin]\n");
        return 2;
    }
    std::fesetround(FE_TOWARDZERO);
    FpUtils::SetDenormalHandlingMode();
    if (!checkWindowsAbi()) return 6;
    if (!checkContextCalls() || !checkWideContextCalls()) return 13;
    if (!runTransferTests()) return 7;
    if (!pendingImportTests()) return 8;
    if (!compiledSessionTests()) return 9;
    if (!runtimeBridgeTests()) return 10;
    if (!scalarFlagTests()) return 11;
    if (!fmacTests()) return 12;
    if (argc == 2)
    {
        try { return replayDiagnostic(argv[1]); }
        catch (const std::exception &e) { std::fprintf(stderr, "%s\n", e.what()); return 5; }
    }
    auto testVm = std::make_unique<CTestVm>();
    for (const auto &entry : tests)
    {
        std::printf("[play-vu:test] %s\n", entry.name);
        std::fflush(stdout);
        testVm->Reset();
        std::unique_ptr<CTest> test(entry.create());
        test->Execute(*testVm);
    }
    std::printf("[play-vu] %zu unmodified upstream tests passed\n", std::size(tests));

    for (int quota : {1, 2, 8, 64})
    {
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        CVuAssembler assembler(reinterpret_cast<uint32*>(vm->m_microMem));
        for (int pair = 0; pair < 64; ++pair)
            assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
        assembler.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT,
            CVuAssembler::Lower::NOP());
        assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
        const auto before = vm->m_cpu.m_State.pipeTime;
        const int remaining = vm->m_executor.Execute(quota);
        const auto elapsed = vm->m_cpu.m_State.pipeTime - before;
        std::printf("[play-vu:budget] requested=%d remaining=%d pipe-cycles=%u pc=0x%x exception=0x%x\n",
            quota, remaining, elapsed, vm->m_cpu.m_State.nPC, vm->m_cpu.m_State.nHasException);
        if (elapsed != 66u || remaining != quota - 132)
        {
            std::fprintf(stderr, "Unexpected pinned-engine budget contract; inspect before bridging.\n");
            return 2;
        }
    }
    auto vm = std::make_unique<CTestVm>();
    vm->Reset();
    uint32 callbackCount = 0u, callbackCycle = ~0u, callbackAddress = ~0u, observedWord = 0u;
    vm->m_cpu.m_pMemoryMap->InsertWriteMap(0x8410u, 0x8413u,
        [&](uint32, uint32 value) -> uint32 {
            ++callbackCount;
            callbackCycle = vm->m_cpu.m_State.pipeTime;
            callbackAddress = value;
            std::memcpy(&observedWord, vm->m_vuMem + 32u, sizeof(observedWord));
            return 0u;
        }, 1u);
    const uint32 oldWord = 0x11223344u, newWord = 0x55667788u;
    std::memcpy(vm->m_vuMem + 32u, &oldWord, sizeof(oldWord));
    vm->m_cpu.m_State.nCOP2VI[1] = 2u;
    vm->m_cpu.m_State.nCOP2[1].nV0 = newWord;
    CVuAssembler assembler(reinterpret_cast<uint32*>(vm->m_microMem));
    assembler.Write(CVuAssembler::Upper::NOP(), 0x800006fcu | (1u << 11u)); // XGKICK VI1
    assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::SQ(
        CVuAssembler::DEST_XYZW, CVuAssembler::VF1, 2u, CVuAssembler::VI0));
    assembler.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
    assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    vm->ExecuteTest(0u);
    std::printf("[play-vu:xgkick] callbacks=%u address=%u callback-pipe=%u final-pipe=%u word=%08x\n",
        callbackCount, callbackAddress, callbackCycle, vm->m_cpu.m_State.pipeTime, observedWord);
    if (callbackCount != 1u || callbackAddress != 2u || callbackCycle != 0u ||
        vm->m_cpu.m_State.pipeTime != 4u || observedWord != newWord)
    {
        std::fprintf(stderr, "Unexpected pinned-engine XGKICK callback contract.\n");
        return 3;
    }
    return 0;
}
