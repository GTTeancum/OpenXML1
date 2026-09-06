#pragma once
#include <array>
#include <cstdint>

namespace CompiledEfu
{
struct Result
{
    uint32_t bits;
    uint32_t latency;
};
// Matches the current runtime's MSVC AVX2 fused lowering, not a hardware oracle.
// Caller supplies round-toward-zero arithmetic. No flags or CPU state are changed.
// The latency is result visibility; the EFU can accept new work one cycle earlier.
Result evaluateRuntimeFused(uint32_t function, unsigned component, const std::array<uint32_t, 4> &source);
}
