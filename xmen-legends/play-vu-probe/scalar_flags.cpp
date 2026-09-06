#include "scalar_flags.h"
#include <algorithm>
#include <stdexcept>

void ScalarFlags::reset(const State &initial)
{
    if (initial.status & ~0xc30u) throw std::runtime_error("Invalid scalar status bits");
    for (const auto &e : initial.events)
        if (e.valid && (!e.ready || e.ready > 1048576 ||
            (e.value & ~(e.stickyWrite ? 0xc00u : 0x30u))))
            throw std::runtime_error("Invalid pending scalar flag event");
    state = initial;
    time = 0;
}

void ScalarFlags::advance(uint64_t cycle)
{
    if (cycle < time) throw std::runtime_error("Scalar flag time moved backward");
    for (;;)
    {
        Event *next = nullptr;
        for (auto &e : state.events)
        {
            if (!e.valid || e.ready > cycle) continue;
            // FMAC/FSSET retirement precedes FDIV retirement on the same cycle.
            if (!next || e.ready < next->ready || (e.ready == next->ready && e.stickyWrite && !next->stickyWrite)) next = &e;
        }
        if (!next) break;
        if (next->stickyWrite) state.status = (state.status & 0x30) | next->value;
        else state.status = (state.status & 0xc00) | next->value | (next->value << 6);
        next->valid = false;
    }
    time = cycle;
}

void ScalarFlags::queue(Event event)
{
    for (auto &slot : state.events)
        if (!slot.valid) { slot = event; return; }
    throw std::runtime_error("Scalar flag queue is full");
}

uint32_t ScalarFlags::observe(CMIPS *cpu, uint32_t opcode, uint64_t cycle, uint32_t value)
{
    advance(cycle);
    const auto major = opcode >> 25;
    if (major == 0x16 || major == 0x17) return (value & ~0xc30u) | state.status;
    if (major == 0x15)
    {
        const auto immediate = (opcode & 0x7ff) | ((opcode >> 10) & 0x800);
        queue({cycle + 4, immediate & 0xc00, true, true});
        return value;
    }
    const auto instruction = opcode & 0x800007ffu;
    if (instruction != 0x800003bcu && instruction != 0x800003bdu && instruction != 0x800003beu)
        throw std::runtime_error("Unknown scalar flag instruction");
    const auto &s = cpu->m_State;
    const auto numerator = s.nCOP2[(opcode >> 11) & 31].nV[(opcode >> 21) & 3];
    const auto denominator = s.nCOP2[(opcode >> 16) & 31].nV[(opcode >> 23) & 3];
    // Exponent-zero PS2 operands are signed zero, including denormals.
    const bool numeratorZero = !(numerator & 0x7f800000);
    const bool denominatorZero = !(denominator & 0x7f800000);
    const bool negative = !denominatorZero && (denominator & 0x80000000);
    uint32_t flags = 0;
    if (instruction == 0x800003bc) flags = denominatorZero ? (numeratorZero ? 0x10u : 0x20u) : 0u;
    else if (instruction == 0x800003bd) flags = negative ? 0x10u : 0u;
    else flags = denominatorZero ? (numeratorZero ? 0x30u : 0x20u) : (negative ? 0x10u : 0u);
    const uint64_t ready = s.pipeQ.counter;
    const uint64_t latency = instruction == 0x800003be ? 13 : 7;
    if (ready != cycle + latency) throw std::runtime_error("Scalar flag deadline disagrees with Q pipeline");
    queue({ready, flags, false, true});
    return value;
}

uint32_t ScalarFlags::finish(uint64_t cycle)
{
    advance(cycle);
    for (const auto &e : state.events)
        if (e.valid) throw std::runtime_error("Scalar flags still pending at completed drain");
    return state.status;
}

uint64_t ScalarFlags::deadline() const
{
    uint64_t last = 0;
    for (const auto &e : state.events) if (e.valid) last = std::max(last, e.ready);
    return last;
}
