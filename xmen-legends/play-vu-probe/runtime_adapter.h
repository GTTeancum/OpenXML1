#pragma once
#include <cstdint>
#include <string>

class VU1Interpreter;
class GS;
class PS2Memory;

struct CompiledVuCounters
{
    uint64_t attempted = 0, accepted = 0, cycles = 0;
};

struct CompiledVuDrainRejection
{
    uint64_t tick = 0;
    uint64_t cycles = 0;
    uint32_t pc = 0;
    std::string reason;
};

CompiledVuCounters compiledVuCounters();
const CompiledVuDrainRejection &compiledVuLastDrainRejection();
bool compiledVuEnabled();
bool compiledVuStreamEnabled();

// Thread-local override for paired runtime tests; the game defaults to the
// explicit PS2X_VU_COMPILED=1 opt-in. No desktop or input state is involved.
class ScopedCompiledVuMode
{
public:
    explicit ScopedCompiledVuMode(bool enabled);
    ~ScopedCompiledVuMode();
    ScopedCompiledVuMode(const ScopedCompiledVuMode &) = delete;
    ScopedCompiledVuMode &operator=(const ScopedCompiledVuMode &) = delete;
private:
    int previous;
};

// False leaves the runtime untouched. Exceptions during publication propagate:
// the caller must never fall back after graphics may have been submitted.
bool tryCompiledVuDrain(VU1Interpreter &, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &, PS2Memory *, uint32_t budget,
    std::string *rejection = nullptr);

bool tryBeginCompiledVuStream(VU1Interpreter &, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, PS2Memory *, uint32_t top, uint32_t itop,
    std::string *rejection = nullptr);
bool tryResumeCompiledVuStream(VU1Interpreter &, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &, PS2Memory *, uint32_t top, uint32_t itop,
    uint32_t budget);
void cancelCompiledVuStream(VU1Interpreter &);
