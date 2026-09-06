#include "compiled_session.h"
#include "VuAssembler.h"
#include "transfer_timeline.h"
#include <cfenv>
#include <cstdio>
#include <cstring>
#include <xmmintrin.h>

bool compiledSessionTests()
{
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
    const auto recovered = session.run(code, data, initial, 1048576);
    const bool passed = recovered.executed && recovered.data == result.data &&
        recovered.packets == result.packets && environmentIntact();
    std::printf("[play-vu:session-test] passed=%u detached=1 fp-restored=1 cache-replaced=1 rejection-recovered=1\n",
        unsigned(passed));
    return passed;
}
