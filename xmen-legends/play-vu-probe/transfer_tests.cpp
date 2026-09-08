#define NOMINMAX
#include "transfer_timeline.h"
#include "TestVm.h"
#include "VuAssembler.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <string>

static bool runBulkTransferTests()
{
    unsigned cases = 0;
    for (unsigned format : {0u, 1u, 2u, 3u})
    for (unsigned registers : {1u, 3u, 16u})
    for (unsigned loops : {0u, 1u, 127u, 513u})
    for (unsigned source : {0u, 1023u})
    for (unsigned step : {1u, 7u, 97u, 65536u})
    {
        const unsigned payload = format == 0 ? loops * registers * 16 :
            format == 1 ? ((loops * registers + 1) / 2) * 16 : loops * 16;
        if (payload + 16 > 65536) continue;
        std::array<uint8_t, 16384> memory;
        for (size_t i = 0; i < memory.size(); ++i) memory[i] = uint8_t(i * 37 + i / 256);
        const uint64_t tag = loops | 0x8000ull | (uint64_t(format) << 58) |
            (uint64_t(registers & 15) << 60);
        std::memcpy(memory.data() + source * 16, &tag, 8);
        TransferTimeline bulk(memory.data()), single(memory.data());
        bulk.kick(source, 0);
        single.kick(source, 0);
        const uint64_t completion = 1 + (payload / 16) * 2;
        uint64_t cycle = 0;
        while (cycle < completion)
        {
            const uint64_t target = std::min<uint64_t>(cycle + step, completion);
            bulk.advance(target);
            while (cycle < target) single.advance(++cycle);
            // A VU store happens after this observation, never before ready reads.
            if (payload && step != 65536)
                memory[(source * 16 + 16 + (cycle * 13) % payload) & 16383] ^= 0x5a;
            if (bulk.packets != single.packets ||
                bulk.completionCycles != single.completionCycles || bulk.time != single.time)
                return false;
        }
        if (bulk.packets.size() != 1 || bulk.packets[0].size() != payload + 16 ||
            bulk.completionCycles != std::vector<uint64_t>{completion}) return false;
        ++cases;
    }
    for (unsigned format : {0u, 1u, 2u, 3u})
    {
        std::array<uint8_t, 16384> memory{};
        const uint64_t emptyTag = 0x1000000000000000ull;
        const uint64_t endTag = 3ull | 0x8000ull | (uint64_t(format) << 58) | (3ull << 60);
        std::memcpy(memory.data() + 16368, &emptyTag, 8);
        std::memcpy(memory.data(), &endTag, 8);
        const unsigned payloadQwords = format == 0 ? 9 : format == 1 ? 5 : 3;
        const uint64_t completion = 3 + payloadQwords * 2;
        TransferTimeline bulk(memory.data()), single(memory.data());
        bulk.kick(1023, 0);
        single.kick(1023, 0);
        bulk.finish(0);
        for (uint64_t cycle = 0; cycle <= completion; ++cycle) single.advance(cycle);
        if (bulk.packets != single.packets || bulk.completionCycles != single.completionCycles ||
            bulk.time != completion || bulk.completionCycles != std::vector<uint64_t>{completion}) return false;
        ++cases;
    }
    {
        constexpr unsigned source = 777;
        constexpr unsigned loops = 5000;
        constexpr size_t packetBytes = (loops + 1u) * 16u;
        std::array<uint8_t, 16384> memory;
        for (size_t i = 0; i < memory.size(); ++i)
            memory[i] = static_cast<uint8_t>(i * 37u + 11u);
        const uint64_t tag = loops | 0x8000ull | (3ull << 58) | (3ull << 60);
        std::memcpy(memory.data() + source * 16u, &tag, sizeof(tag));
        std::memset(memory.data() + source * 16u + sizeof(tag), 0, sizeof(tag));

        TransferTimeline timeline(memory.data());
        timeline.kick(source, 0);
        timeline.finish(0);
        const uint64_t completion = 1u + loops * 2u;
        if (timeline.packets.size() != 1 ||
            timeline.packets[0].size() != packetBytes ||
            timeline.completionCycles != std::vector<uint64_t>{completion})
            return false;
        for (size_t i = 0; i < packetBytes; ++i)
            if (timeline.packets[0][i] != memory[(source * 16u + i) & 16383u])
                return false;
        ++cases;
    }
    std::printf("[play-vu:bulk-transfer] cases=%u passed=1\n", cases);
    return true;
}

static bool runXgkickWaitTests()
{
    for (unsigned mode = 0; mode < 7; ++mode)
    {
        auto vm = std::make_unique<CTestVm>();
        vm->Reset();
        TransferTimeline timeline(vm->m_vuMem);
        std::string error;
        unsigned waits = 0;
        std::vector<uint32> issues;
        vm->m_cpu.m_vuMemoryObserver = [&](CMIPS *cpu, uint32, uint32 cycle, uint32 phase) {
            if (!error.empty()) return;
            try {
                if (phase == 2) {
                    issues.push_back(cycle);
                    timeline.kick(cpu->m_State.xgkickAddress, cycle);
                } else timeline.advance(cycle);
            } catch (const std::exception &e) { error = e.what(); }
        };
        vm->m_cpu.m_vuXgkickWait = [&](CMIPS *, uint32, uint32 cycle) -> uint32 {
            if (!error.empty()) return 0;
            try {
                timeline.finish(cycle);
                const auto elapsed = static_cast<uint32>(timeline.time - cycle);
                waits += elapsed;
                return elapsed;
            } catch (const std::exception &e) { error = e.what(); return 0; }
        };
        vm->m_cpu.m_pMemoryMap->InsertWriteMap(0x8410u, 0x8413u,
            CMemoryMap::MemoryMapHandlerType{[](uint32, uint32) -> uint32 { return 0; }}, 1u);
        const uint64_t firstTag = mode == 3 ? 0x1000000000008008ull : 0x1000000000008001ull;
        const uint64_t secondTag = 0x1000000000008001ull;
        std::memcpy(vm->m_vuMem + 64, &firstTag, 8);
        std::memcpy(vm->m_vuMem + 256, &secondTag, 8);
        auto &s = vm->m_cpu.m_State;
        s.nCOP2VI[1] = 4;
        s.nCOP2VI[2] = 16;
        s.nCOP2[1].nV0 = 0x3f800000;
        if (mode == 4) {
            s.nCOP2[2].nV0 = 0x40000000;
            for (auto &mask : s.pipeFmacWrite) mask.nV0 = 0x800;
        }
        {
            CVuAssembler a(reinterpret_cast<uint32 *>(vm->m_microMem));
            const auto nop = CVuAssembler::Upper::NOP();
            const auto read2 = CVuAssembler::Upper::MULAbc(CVuAssembler::DEST_X,
                CVuAssembler::VF2, CVuAssembler::VF0, CVuAssembler::BC_W);
            const auto write2 = CVuAssembler::Upper::ADDbc(CVuAssembler::DEST_X,
                CVuAssembler::VF2, CVuAssembler::VF1, CVuAssembler::VF0, CVuAssembler::BC_W);
            a.Write(mode == 4 ? nop : write2,
                mode == 4 ? CVuAssembler::Lower::NOP() : 0x800006fcu | (1u << 11));
            const auto target = a.CreateLabel();
            if (mode >= 5) a.Write(nop, CVuAssembler::Lower::B(target));
            a.Write(mode == 1 || mode == 4 || mode == 6 ? read2 : mode == 3 ? write2 : nop,
                0x800006fcu | (2u << 11));
            if (mode >= 5) {
                a.Write(nop, CVuAssembler::Lower::NOP());
                a.MarkLabel(target);
            }
            if (mode == 2 || mode == 3) a.Write(read2, CVuAssembler::Lower::NOP());
            a.Write(nop | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
            a.Write(nop, CVuAssembler::Lower::NOP());
        }
        vm->ExecuteTest(0);
        try { if (error.empty()) timeline.finish(s.pipeTime); }
        catch (const std::exception &e) { error = e.what(); }
        const std::vector<uint32> expectedIssues = mode == 4 ? std::vector<uint32>{3} :
            std::vector<uint32>{0, mode == 1 || mode == 6 ? 4u : mode == 3 ? 17u : 3u};
        const std::vector<uint64_t> expectedCompletions = mode == 4 ? std::vector<uint64_t>{6} :
            std::vector<uint64_t>{mode == 3 ? 17u : 3u, mode == 1 || mode == 6 ? 7u : mode == 3 ? 20u : 6u};
        const uint32 expectedEnd[] = {6, 7, 7, 24, 6, 6, 7};
        const bool passed = error.empty() && issues == expectedIssues &&
            timeline.completionCycles == expectedCompletions && s.pipeTime == expectedEnd[mode] &&
            waits == (mode == 3 ? 16u : mode == 4 ? 0u : mode >= 5 ? 1u : 2u) &&
            (mode == 0 || mode == 5 || s.nCOP2A.nV0 == 0x40000000);
        std::printf("[play-vu:wait-test] mode=%u passed=%u wait=%u end=%u acc=%08x error=%s\n",
            mode, unsigned(passed), waits, s.pipeTime, s.nCOP2A.nV0, error.c_str());
        if (!passed) return false;
    }
    return true;
}

bool runTransferTests()
{
    if (!runBulkTransferTests()) return false;
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
            CMemoryMap::MemoryMapHandlerType{[](uint32, uint32) -> uint32 { return 0; }}, 1u);
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
    return runXgkickWaitTests();
}
