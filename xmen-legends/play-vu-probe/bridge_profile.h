#pragma once
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <utility>

namespace VuBridgeProfile
{
enum class Stage : unsigned { Capture, Copy, Import, ScalarImport, Execute, Export, Commit, Count };
using Clock = std::chrono::steady_clock;
struct Totals
{
    struct Entry { unsigned long long calls = 0, ns = 0; };
    std::array<Entry, static_cast<unsigned>(Stage::Count)> entries{};
    ~Totals()
    {
        constexpr const char* names[] = {"capture", "copy", "import", "scalar-import", "execute", "export", "commit"};
        for (unsigned i = 0; i < entries.size(); ++i)
            if (entries[i].calls)
                std::fprintf(stderr, "[vu:bridge-profile] stage=%s calls=%llu ns=%llu\n",
                    names[i], entries[i].calls, entries[i].ns);
    }
};
inline thread_local Totals totals;

template<class Operation>
decltype(auto) measure(Stage stage, Operation&& operation)
{
    static const bool enabled = std::getenv("PS2X_VU_BRIDGE_PROFILE") != nullptr;
    if (!enabled) return std::forward<Operation>(operation)();
    struct Timer
    {
        Totals::Entry& entry;
        Clock::time_point start = Clock::now();
        ~Timer()
        {
            ++entry.calls;
            entry.ns += std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - start).count();
        }
    } timer{totals.entries[static_cast<unsigned>(stage)]};
    return std::forward<Operation>(operation)();
}
}
