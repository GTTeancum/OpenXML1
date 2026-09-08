#pragma once
#include "MIPS.h"
#include "scalar_flags.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
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
        uint64_t efuEnd = 0;
        bool scalarFlagsValid = false;
        bool dataIsLive = false;
    };
    struct StreamSlice
    {
        bool advanced = false;
        bool ended = false;
        std::string reason;
        uint64_t beginCycle = 0;
        uint64_t endCycle = 0;
        uint32_t beginPc = 0;
        uint32_t endPc = 0;
        int32_t quotaRemaining = 0;
        std::vector<std::vector<uint8_t>> packets;
        std::vector<uint64_t> completionCycles;
        std::vector<uint64_t> blockEnds;
        std::vector<uint32_t> blockPcs;
        std::vector<uint32_t> blockStatePcs;
    };
    explicit CompiledVuSession(Arithmetic = Arithmetic::Separate, Emission = Emission::Environment,
        Cache = Cache::Environment);
    uint64_t directInstructionsCompiled() const;
    CacheStatistics cacheStatistics() const;
    void setStreamMaximumBlockSize(uint32_t bytes);
    ~CompiledVuSession();
    CompiledVuSession(const CompiledVuSession &) = delete;
    CompiledVuSession &operator=(const CompiledVuSession &) = delete;
    // nCOP2SF/pipeSticky pack sticky Z/S/U/O lane masks in bits 0..15 and
    // current masks in bits 16..31. Use the typed bridge for architectural input.
    Result run(const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> &data, const MIPSSTATE &state,
        uint32_t budget, uint32_t top = 0, uint32_t itop = 0,
        const ScalarFlags::State *scalarState = nullptr);
    bool beginStream(const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> &data, const MIPSSTATE &state,
        uint32_t top = 0, uint32_t itop = 0,
        const ScalarFlags::State *scalarState = nullptr, std::string *reason = nullptr);
    bool beginStreamLive(const std::array<uint8_t, 16384> &code,
        uint8_t *data, size_t dataSize, const MIPSSTATE &state,
        uint32_t top = 0, uint32_t itop = 0,
        const ScalarFlags::State *scalarState = nullptr, std::string *reason = nullptr,
        std::optional<uint64_t> codeGeneration = std::nullopt);
    void setStreamRegisters(uint32_t top, uint32_t itop);
    StreamSlice runStreamSlice(uint32_t budget, bool collectBlockTrace = true);
    Result finishStream();
    void cancelStream();
private:
    bool beginStreamInternal(const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> *ownedData, uint8_t *liveData,
        const MIPSSTATE &state, uint32_t top, uint32_t itop,
        const ScalarFlags::State *scalarState, std::string *reason,
        std::optional<uint64_t> codeGeneration);
    struct Impl;
    std::unique_ptr<Impl> impl;
};

bool compiledSessionTests();
uint64_t compiledVuDrainCycle(const MIPSSTATE &, uint64_t transferEnd);
