#include "runtime_bridge.h"
#include "VuAssembler.h"
#include <bit>
#include <cstdio>
#include <limits>
#include <stdexcept>

bool runtimeBridgeTests()
{
    VUCompiledState::Input input{};
    input.budget = 1048576;
    input.cycle = input.state.cycles = 100;
    input.state.vf[0][3] = 1;
    input.state.vf[1][0] = 7;
    input.state.q = 0.5f;
    input.state.p = 0.25f;
    input.state.top = 37;
    input.state.itop = 12;
    input.state.status = 0xf00; // Unknown sticky bits must not be copied into a claim of full coverage.
    input.state.mac = 0xff00;
    input.vfMask = 1;
    input.vfWrites[0] = {103, 2, {0x40000000, 0, 0, 0}, 1, 8, true};
    input.vfReady[1][0] = 103;
    input.vfLatest[1][0] = 2;
    input.nextSequence = 3;
    input.flagMask = 3;
    input.flags[0] = {103, 99, 0xf, 1, 0, 0x123, true, true, true, false, true};
    input.flags[1] = {101, 97, 0xf0, 2, 0, 0x321, true, true, true, false, true};
    input.branchBackupValid = true;
    input.branchBackupReg = 7;
    input.branchBackupValue = -123;
    const auto original = input;
    const auto imported = PlayVuRuntimeBridge::importState(input);
    if (imported.nCOP2[1].nV0 != 0x40000000 || imported.pipeFmacWrite[2].nV0 != 0x80 ||
        imported.pipeQ.heldValue != 0x3f000000 || imported.pipeP.heldValue != 0x3e800000 ||
        imported.pipeMac.pipeTimes[0] != 1 || imported.pipeMac.values[0] != 0xf0 ||
        imported.pipeMac.pipeTimes[1] != 3 || imported.pipeMac.values[1] != 0xf ||
        imported.savedNextBlockIntRegIdx != 7 || imported.savedNextBlockIntRegVal != uint32_t(-123)) return false;
    alignas(16) std::array<uint8_t, 16384> code{}, data{};
    CVuAssembler a(reinterpret_cast<uint32 *>(code.data()));
    a.Write(CVuAssembler::Upper::MULq(CVuAssembler::DEST_X, CVuAssembler::VF2, CVuAssembler::VF1),
        CVuAssembler::Lower::NOP());
    a.Write(CVuAssembler::Upper::NOP() | CVuAssembler::Upper::E_BIT, CVuAssembler::Lower::NOP());
    a.Write(CVuAssembler::Upper::NOP(), CVuAssembler::Lower::NOP());
    PlayVuRuntimeBridge bridge;
    const auto result = bridge.evaluate(input, code, data);
    if (!result.evaluated)
    {
        std::printf("[play-vu:typed-error] %s\n", result.reason.c_str());
        return false;
    }
    const auto &out = result.output;
    if (out.state.vf[2][0] != 1 || out.state.q != 0.5f || out.state.p != 0.25f ||
        out.elapsed < 4 || out.state.cycles != 100 + out.elapsed || out.state.top != 37 || out.state.itop != 12 ||
        out.statusMask != 0xcf3 || out.macMask != 0xff || (out.state.status & ~out.statusMask) ||
        (out.state.mac & ~out.macMask) || out.data != data ||
        std::memcmp(&input.state, &original.state, sizeof(input.state)) || input.vfWrites != original.vfWrites ||
        input.flags != original.flags || input.vfReady != original.vfReady || input.vfLatest != original.vfLatest) return false;

    const auto rejected = [&](const VUCompiledState::Input &bad) {
        const auto r = bridge.evaluate(bad, code, data);
        return !r.evaluated && !r.reason.empty() && r.output.packets.empty() &&
            !r.output.elapsed && r.output.data == std::array<uint8_t, 16384>{};
    };
    auto bad = input;
    bad.vfMask = 0;
    if (!rejected(bad)) return false;
    bad = input;
    bad.vfLatest[1][0] = 3;
    if (!rejected(bad)) return false;
    bad = input;
    bad.vfReady[1][0] = 102;
    if (!rejected(bad)) return false;
    bad = input;
    bad.vfWrites[1] = bad.vfWrites[0];
    bad.vfMask |= 2;
    if (!rejected(bad)) return false;
    bad = input;
    bad.flagMask = 0;
    if (!rejected(bad)) return false;
    bad = input;
    bad.flags[1].ready = 104;
    if (!rejected(bad)) return false;
    bad = input;
    bad.cycle = bad.state.cycles = std::numeric_limits<uint64_t>::max();
    if (!rejected(bad)) return false;
    bad = input;
    bad.budget = 64;
    if (!rejected(bad)) return false;
    for (uint32_t bits : {0x80000000u, 0x7fc00001u, 0x7f800000u, 1u})
    {
        bad = input;
        bad.state.vf[0][0] = std::bit_cast<float>(bits);
        if (!rejected(bad)) return false;
    }
    CompiledVuSession::Result incomplete;
    bool exportRejected = false;
    try { PlayVuRuntimeBridge::exportState(input, incomplete); }
    catch (const std::exception &) { exportRejected = true; }
    const auto recovered = bridge.evaluate(input, code, data);
    const bool passed = exportRejected && recovered.evaluated && recovered.output.elapsed == out.elapsed &&
        !std::memcmp(recovered.output.state.vf, out.state.vf, sizeof(out.state.vf));
    std::printf("[play-vu:typed-bridge-test] passed=%u pending-import=1 staged-export=1 partial-flags=1 runtime-accepted=0\n",
        unsigned(passed));
    return passed;
}
