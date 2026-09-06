#pragma once
#include <cstdint>
#include <vector>

// Diagnostic counterpart of PS2Recomp's two-cycle/qword PATH1 transfer.
// It observes memory at store boundaries; it never writes guest memory or stalls VU.
class TransferTimeline
{
public:
    explicit TransferTimeline(const uint8_t *memory) : memory(memory) {}
    void reset();
    void advance(uint64_t cycle);
    void kick(uint32_t qword, uint64_t cycle);
    void finish(uint64_t cycle);
    std::vector<std::vector<uint8_t>> packets;
    std::vector<uint64_t> completionCycles;
    uint64_t time = 0;
    unsigned events = 0;

private:
    const uint8_t *memory;
    bool active = false;
    bool eop = false;
    uint32_t source = 0;
    uint32_t tagEnd = 0;
    uint64_t nextRead = 0;
    size_t completedBytes = 0;
    std::vector<uint8_t> packet;
};
