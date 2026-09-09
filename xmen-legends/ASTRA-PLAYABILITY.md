# Astra playability investigation — September 9, 2026

Priority: sustained movement and combat, then FPS. No playable handoff yet.

Runtime source checkpoint: PS2Recomp `d885f1b` on
`codex/xmen-legends-bringup`. The upper-memory partition remains opt-in and
unvalidated for gameplay. Generated captures, diagnostic RAM/trace files, and
experimental binaries remain local.

## Confirmed freeze

The user identified the reference run as the same freeze: audio continues while
the world stops. Preserved private artifacts are `astra-user-freeze.*` and
`astra-user-freeze-heap.bin` in `PS2Recomp/out/xmen-final3-build`.
The final framebuffer hash repeats for 76 captured samples, ticks 1551–3993.
This particular run has no allocation failure and never logs synthetic input.
The reference does not activate Vulkan despite the launcher flag; its original
handoff JSON also records `VulkanActive=false` and rejects the workload.

Rebuilt `ps2_runtime` and the runner's `unity_0` (main/registration) against the
current configuration, then linked only `ps2EntryRunner.astra-playability.exe`.
The old runner object predates the VU XGKICK buffer layout change. Vulkan now
activates. Primary/staged/candidate executables have not been replaced.

That selected-source rebuild was insufficient: it reused an older precompiled
header. The reserved-heap run subsequently reports impossible VU counters
(`executed=4060258`, `attempted=0`, `pairs=3689915037898525696`) and still freezes.
Treat these executable results as provisional until the layout inconsistency
is eliminated. The user paused work and requested a commit/push. The compile-only
rebuild was stopped during source 8 of 107 (`unity_103_cxx.cxx`); the PCH and
earlier sources completed, but the runner object set is incomplete. Restart the
full compile-only rebuild, then perform an isolated experimental relink. Do not
infer successful movement or FPS from the earlier runs.

Resume with `build-below-normal.ps1 -CompileOnly -Target ps2EntryRunner
-Parallel 1 -MaxCompilerMiB 2048`, then `-LinkOnly -OutputName
ps2EntryRunner.astra-playability`. Keep the primary executable unchanged. Check
plausible VU counters, fresh broad world frames, sustained synthetic movement,
and heap/fault gates before any interactive handoff or FPS claim. No task-owned
game or build process remains running at this checkpoint.

## First failure, before renderer-slot damage

The rebuilt baseline reproduces exhaustion at public realloc `0x200f30`, caller
`0x28194c`, requesting 23,936 bytes. The renderer-slot request for 3,936 bytes
fails afterward. One fully validated trace contains 160,951 events, 60,702 live
blocks, 15,378,197 requested bytes and 15,725,008 padded bytes. Only 3,632 bytes
are unowned. Changing placement cannot satisfy that request.

Baseline diagnostic image `030D7476F8DB8D71A320E1B8CBBF66AB0E46EB2541EE245FC66CC660C866DC68`
and its paired first-failure RAM/trace/log evidence are retained in
`astra-heap-baseline.*`. Counts vary slightly with scheduling; do not combine
different traces as if they were one run.

## Owner identity

Diagnostics show constructor `0x213494` calling owner lookup `0x203f90` on live
compatibility pointers. Native membership `0x233710` reads metadata before the
pointer, which these allocations lack. Track the allocator supplied to the
allocation wrapper, preserve it across moving realloc, erase it on free, and
answer owner/membership/size queries from that metadata. Unknown pointers retain
native dispatch. This correction passes 67 fresh-process checks with diagnostics
off and on, including both dispatch paths and both placement/realloc modes.
It does **not** cure exhaustion; the owner-corrected gameplay run still fails.

## Explicit upper-memory partition experiment

The first-failure snapshot has zero nonzero bytes throughout 24–31 MiB. This is
corroborating evidence, not by itself a lease. The native backing provider at
`0x747610` points to vtable `0x6f8c20`; allocation entries `0x2405e0`, `0x240630`,
`0x240680`, and `0x240690` lead to libc allocation functions. Runtime guest heap
and SetupHeap remain capped at 24 MiB. The native allocator's recorded backing
table at `0x8997e0` does not own an upper-memory extent. The runtime callback
allocator was the overlapping reservation above 24 MiB.

`PS2X_XMEN_RESERVED_HEAP` / benchmark `-ReservedHeap` explicitly assigns
24–30 MiB to compatibility allocations and raises the callback-stack floor to
30 MiB in both constructor and ELF-load initialization. The native heap limit
stays 24 MiB. The fixed RPC pool at 31 MiB and retail stacks are above the lease.
The old arena remains the default. Partition tests pass with the option off/on,
checking that native allocation cannot enter the lease and callbacks cannot
descend into it. Gameplay validation is pending; do not promote this experiment
based on the memory tests alone.

All compiles use one worker, BelowNormal, affinity `0xF`, and 2048 MiB maximum.
No host input, desktop capture, upstream push, or PR is used.
