#include "transfer_timeline.h"
#include <cstring>
#include <stdexcept>

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
        if (packet.size() >= 65536) throw std::runtime_error("Timeline packet exceeds 64 KiB");
        const size_t offset = packet.size();
        for (unsigned byte = 0; byte < 16; ++byte)
            packet.push_back(memory[(source + offset + byte) & 16383u]);
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
            if (offset + 16u + payload > 65536u) throw std::runtime_error("Timeline GIF tag exceeds limit");
            tagEnd = static_cast<uint32_t>(offset + 16u + payload);
            eop = (tag & 0x8000u) != 0;
        }
        if (packet.size() == tagEnd)
        {
            if (eop)
            {
                if (packets.size() >= 1024) throw std::runtime_error("Too many timeline packets");
                if (completedBytes + packet.size() > 1048576)
                    throw std::runtime_error("Staged VU graphics exceed 1 MiB");
                completedBytes += packet.size();
                packets.push_back(packet);
                completionCycles.push_back(nextRead);
                active = false;
            }
            tagEnd = 0;
        }
        nextRead += 2;
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
    while (active) advance(nextRead);
}
