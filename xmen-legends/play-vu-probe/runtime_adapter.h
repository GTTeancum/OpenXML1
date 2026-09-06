#pragma once
#include <cstdint>
#include <string>

class VU1Interpreter;
class GS;
class PS2Memory;

// False leaves the runtime untouched. Exceptions during publication propagate:
// the caller must never fall back after graphics may have been submitted.
bool tryCompiledVuDrain(VU1Interpreter &, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &, PS2Memory *, uint32_t budget,
    std::string *rejection = nullptr);
