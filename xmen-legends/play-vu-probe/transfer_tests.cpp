#define NOMINMAX
#include "transfer_timeline.h"
#include "TestVm.h"
#include "VuAssembler.h"
#include <cstdio>
#include <cstring>
#include <string>

bool runTransferTests()
{
    for (unsigned mode = 0; mode < 8; ++mode)
    {
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        TransferTimeline timeline(vm->m_vuMem);
        std::string error;
        std::vector<uint32_t> eventPcs;
        vm->m_cpu.m_vuMemoryObserver = [&](CMIPS *cpu, uint32 pc, uint32 cycle, uint32 phase) {
            if (!error.empty()) return;
            try {
                ++timeline.events;
                eventPcs.push_back(pc);
                if (phase == 2) timeline.kick(cpu->m_State.xgkickAddress, cycle);
                else timeline.advance(cycle);
            } catch (const std::exception &e) { error = e.what(); }
        };
        vm->m_cpu.m_pMemoryMap->InsertWriteMap(0x8410u, 0x8413u,
            [](uint32, uint32) -> uint32 { return 0; }, 1u);
        const uint64_t tag = mode == 3 ? 0x1000000000008008ull : 0x1000000000008001ull;
        const uint32_t oldWord = 0x12345678, newWord = 0x55667788;
        const unsigned source = mode == 4 ? 1023 : 4;
        const unsigned payload = (source + 1) & 1023;
        std::memcpy(vm->m_vuMem + source * 16, &tag, 8);
        std::memcpy(vm->m_vuMem + payload * 16, &oldWord, 4);
        vm->m_cpu.m_State.nCOP2VI[1] = source;
        vm->m_cpu.m_State.nCOP2[1].nV0 = newWord;
        const unsigned prefix = mode == 1 ? 7 : 0;
        // Label references are resolved by the assembler's destructor.
        {
            CVuAssembler assembler(reinterpret_cast<uint32 *>(vm->m_microMem));
            for (unsigned i = 0; i < prefix; ++i)
                assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
            if (mode == 5)
            {
                const auto target = assembler.CreateLabel();
                assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::B(target));
                assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
                assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
                assembler.MarkLabel(target);
            }
            assembler.Write(CVuAssembler::Upper::NOP(), 0x800006fcu | (1u << 11));
            if (mode == 2)
                for (unsigned i = 0; i < 3; ++i)
                    assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
            assembler.Write(CVuAssembler::Upper::NOP() | (mode == 6 ? CVuAssembler::Upper::I_BIT : 0),
                CVuAssembler::Lower::SQ(CVuAssembler::DEST_XYZW, CVuAssembler::VF1,
                    mode == 0 ? source : payload, CVuAssembler::VI0));
            assembler.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
            assembler.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
        }
        const auto initialState = vm->m_cpu.m_State;
        vm->ExecuteTest(0);
        if (mode == 7 && error.empty())
        {
            std::memcpy(vm->m_microMem + 128, vm->m_microMem, 32);
            vm->m_cpu.m_State = initialState;
            std::memcpy(vm->m_vuMem + source * 16, &tag, 8);
            std::memcpy(vm->m_vuMem + payload * 16, &oldWord, 4);
            timeline.reset();
            eventPcs.clear();
            vm->ExecuteTest(128); // Keep the first block in the compiled-code cache.
        }
        try { if (error.empty()) timeline.finish(vm->m_cpu.m_State.pipeTime); }
        catch (const std::exception &e) { error = e.what(); }
        uint64_t observedTag = 0;
        uint32_t observedWord = 0;
        const unsigned expectedSize = mode == 3 ? 144 : 32;
        if (timeline.packets.size() == 1 && timeline.packets[0].size() == expectedSize)
        {
            std::memcpy(&observedTag, timeline.packets[0].data(), 8);
            std::memcpy(&observedWord, timeline.packets[0].data() + 16, 4);
        }
        const uint32_t expectedWord = mode == 0 || mode == 2 || mode == 6 ? oldWord : newWord;
        const unsigned expectedEvents = mode == 5 ? 5 : mode == 6 ? 2 : 4;
        const unsigned expectedCompletion = prefix + (mode == 5 ? 2 : 0) + expectedSize / 8 - 1;
        const bool pcsCorrect = mode != 7 || eventPcs == std::vector<uint32_t>{128, 136, 136, 152};
        const bool passed = error.empty() && timeline.events == expectedEvents && observedTag == tag &&
            observedWord == expectedWord && timeline.completionCycles.size() == 1 &&
            timeline.completionCycles[0] == expectedCompletion && timeline.time >= expectedCompletion && pcsCorrect;
        std::printf("[play-vu:transfer-test] mode=%u passed=%u events=%u packet-word=%08x error=%s\n",
            mode, unsigned(passed), timeline.events, observedWord, error.c_str());
        if (!passed) return false;
    }
    return true;
}
