#pragma once
#include "MIPS.h"
#include <array>
#include <cstdint>

// Only FDIV I/D and their sticky counterparts. FMAC U/O remain unsupported.
class ScalarFlags
{
public:
    struct Event
    {
        uint64_t ready = 0;
        uint32_t value = 0;
        bool stickyWrite = false, valid = false;
    };
    struct State
    {
        uint32_t status = 0;
        std::array<Event, 8> events{};
    };
    void reset(const State & = {});
    uint32_t observe(CMIPS *, uint32_t opcode, uint64_t cycle, uint32_t value);
    uint32_t finish(uint64_t cycle);
    uint64_t deadline() const;
private:
    State state{};
    uint64_t time = 0;
    void advance(uint64_t);
    void queue(Event);
};

bool scalarFlagTests();
