#include "transfer_timeline.h"
#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace
{
constexpr size_t kMaximumStagedBytes = 16u * 1024u * 1024u;
}

void TransferTimeline::reset()
{
    active = false;
    eop = false;
    source = tagEnd = 0;
    nextRead = time = 0;
    events = 0;
    completedBytes = 0;
    packet.clear();
    packets.clear();
    completionCycles.clear();
}

void TransferTimeline::advance(uint64_t cycle)
{
    if (cycle < time) throw std::runtime_error("VU memory events moved backward");
    while (active && nextRead <= cycle)
    {
        if (packet.size() >= kMaximumStagedBytes)
            throw std::runtime_error("Timeline packet exceeds staging limit");
        const size_t offset = packet.size();
        // Memory is stable within this observation. Never read beyond the
        // ready cycle or a known GIFtag boundary; unknown tags are read alone.
        const uint64_t available = (cycle - nextRead) / 2 + 1;
        const size_t qwords = tagEnd ? static_cast<size_t>(std::min<uint64_t>(
            available, (tagEnd - offset) / 16)) : 1;
        const size_t bytes = qwords * 16;
        packet.resize(offset + bytes);
        for (size_t copied = 0; copied < bytes;)
        {
            const size_t address = (source + offset + copied) & 16383u;
            const size_t count = std::min(bytes - copied, 16384 - address);
            std::memcpy(packet.data() + offset + copied, memory + address, count);
            copied += count;
        }
        const uint64_t lastRead = nextRead + (qwords - 1) * 2;
        nextRead += qwords * 2;
        if (!tagEnd)
        {
            uint64_t tag = 0;
            std::memcpy(&tag, packet.data() + offset, 8);
            const uint32_t loops = static_cast<uint32_t>(tag & 0x7fffu);
            const uint32_t format = static_cast<uint32_t>((tag >> 58) & 3u);
            uint32_t registers = static_cast<uint32_t>(tag >> 60);
            if (!registers) registers = 16;
            const uint32_t payload = format == 0 ? loops * registers * 16u :
                format == 1 ? ((loops * registers + 1u) / 2u) * 16u : loops * 16u;
            if (offset > kMaximumStagedBytes - 16u - payload)
                throw std::runtime_error("Timeline GIF tag exceeds staging limit");
            tagEnd = static_cast<uint32_t>(offset + 16u + payload);
            eop = (tag & 0x8000u) != 0;
        }
        if (packet.size() == tagEnd)
        {
            if (eop)
            {
                if (packets.size() >= 1024) throw std::runtime_error("Too many timeline packets");
                if (packet.size() > kMaximumStagedBytes - completedBytes)
                    throw std::runtime_error("Staged VU graphics exceed staging limit");
                completedBytes += packet.size();
                packets.push_back(packet);
                completionCycles.push_back(lastRead);
                active = false;
            }
            tagEnd = 0;
        }
    }
    time = cycle;
}

void TransferTimeline::kick(uint32_t qword, uint64_t cycle)
{
    advance(cycle);
    if (active) throw std::runtime_error("Timeline requires a VU stall before overlapping XGKICK");
    source = (qword & 1023u) * 16u;
    packet.clear();
    tagEnd = 0;
    eop = false;
    active = true;
    nextRead = cycle + 1;
}

void TransferTimeline::finish(uint64_t cycle)
{
    advance(cycle);
    while (active)
    {
        const size_t qwords = tagEnd ? (tagEnd - packet.size()) / 16 : 1;
        advance(nextRead + (qwords - 1) * 2);
    }
}
