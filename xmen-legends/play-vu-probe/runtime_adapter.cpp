#include "runtime_adapter.h"
#include "runtime_bridge.h"
#include <cstring>

bool tryCompiledVuDrain(VU1Interpreter &vu, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &gs, PS2Memory *memory, uint32_t budget,
    std::string *rejection)
{
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
    if (!VUCompiledState::commit(vu, *input, result.output, data, dataSize, gs, memory))
        return reject("Runtime rejected compiled output before publication");
    return true;
}
