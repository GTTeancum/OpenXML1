#include "runtime_adapter.h"
#include "runtime_bridge.h"
#include "bridge_profile.h"
#include "runtime/ps2_vu1_replay.h"
#include "runtime/ps2_memory.h"
#include "runtime/gs/gs_frontend.h"
#include "runtime/runtime_profile.h"
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <chrono>
#include <fstream>
#include <limits>
#include <optional>
#include <stdexcept>

namespace
{
thread_local int modeOverride = -1;
thread_local CompiledVuCounters counters;
thread_local CompiledVuDrainRejection lastDrainRejection;

struct CompiledVuStream
{
    struct Profile
    {
        uint64_t beginCalls = 0, resumeCalls = 0;
        uint64_t captureNs = 0, codeNs = 0, importNs = 0, beginNs = 0;
        uint64_t validateNs = 0, executeNs = 0, submitNs = 0;
        uint64_t finishNs = 0, exportNs = 0, commitNs = 0;
    } profile;
    CompiledVuSession session{CompiledVuSession::Arithmetic::RuntimeFused,
        CompiledVuSession::Emission::Direct, CompiledVuSession::Cache::Retain};
    std::optional<VUCompiledState::Input> input;
    std::array<uint8_t, 16384> code{};
    uint64_t codeGeneration = 0;
    bool codeGenerationValid = false;
    VU1Interpreter *owner = nullptr;
    uint64_t slices = 0;
    uint64_t started = 0;
    uint64_t completed = 0;
    uint64_t tick = 0;
    bool trace = false;
};

thread_local CompiledVuStream stream;

uint64_t compiledVuStreamTraceMinTick();
uint64_t compiledVuRejectionTraceMinTick();

void traceCompiledVuRejection(const char *phase, const char *reason,
    VU1Interpreter &vu, PS2Memory *memory)
{
    if (!phase || std::strcmp(phase, "drain") != 0) return;
    const uint64_t tick = memory
        ? memory->gs().vsyncTick.load(std::memory_order_relaxed)
        : 0u;
    if (tick < compiledVuRejectionTraceMinTick()) return;

    static thread_local uint32_t count = 0u;
    if (count++ >= 128u) return;
    const auto &state = vu.state();
    std::fprintf(stderr,
        "[vu:compiled-reject] phase=%s tick=%llu pc=0x%x cycles=%llu "
        "top=0x%x itop=0x%x running=%u reason=%s\n",
        phase,
        static_cast<unsigned long long>(tick),
        state.pc,
        static_cast<unsigned long long>(state.cycles),
        state.top,
        state.itop,
        vu.isRunning() ? 1u : 0u,
        reason ? reason : "");
}

uint64_t compiledVuStreamTraceMinTick()
{
    static const uint64_t value = [] {
        const auto *text = std::getenv("PS2X_VU_COMPILED_STREAM_TRACE_MIN_TICK");
        if (!text || !*text) return std::numeric_limits<uint64_t>::max();
        char *end = nullptr;
        const auto parsed = std::strtoull(text, &end, 0);
        return end && end != text && !*end ? parsed : std::numeric_limits<uint64_t>::max();
    }();
    return value;
}

uint64_t compiledVuRejectionTraceMinTick()
{
    static const uint64_t value = [] {
        const auto *text = std::getenv("PS2X_VU1_SERVICE_TRACE_MIN_TICK");
        if (!text || !*text) return std::numeric_limits<uint64_t>::max();
        char *end = nullptr;
        const auto parsed = std::strtoull(text, &end, 0);
        return end && end != text && !*end ? parsed : std::numeric_limits<uint64_t>::max();
    }();
    return value;
}

uint32_t compiledVuStreamBlockBytes()
{
    static const uint32_t value = [] {
        const auto *text = std::getenv("PS2X_VU_COMPILED_STREAM_BLOCK_BYTES");
        if (!text || !*text) return 64u;
        char *end = nullptr;
        const auto parsed = std::strtoul(text, &end, 0);
        if (!end || end == text || *end || parsed < 8 || parsed > 4096 || (parsed & 7))
            throw std::runtime_error("Invalid PS2X_VU_COMPILED_STREAM_BLOCK_BYTES");
        return static_cast<uint32_t>(parsed);
    }();
    return value;
}
}

CompiledVuCounters compiledVuCounters() { return counters; }
const CompiledVuDrainRejection &compiledVuLastDrainRejection() { return lastDrainRejection; }
bool compiledVuEnabled()
{
    static const bool requested = [] {
        const auto *value = std::getenv("PS2X_VU_COMPILED");
        return value && std::strcmp(value, "1") == 0;
    }();
    return modeOverride < 0 ? requested : modeOverride != 0;
}

bool compiledVuStreamEnabled()
{
    static const bool requested = [] {
        const auto *value = std::getenv("PS2X_VU_COMPILED_STREAM");
        return value && std::strcmp(value, "1") == 0;
    }();
    if (modeOverride >= 0)
    {
        const auto *value = std::getenv("PS2X_VU_COMPILED_STREAM");
        return modeOverride != 0 && value && std::strcmp(value, "1") == 0;
    }
    return requested && compiledVuEnabled();
}
ScopedCompiledVuMode::ScopedCompiledVuMode(bool enabled) : previous(modeOverride)
{
    modeOverride = enabled ? 1 : 0;
}
ScopedCompiledVuMode::~ScopedCompiledVuMode() { modeOverride = previous; }

bool tryCompiledVuDrain(VU1Interpreter &vu, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &gs, PS2Memory *memory, uint32_t budget,
    std::string *rejection)
{
    ++counters.attempted;
    if (rejection) rejection->clear();
    const auto reject = [&](const char *reason) {
        const auto &state = vu.state();
        lastDrainRejection.tick = memory
            ? memory->gs().vsyncTick.load(std::memory_order_relaxed)
            : 0u;
        lastDrainRejection.cycles = state.cycles;
        lastDrainRejection.pc = state.pc;
        lastDrainRejection.reason = reason ? reason : "";
        traceCompiledVuRejection("drain", reason, vu, memory);
        if (rejection) *rejection = reason;
        return false;
    };
    if (!code || !data || codeSize != 16384 || dataSize != 16384)
        return reject("Unsupported VU memory shape");
    // Rejected entries still pay this validation cost before fallback.
    const auto input = VuBridgeProfile::measure(VuBridgeProfile::Stage::Capture,
        [&] { return VUCompiledState::capture(vu, budget); });
    if (!input) return reject("Unsupported VU entry or budget");

    PlayVuRuntimeBridge::Result result;
    CompiledVuSession::CacheStatistics cache;
    try
    {
        thread_local PlayVuRuntimeBridge bridge;
        std::array<uint8_t, 16384> privateCode, privateData;
        VuBridgeProfile::measure(VuBridgeProfile::Stage::Copy, [&] {
            std::memcpy(privateCode.data(), code, privateCode.size());
            std::memcpy(privateData.data(), data, privateData.size());
        });
        result = bridge.evaluate(*input, privateCode, privateData);
        cache = bridge.cacheStatistics();
    }
    catch (const std::exception &e)
    {
        return reject(e.what());
    }
    if (!result.evaluated) return reject(result.reason.c_str());
    static const char *auditPath = std::getenv("PS2X_VU_COMPILED_AUDIT");
    if (auditPath && *auditPath)
    {
        thread_local bool failed = false;
        if (failed) throw std::runtime_error("Compiled VU audit previously failed; execution remains stopped");
        thread_local std::ofstream failure(auditPath, std::ios::binary | std::ios::trunc);
        if (!failure) throw std::runtime_error("Cannot open compiled VU audit replay");
        std::string difference;
        const auto tick = memory ? memory->gs().vsyncTick.load(std::memory_order_relaxed) : 0;
        if (!VUReplay::verifyCompiledDrain(vu, *input, result.output, code, data, gs,
                tick, &failure, difference))
        {
            failed = true;
            std::fprintf(stderr, "[vu:compiled-audit-failed] accepted=%llu tick=%llu pc=0x%x cycle=%llu reason=%s\n",
                static_cast<unsigned long long>(counters.accepted), static_cast<unsigned long long>(tick),
                input->state.pc, static_cast<unsigned long long>(input->cycle), difference.c_str());
            throw std::runtime_error("Compiled VU audit stopped before live publication: " + difference);
        }
    }
    if (!VuBridgeProfile::measure(VuBridgeProfile::Stage::Commit,
        [&] { return VUCompiledState::commit(vu, *input, result.output, data, dataSize, gs, memory); }))
        return reject("Runtime rejected compiled output before publication");
    ++counters.accepted;
    counters.cycles += result.output.elapsed;
    static const bool report = std::getenv("PS2X_VU_COMPILED_STATS") != nullptr;
    if (report && counters.accepted <= 262144 && (counters.accepted & 4095) == 1)
    {
        std::fprintf(stderr, "[vu:compiled] accepted=%llu attempts=%llu cycles=%llu\n",
            static_cast<unsigned long long>(counters.accepted),
            static_cast<unsigned long long>(counters.attempted),
            static_cast<unsigned long long>(counters.cycles));
        std::fprintf(stderr, "[vu:compiled-cache] compiled=%llu hits=%llu clears=%llu changes=%llu blocks=%zu bytes=%zu\n",
            static_cast<unsigned long long>(cache.compiled), static_cast<unsigned long long>(cache.hits),
            static_cast<unsigned long long>(cache.clears), static_cast<unsigned long long>(cache.codeChanges),
            cache.blocks, cache.bytes);
    }
    return true;
}

bool tryBeginCompiledVuStream(VU1Interpreter &vu, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, PS2Memory *memory, uint32_t top, uint32_t itop,
    std::string *rejection)
{
    if (rejection) rejection->clear();
    if (!compiledVuStreamEnabled()) return false;
    const auto reject = [&](const char *reason) {
        traceCompiledVuRejection("stream-begin", reason, vu, memory);
        if (rejection) *rejection = reason;
        return false;
    };
    if (!code || !data || codeSize != 16384 || dataSize != 16384)
        return reject("Unsupported VU memory shape");
    if (stream.owner)
    {
        if (stream.owner == &vu) return true;
        throw std::runtime_error("Compiled VU stream changed owners while active");
    }
    try
    {
        using Clock = std::chrono::steady_clock;
        const bool profile = RuntimeProfile::enabled();
        const auto profileStart = profile ? Clock::now() : Clock::time_point{};
        const auto input = VUCompiledState::capture(vu, std::numeric_limits<uint32_t>::max());
        if (!input) return reject("Unsupported compiled stream entry");
        const auto captureDone = profile ? Clock::now() : Clock::time_point{};
        const std::optional<uint64_t> generation = memory ?
            std::optional<uint64_t>(memory->getVU1CodeGeneration()) : std::nullopt;
        if (!generation || !stream.codeGenerationValid || stream.codeGeneration != *generation)
            std::memcpy(stream.code.data(), code, stream.code.size());
        if (generation)
        {
            stream.codeGeneration = *generation;
            stream.codeGenerationValid = true;
        }
        else stream.codeGenerationValid = false;
        const auto codeDone = profile ? Clock::now() : Clock::time_point{};
        const auto state = PlayVuRuntimeBridge::importState(*input);
        const auto scalar = PlayVuRuntimeBridge::importScalarFlags(*input);
        const auto importDone = profile ? Clock::now() : Clock::time_point{};
        std::string reason;
        stream.session.setStreamMaximumBlockSize(compiledVuStreamBlockBytes());
        if (!stream.session.beginStreamLive(stream.code, data, dataSize, state,
                top, itop, &scalar, &reason, generation))
            return reject(reason.c_str());
        const auto beginDone = profile ? Clock::now() : Clock::time_point{};
        if (profile)
        {
            const auto ns = [](Clock::time_point first, Clock::time_point last) {
                return static_cast<uint64_t>(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(last - first).count());
            };
            ++stream.profile.beginCalls;
            stream.profile.captureNs += ns(profileStart, captureDone);
            stream.profile.codeNs += ns(captureDone, codeDone);
            stream.profile.importNs += ns(codeDone, importDone);
            stream.profile.beginNs += ns(importDone, beginDone);
        }
        stream.input = input;
        stream.owner = &vu;
        stream.slices = 0;
        stream.tick = memory ? memory->gs().vsyncTick.load(std::memory_order_relaxed) : 0;
        stream.trace = stream.tick >= compiledVuStreamTraceMinTick();
        ++stream.started;
        static const bool report = std::getenv("PS2X_VU_COMPILED_STATS") != nullptr;
        if (report && (stream.started <= 4 || (stream.started & 4095) == 1))
            std::fprintf(stderr, "[vu:compiled-stream] started=%llu completed=%llu entry=0x%x cycle=%llu\n",
                static_cast<unsigned long long>(stream.started),
                static_cast<unsigned long long>(stream.completed), input->state.pc,
                static_cast<unsigned long long>(input->cycle));
        if (stream.trace)
            std::fprintf(stderr,
                "[vu:compiled-stream-begin] serial=%llu tick=%llu entry=0x%x cycle=%llu top=0x%x itop=0x%x\n",
                static_cast<unsigned long long>(stream.started),
                static_cast<unsigned long long>(stream.tick), input->state.pc,
                static_cast<unsigned long long>(input->cycle), top, itop);
    }
    catch (const std::exception &e)
    {
        stream.session.cancelStream();
        stream.input.reset();
        stream.owner = nullptr;
        return reject(e.what());
    }
    return true;
}

bool tryResumeCompiledVuStream(VU1Interpreter &vu, const uint8_t *code, uint32_t codeSize,
    uint8_t *data, uint32_t dataSize, GS &gs, PS2Memory *memory,
    uint32_t top, uint32_t itop, uint32_t budget)
{
    using Clock = std::chrono::steady_clock;
    const bool profile = RuntimeProfile::enabled();
    const auto profileStart = profile ? Clock::now() : Clock::time_point{};
    if (stream.owner != &vu) return false;
    const std::optional<uint64_t> generation = memory ?
        std::optional<uint64_t>(memory->getVU1CodeGeneration()) : std::nullopt;
    if (!compiledVuStreamEnabled() || !code || !data || codeSize != 16384 || dataSize != 16384 ||
        (generation ? (!stream.codeGenerationValid || stream.codeGeneration != *generation) :
            std::memcmp(stream.code.data(), code, stream.code.size()) != 0))
    {
        if (stream.slices)
            throw std::runtime_error("Compiled VU stream inputs changed after execution began");
        stream.session.cancelStream();
        stream.input.reset();
        stream.owner = nullptr;
        return false;
    }
    stream.session.setStreamRegisters(top, itop);
    const auto validateDone = profile ? Clock::now() : Clock::time_point{};
    static const bool batchSlices = [] {
        const auto *value = std::getenv("PS2X_VU_COMPILED_STREAM_BATCH");
        return value && std::strcmp(value, "1") == 0;
    }();
    const uint32_t sliceBudget = batchSlices && budget == 64u ? 4096u : budget;
    auto slice = stream.session.runStreamSlice(sliceBudget, false);
    const auto executeDone = profile ? Clock::now() : Clock::time_point{};
    if (!slice.advanced)
        throw std::runtime_error("Active compiled VU stream failed: " + slice.reason);
    ++stream.slices;
    if (stream.trace)
        std::fprintf(stderr,
            "[vu:compiled-stream-slice] serial=%llu tick=%llu slice=%llu budget=%u "
            "begin=0x%x/%llu end=0x%x/%llu ended=%u packets=%zu quota=%d\n",
            static_cast<unsigned long long>(stream.started),
            static_cast<unsigned long long>(stream.tick),
            static_cast<unsigned long long>(stream.slices), sliceBudget,
            slice.beginPc, static_cast<unsigned long long>(slice.beginCycle),
            slice.endPc, static_cast<unsigned long long>(slice.endCycle),
            slice.ended ? 1u : 0u, slice.packets.size(), slice.quotaRemaining);
    for (size_t index = 0; index < slice.packets.size(); ++index)
    {
        const auto &packet = slice.packets[index];
        if (VUReplay::observeGif(packet.data(), static_cast<uint32_t>(packet.size()),
                stream.input->cycle + slice.completionCycles[index]))
            continue;
        if (memory) memory->submitGifPacket(GifPathId::Path1,
            std::move(slice.packets[index]), false);
        else gs.processGIFPacket(packet.data(), static_cast<uint32_t>(packet.size()));
    }
    const auto submitDone = profile ? Clock::now() : Clock::time_point{};
    if (profile)
    {
        const auto ns = [](Clock::time_point first, Clock::time_point last) {
            return static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(last - first).count());
        };
        ++stream.profile.resumeCalls;
        stream.profile.validateNs += ns(profileStart, validateDone);
        stream.profile.executeNs += ns(validateDone, executeDone);
        stream.profile.submitNs += ns(executeDone, submitDone);
    }
    if (!slice.ended) return true;

    auto result = stream.session.finishStream();
    const auto finishDone = profile ? Clock::now() : Clock::time_point{};
    if (!result.executed)
        throw std::runtime_error("Compiled VU stream could not finish: " + result.reason);
    auto output = PlayVuRuntimeBridge::exportState(*stream.input, std::move(result));
    const auto exportDone = profile ? Clock::now() : Clock::time_point{};
    if (!VUCompiledState::commitStream(vu, *stream.input, std::move(output),
            data, dataSize, gs, memory))
        throw std::runtime_error("Runtime rejected completed compiled VU stream");
    const auto commitDone = profile ? Clock::now() : Clock::time_point{};
    ++counters.accepted;
    counters.cycles += output.elapsed;
    ++stream.completed;
    if (stream.trace)
        std::fprintf(stderr,
            "[vu:compiled-stream-end] serial=%llu tick=%llu slices=%llu cycles=%llu\n",
            static_cast<unsigned long long>(stream.started),
            static_cast<unsigned long long>(stream.tick),
            static_cast<unsigned long long>(stream.slices),
            static_cast<unsigned long long>(output.elapsed));
    if (profile)
    {
        const auto ns = [](Clock::time_point first, Clock::time_point last) {
            return static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(last - first).count());
        };
        stream.profile.finishNs += ns(submitDone, finishDone);
        stream.profile.exportNs += ns(finishDone, exportDone);
        stream.profile.commitNs += ns(exportDone, commitDone);
        if (stream.completed == 1u || (stream.completed & 0xFFFFu) == 0u)
        {
            constexpr double kNsPerMs = 1000000.0;
            std::fprintf(stderr,
                "[vu:stream-profile] completed=%llu begins=%llu resumes=%llu "
                "capture-ms=%.3f code-ms=%.3f import-ms=%.3f begin-ms=%.3f "
                "validate-ms=%.3f execute-ms=%.3f submit-ms=%.3f finish-ms=%.3f "
                "export-ms=%.3f commit-ms=%.3f\n",
                static_cast<unsigned long long>(stream.completed),
                static_cast<unsigned long long>(stream.profile.beginCalls),
                static_cast<unsigned long long>(stream.profile.resumeCalls),
                stream.profile.captureNs / kNsPerMs,
                stream.profile.codeNs / kNsPerMs,
                stream.profile.importNs / kNsPerMs,
                stream.profile.beginNs / kNsPerMs,
                stream.profile.validateNs / kNsPerMs,
                stream.profile.executeNs / kNsPerMs,
                stream.profile.submitNs / kNsPerMs,
                stream.profile.finishNs / kNsPerMs,
                stream.profile.exportNs / kNsPerMs,
                stream.profile.commitNs / kNsPerMs);
        }
    }
    static const bool report = std::getenv("PS2X_VU_COMPILED_STATS") != nullptr;
    if (report && (stream.completed <= 4 || (stream.completed & 4095) == 1))
        std::fprintf(stderr, "[vu:compiled-stream] started=%llu completed=%llu slices=%llu cycles=%llu\n",
            static_cast<unsigned long long>(stream.started),
            static_cast<unsigned long long>(stream.completed),
            static_cast<unsigned long long>(stream.slices),
            static_cast<unsigned long long>(output.elapsed));
    stream.input.reset();
    stream.owner = nullptr;
    return true;
}

void cancelCompiledVuStream(VU1Interpreter &vu)
{
    if (stream.owner != &vu) return;
    stream.session.cancelStream();
    stream.input.reset();
    stream.owner = nullptr;
}
