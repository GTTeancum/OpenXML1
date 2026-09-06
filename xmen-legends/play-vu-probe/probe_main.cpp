#define NOMINMAX
#include <windows.h>
#include "VuAssembler.h"
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
    std::fesetround(FE_TOWARDZERO);
    FpUtils::SetDenormalHandlingMode();
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
