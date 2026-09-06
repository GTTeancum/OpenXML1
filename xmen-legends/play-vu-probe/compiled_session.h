#pragma once
#include "MIPS.h"
#include "scalar_flags.h"
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Detached execution only. The caller must validate architectural conversion
// before committing this result to a runtime or submitting its graphics packets.
class CompiledVuSession
{
public:
    enum class Arithmetic { Separate, RuntimeFused };
    enum class Emission { Environment, Helpers, Direct };
    enum class Cache { Environment, Discard, Retain };
    struct CacheStatistics
    {
        uint64_t compiled = 0, hits = 0, clears = 0, codeChanges = 0;
        size_t blocks = 0, bytes = 0;
    };
    static constexpr size_t cacheBlockLimit = 2048;
    static constexpr size_t cacheByteLimit = 8 * 1024 * 1024;
    struct Result
    {
        bool executed = false;
        std::string reason;
        MIPSSTATE state{};
        std::array<uint8_t, 16384> data{};
        std::vector<std::vector<uint8_t>> packets;
        std::vector<uint64_t> completionCycles;
        uint64_t transferEnd = 0;
        uint64_t drainedCycle = 0;
        uint32_t scalarStatus = 0;
        uint64_t scalarEnd = 0;
        bool scalarFlagsValid = false;
    };
    explicit CompiledVuSession(Arithmetic = Arithmetic::Separate, Emission = Emission::Environment,
        Cache = Cache::Environment);
    uint64_t directInstructionsCompiled() const;
    CacheStatistics cacheStatistics() const;
    ~CompiledVuSession();
    CompiledVuSession(const CompiledVuSession &) = delete;
    CompiledVuSession &operator=(const CompiledVuSession &) = delete;
    // nCOP2SF/pipeSticky pack sticky Z/S/U/O lane masks in bits 0..15 and
    // current masks in bits 16..31. Use the typed bridge for architectural input.
    Result run(const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> &data, const MIPSSTATE &state,
        uint32_t budget, uint32_t top = 0, uint32_t itop = 0,
        const ScalarFlags::State *scalarState = nullptr);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

bool compiledSessionTests();
uint64_t compiledVuDrainCycle(const MIPSSTATE &, uint64_t transferEnd);
