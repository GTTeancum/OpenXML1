#pragma once
#include "MIPS.h"
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
    };
    CompiledVuSession();
    ~CompiledVuSession();
    CompiledVuSession(const CompiledVuSession &) = delete;
    CompiledVuSession &operator=(const CompiledVuSession &) = delete;
    Result run(const std::array<uint8_t, 16384> &code,
        const std::array<uint8_t, 16384> &data, const MIPSSTATE &state,
        uint32_t budget, uint32_t top = 0, uint32_t itop = 0);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

bool compiledSessionTests();
uint64_t compiledVuDrainCycle(const MIPSSTATE &, uint64_t transferEnd);
