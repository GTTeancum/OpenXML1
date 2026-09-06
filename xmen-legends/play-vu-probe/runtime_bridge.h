#pragma once
#include "compiled_session.h"
#include "ps2_vu_compiled_state.h"

// Conversion for detached full drains; the runtime validates output before commit.
class PlayVuRuntimeBridge
{
public:
    struct Result
    {
        bool evaluated = false;
        std::string reason;
        VUCompiledState::Output output{};
    };
    static MIPSSTATE importState(const VUCompiledState::Input &);
    static ScalarFlags::State importScalarFlags(const VUCompiledState::Input &);
    static VUCompiledState::Output exportState(const VUCompiledState::Input &, CompiledVuSession::Result);
    Result evaluate(const VUCompiledState::Input &, const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> &data);
    CompiledVuSession::CacheStatistics cacheStatistics() const { return session.cacheStatistics(); }
private:
    CompiledVuSession session{CompiledVuSession::Arithmetic::RuntimeFused};
};

bool runtimeBridgeTests();
