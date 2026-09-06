#include "runtime_adapter.h"
#include "runtime_bridge.h"
#include "runtime/ps2_vu1_replay.h"
#include "runtime/ps2_memory.h"
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <stdexcept>

namespace
{
thread_local int modeOverride = -1;
thread_local CompiledVuCounters counters;
}

CompiledVuCounters compiledVuCounters() { return counters; }
bool compiledVuEnabled()
{
    static const bool requested = [] {
        const auto *value = std::getenv("PS2X_VU_COMPILED");
        return value && std::strcmp(value, "1") == 0;
    }();
    return modeOverride < 0 ? requested : modeOverride != 0;
}
ScopedCompiledVuMode::ScopedCompiledVuMode(bool enabled) : previous(modeOverride)
{
    modeOverride = enabled ? 1 : 0;
}
ScopedCompiledVuMode::~ScopedCompiledVuMode() { modeOverride = previous; }

bool tryCompiledVuDrain(VU1Interpreter &vu, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &gs, PS2Memory *memory, uint32_t budget,
    std::string *rejection)
{
    ++counters.attempted;
    if (rejection) rejection->clear();
    const auto reject = [&](const char *reason) {
        if (rejection) *rejection = reason;
        return false;
    };
    if (!code || !data || codeSize != 16384 || dataSize != 16384)
        return reject("Unsupported VU memory shape");
    const auto input = VUCompiledState::capture(vu, budget);
    if (!input) return reject("Unsupported VU entry or budget");

    PlayVuRuntimeBridge::Result result;
    try
    {
        thread_local PlayVuRuntimeBridge bridge;
        std::array<uint8_t, 16384> privateCode, privateData;
        std::memcpy(privateCode.data(), code, privateCode.size());
        std::memcpy(privateData.data(), data, privateData.size());
        result = bridge.evaluate(*input, privateCode, privateData);
    }
    catch (const std::exception &e)
    {
        return reject(e.what());
    }
    if (!result.evaluated) return reject(result.reason.c_str());
    static const char *auditPath = std::getenv("PS2X_VU_COMPILED_AUDIT");
    if (auditPath && *auditPath)
    {
        thread_local bool failed = false;
        if (failed) throw std::runtime_error("Compiled VU audit previously failed; execution remains stopped");
        thread_local std::ofstream failure(auditPath, std::ios::binary | std::ios::trunc);
        if (!failure) throw std::runtime_error("Cannot open compiled VU audit replay");
        std::string difference;
        const auto tick = memory ? memory->gs().vsyncTick.load(std::memory_order_relaxed) : 0;
        if (!VUReplay::verifyCompiledDrain(vu, *input, result.output, code, data, gs,
                tick, &failure, difference))
        {
            failed = true;
            std::fprintf(stderr, "[vu:compiled-audit-failed] accepted=%llu tick=%llu pc=0x%x cycle=%llu reason=%s\n",
                static_cast<unsigned long long>(counters.accepted), static_cast<unsigned long long>(tick),
                input->state.pc, static_cast<unsigned long long>(input->cycle), difference.c_str());
            throw std::runtime_error("Compiled VU audit stopped before live publication: " + difference);
        }
    }
    if (!VUCompiledState::commit(vu, *input, result.output, data, dataSize, gs, memory))
        return reject("Runtime rejected compiled output before publication");
    ++counters.accepted;
    counters.cycles += result.output.elapsed;
    static const bool report = std::getenv("PS2X_VU_COMPILED_STATS") != nullptr;
    if (report && counters.accepted <= 262144 && (counters.accepted & 4095) == 1)
        std::fprintf(stderr, "[vu:compiled] accepted=%llu attempts=%llu cycles=%llu\n",
            static_cast<unsigned long long>(counters.accepted),
            static_cast<unsigned long long>(counters.attempted),
            static_cast<unsigned long long>(counters.cycles));
    return true;
}
