#include "compiled_session.h"
#include "VuAssembler.h"
#include "transfer_timeline.h"
#include <cfenv>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <xmmintrin.h>

static bool cacheRetentionTests()
{
    using Session = CompiledVuSession;
    Session discarded(Session::Arithmetic::RuntimeFused, Session::Emission::Helpers, Session::Cache::Discard);
    Session retained(Session::Arithmetic::RuntimeFused, Session::Emission::Helpers, Session::Cache::Retain);
    std::array<std::array<uint8_t, 16384>, 8> programs{};
    std::array<uint8_t, 16384> data{};
    MIPSSTATE initial{};
    initial.nDelayedJumpAddr = MIPS_INVALID_PC;
    initial.nCOP2[0].nV3 = 0x3f800000;
    initial.nCOP2[1].nV0 = 0x40000000;
    const auto nop = CVuAssembler::Upper::NOP();
    for (unsigned variant = 0; variant < programs.size(); ++variant)
    {
        CVuAssembler a(reinterpret_cast<uint32 *>(programs[variant].data()));
        const auto target = a.CreateLabel();
        a.Write(nop | 0x80000000u, 0x3f800000u + (variant << 15));
        a.Write(CVuAssembler::Upper::MULi(CVuAssembler::DEST_X, CVuAssembler::VF2, CVuAssembler::VF1), CVuAssembler::Lower::NOP());
        a.Write(nop, CVuAssembler::Lower::B(target));
        a.Write(nop, CVuAssembler::Lower::NOP());
        a.Write(nop, CVuAssembler::Lower::IADDIU(CVuAssembler::VI1, CVuAssembler::VI0, variant));
        a.MarkLabel(target);
        a.Write(nop, CVuAssembler::Lower::SQ(CVuAssembler::DEST_XYZW, CVuAssembler::VF2, 4, CVuAssembler::VI0));
        a.Write(nop | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
        a.Write(nop, CVuAssembler::Lower::NOP());
    }
    int64_t discardedNs = 0, retainedNs = 0;
    for (unsigned run = 0; run < 256; ++run)
    {
        const auto &code = programs[run % programs.size()];
        const auto begin = std::chrono::steady_clock::now();
        const auto a = discarded.run(code, data, initial, 1048576);
        const auto middle = std::chrono::steady_clock::now();
        const auto b = retained.run(code, data, initial, 1048576);
        const auto finish = std::chrono::steady_clock::now();
        discardedNs += std::chrono::duration_cast<std::chrono::nanoseconds>(middle - begin).count();
        retainedNs += std::chrono::duration_cast<std::chrono::nanoseconds>(finish - middle).count();
        if (!a.executed || !b.executed || std::memcmp(&a.state, &b.state, sizeof(a.state)) ||
            a.data != b.data || a.packets != b.packets || a.completionCycles != b.completionCycles ||
            a.transferEnd != b.transferEnd || a.drainedCycle != b.drainedCycle ||
            a.scalarStatus != b.scalarStatus || a.scalarEnd != b.scalarEnd) return false;
    }
    const auto off = discarded.cacheStatistics(), on = retained.cacheStatistics();
    if (!on.hits || on.compiled >= off.compiled || on.codeChanges != 256 || on.clears) return false;
    auto unsupported = programs[0];
    const uint32_t efu = CVuAssembler::Lower::ERLENG(CVuAssembler::VF1);
    std::memcpy(unsupported.data() + 40, &efu, 4);
    if (retained.run(unsupported, data, initial, 1048576).executed) return false;
    const auto beforeRecovery = retained.cacheStatistics().compiled;
    if (!retained.run(programs[0], data, initial, 1048576).executed ||
        retained.cacheStatistics().compiled != beforeRecovery) return false;
    Session pressure(Session::Arithmetic::RuntimeFused, Session::Emission::Helpers, Session::Cache::Retain);
    auto code = programs[0];
    code.fill(0);
    unsigned rejected = 0;
    for (unsigned variant = 0; variant < Session::cacheBlockLimit + 8; ++variant)
    {
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        a.Write(nop | 0xc0000000u, 0x3f000000u + variant);
        a.Write(nop, CVuAssembler::Lower::NOP());
        const auto result = pressure.run(code, data, initial, 1048576);
        if (!result.executed)
        {
            if (result.reason != "Compiled VU code cache capacity exceeded" || !result.packets.empty() ||
                result.data != data) return false;
            ++rejected;
        }
        else if (result.state.nCOP2I != 0x3f000000u + variant) return false;
        const auto stats = pressure.cacheStatistics();
        if (stats.blocks > Session::cacheBlockLimit || stats.bytes > Session::cacheByteLimit) return false;
    }
    if (!rejected || !pressure.run(programs[0], data, initial, 1048576).executed) return false;
    std::printf("[play-vu:retained-cache] passed=1 replacements=256 compiled=%llu/%llu hits=%llu bytes=%zu "
        "discarded-ms=%.3f retained-ms=%.3f capacity-rejections=%u recovery=1\n",
        static_cast<unsigned long long>(on.compiled), static_cast<unsigned long long>(off.compiled),
        static_cast<unsigned long long>(on.hits), on.bytes, discardedNs / 1e6, retainedNs / 1e6, rejected);
    return true;
}

bool compiledSessionTests()
{
    if (!cacheRetentionTests()) return false;
    {
        std::array<uint8_t, 16384> data{};
        const uint64_t tag = 0x1000000000008fffull;
        std::memcpy(data.data(), &tag, 8);
        TransferTimeline timeline(data.data());
        for (unsigned i = 0; i < 16; ++i) {
            timeline.kick(0, timeline.time);
            timeline.finish(timeline.time);
        }
        bool rejected = false;
        try { timeline.kick(0, timeline.time); timeline.finish(timeline.time); }
        catch (const std::exception &) { rejected = true; }
        if (!rejected || timeline.packets.size() != 16) return false;
        timeline.reset();
        timeline.kick(0, 0);
        timeline.finish(0);
        if (timeline.packets.size() != 1 || timeline.packets[0].size() != 65536) return false;
    }
    std::fenv_t saved{};
    std::fegetenv(&saved);
    const auto savedCsr = _mm_getcsr();
    struct Restore
    {
        std::fenv_t &environment;
        unsigned csr;
        ~Restore() { std::fesetenv(&environment); _mm_setcsr(csr); }
    } restore{saved, savedCsr};
    std::fesetround(FE_UPWARD);
    _mm_setcsr((_mm_getcsr() & ~0x8040u) | 0x20u);
    const auto callerCsr = _mm_getcsr();
    const auto callerFlags = std::fetestexcept(FE_ALL_EXCEPT);
    const auto environmentIntact = [&] {
        return std::fegetround() == FE_UPWARD && _mm_getcsr() == callerCsr &&
            std::fetestexcept(FE_ALL_EXCEPT) == callerFlags;
    };
    CompiledVuSession session;
    alignas(16) std::array<uint8_t, 16384> code{}, data{};
    MIPSSTATE initial{};
    initial.nCOP2[0].nV3 = 0x3f800000;
    initial.nCOP2[1].nV0 = 0x3f800001;
    initial.nCOP2[3].nV0 = 0x55667788;
    initial.nCOP2VI[1] = 4;
    initial.nCOP2Q = 0x3f800001;
    initial.pipeQ = {0, initial.nCOP2Q};
    const uint64_t tag = 0x1000000000008001ull;
    std::memcpy(data.data() + 64, &tag, 8);
    const auto makeCode = [&](unsigned tail) {
        code.fill(0);
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        a.Write(CVuAssembler::Upper::MULq(CVuAssembler::DEST_X, CVuAssembler::VF2,
            CVuAssembler::VF1), 0x80000efc);
        a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::SQ(CVuAssembler::DEST_XYZW,
            CVuAssembler::VF3, 5, CVuAssembler::VI0));
        for (unsigned i = 0; i < tail; ++i) a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
        a.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
        a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    };
    makeCode(0);
    const auto savedCode = code, savedData = data;
    const MIPSSTATE savedState = initial;
    const auto result = session.run(code, data, initial, 1048576);
    if (!result.executed || result.state.nCOP2[2].nV0 != 0x3f800002 ||
        result.packets.size() != 1 || result.completionCycles != std::vector<uint64_t>{3} ||
        result.packets[0].size() != 32 || result.data[80] != 0x88 || !environmentIntact() ||
        code != savedCode || data != savedData || std::memcmp(&initial, &savedState, sizeof(initial))) return false;
    const auto warm = session.run(code, data, initial, 1048576);
    if (!warm.executed || warm.data != result.data || warm.packets != result.packets ||
        std::memcmp(&warm.state, &result.state, sizeof(result.state)) || !environmentIntact()) return false;
    const uint32_t nop = CVuAssembler::Upper::NOP();
    std::memcpy(code.data() + 4, &nop, 4);
    const auto changed = session.run(code, data, initial, 1048576);
    if (!changed.executed || changed.state.nCOP2[2].nV0 || !environmentIntact()) return false;
    const auto shortSlice = session.run(code, data, initial, 64);
    if (shortSlice.executed || shortSlice.reason.empty() || !shortSlice.packets.empty() || !environmentIntact()) return false;
    makeCode(80);
    const auto longCode = code;
    const auto tooLong = session.run(code, data, initial, 65);
    if (tooLong.executed || tooLong.reason.empty() || !tooLong.packets.empty() ||
        tooLong.data != std::array<uint8_t, 16384>{} || code != longCode || data != savedData ||
        std::memcmp(&initial, &savedState, sizeof(initial)) || !environmentIntact()) return false;
    makeCode(0);
    MIPSSTATE pending = initial;
    pending.pipeP = {66, 0x3f800000};
    const auto scalarTail = session.run(code, data, pending, 65);
    if (scalarTail.executed || scalarTail.reason.empty() || !scalarTail.packets.empty() || !environmentIntact()) return false;
    code.fill(0);
    {
        CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
        const auto efu = a.CreateLabel();
        a.Write(nop, 0x80000efc);
        a.Write(nop, CVuAssembler::Lower::SQ(CVuAssembler::DEST_XYZW, CVuAssembler::VF3, 5, CVuAssembler::VI0));
        a.Write(nop, CVuAssembler::Lower::B(efu));
        a.Write(nop, CVuAssembler::Lower::NOP());
        a.MarkLabel(efu);
        a.Write(nop, CVuAssembler::Lower::ERLENG(CVuAssembler::VF1));
        a.Write(nop | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
        a.Write(nop, CVuAssembler::Lower::NOP());
    }
    for (unsigned attempt = 0; attempt < 3; ++attempt)
    {
        const auto efu = session.run(code, data, initial, 1048576);
        if (efu.executed || efu.reason.find("EFU") == std::string::npos || !efu.packets.empty() ||
            efu.data != std::array<uint8_t, 16384>{} || !environmentIntact()) return false;
    }
    auto separateEntry = initial;
    separateEntry.nPC = 40;
    if (!session.run(code, data, separateEntry, 1048576).executed || !environmentIntact()) return false;
    makeCode(0);
    const auto recovered = session.run(code, data, initial, 1048576);
    const bool passed = recovered.executed && recovered.data == result.data &&
        recovered.packets == result.packets && environmentIntact();
    std::printf("[play-vu:efu-fallback] passed=%u staged-output-discarded=1 cached-entry=1 other-entry=1 code-change=1\n",
        unsigned(passed));
    std::printf("[play-vu:session-test] passed=%u detached=1 fp-restored=1 cache-replaced=1 rejection-recovered=1\n",
        unsigned(passed));
    return passed;
}
