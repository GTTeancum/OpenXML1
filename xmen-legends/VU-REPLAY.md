# VU Slice Replay

The bring-up runtime has an opt-in, process-local VU1 recorder. Use it to check
and time interpreter changes against actual game work without repeating startup.
This is not a replacement for first-level gameplay validation.

## Capture

Set `PS2X_VU_REPLAY_CAPTURE` to an absolute path inside the ignored extracted-disc
directory before launching a guarded first-level probe. The recorder samples
after guest vsync tick 1100, retaining at most 16 short slices (budgets up to 64
cycles) and 16 longer slices. Short slices use deterministic 1-in-64 sampling.
The complete file is capped at 4 MiB; individual records are capped at 1 MiB.
Recording is disabled when the environment variable is absent.

Probe 2262 created `xmen-legends/disc/vu-replay.bin`: 32 cases, 1,914,088 bytes.
It reached present 1200, closed under the guard, and restored the startup archive.
Keep this file private: it contains retail microcode and memory. Do not commit,
attach to an upstream issue, or redistribute it.

## Replay

Build `ps2x_tests` through the BelowNormal, one-worker build wrapper, then run:

```powershell
Get-ChildItem Env:PS2X_* -ErrorAction SilentlyContinue | Remove-Item
$hostProcess = [Diagnostics.Process]::GetCurrentProcess()
$hostProcess.PriorityClass = 'Normal'
$hostProcess.ProcessorAffinity = [IntPtr]0xF
$env:MINITEST_FILTER = 'recorded VU slices'
$env:PS2X_VU_REPLAY_FILE = Join-Path $PWD 'xmen-legends/disc/vu-replay.bin'
$env:PS2X_VU_REPLAY_REPEATS = '128'
& .\PS2Recomp\out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe
```

Replay has no game window, audio device, host input, or GS packet submission.
Each case starts with its captured code, memory, registers, pending pipeline
entries, readiness state, and partial PATH1 transfer. Every repeat compares:

- Canonically serialized post-execution architectural and pipeline state.
- Every byte of the 16 KiB VU1 data memory.
- Every emitted GIF packet byte and its VU emission cycle.

Code writes use local memory-generation tracking. The first execution checks a
cold decode cache and is excluded from timings. Timed repeats exclude snapshot
restoration, serialization, and comparison, but include recording emitted packets.
Limits are 64 cases, 4 MiB input, 4096 repeats, and 100 million expected cycles.
The binary format is versioned by the `VUR1` magic; incompatible snapshot changes
must use a new version, not silently reinterpret old captures.

## September 4 Results

- Before optimization: 32 cases x 128 repeats = 4096 timed executions and
  5,222,784 simulated cycles, with no mismatches. Digest `75d4ff1e67bbbc4c`.
- Removing duplicate same-cycle retirement checks preserves the same digest and
  passes all 96 then-existing local VU tests. Nine interleaved before/after runs
  measured medians of 589.740 ms and 564.147 ms (about 4.3% less execution time).
- Contiguous-qword PATH1 copying also preserves the same game replay results.
  Its incremental timing was noisy; no separate speedup is claimed. All 97 local
  VU tests pass, including new wrapping and zero/one-cycle resume checks.
- Ordinary full-rendering Probe 2263 reached present 1280 with textured New York
  and Wolverine. An external log observer measured 3.1218 FPS over 128 gameplay
  frames. Existing lighting/HUD defects remain; this is not yet practical speed.
- Generic cycle-work changes are submitted as
  [PS2Recomp PR #248](https://github.com/ran-j/PS2Recomp/pull/248), now with 427/427
  upstream-main-based tests passing. Replay diagnostics are not part of that PR.
- The VI-mask follow-up passes 98/98 local VU tests. Nine longer interleaved pairs
  use 512 repeats per case: 16,384 timed slices and 20,891,136 cycles per run.
  Median time falls from 2299.731 ms to 1981.324 ms (13.85%) with the same digest.
  Every candidate run in that batch is faster than every baseline run. The
  preceding shorter batch was noisier and is not the primary timing result.
- Ordinary Probe 2264 preserves textured first-level output and measures
  3.2485 FPS over 128 frames (39.4022 seconds). The smaller end-to-end gain is
  not an isolated or sustained-speed guarantee. Both runtime and observer closed.

These samples cover only captured VU work, not every game program or full-frame
cost. They do not verify GS rendering, audio, gameplay control, or hardware
accuracy. Synthetic tests and an ordinary full-rendering game run remain required.
Do not use a replay timing improvement as a gameplay FPS claim.

## Offline Sampling

On Windows x64, `PS2X_VU_REPLAY_PROFILE=1` enables a test-only sampler. It duplicates
only the calling test thread's handle, briefly suspends that thread to read its
instruction pointer, and resumes it before allocating or logging. It never
attaches to another process, drives a window, or sends host input. Do not use it
for ordinary gameplay, wall-time benchmarks, or live correctness runs. Its
instrumented replay timings are not performance results.

The test executable's MSVC linker map is overwritten in one fixed slot on build
(about 10 MB). The report checks the executable/map timestamp before resolving
sample RVAs. It rejects missing or mismatched identities. Sample storage is
bounded at 8192 successful samples and 4096 unique addresses.

```powershell
$env:PS2X_VU_REPLAY_REPEATS = '2048'
$env:PS2X_VU_REPLAY_PROFILE = '1'
& .\PS2Recomp\out\xmen-final3-build\ps2xTest\Release\ps2x_tests.exe `
    *> xmen-legends/vu-replay-sample-confirm.log
& .\xmen-legends\summarize-vu-sampler.ps1 `
    -LogPath xmen-legends/vu-replay-sample-confirm.log
Remove-Item Env:PS2X_VU_REPLAY_PROFILE
```

Run the earlier replay setup first so the filter and input file are set. The
confirmation profile checks 65,536 timed slices / 83,564,544 VU cycles with the
same digest. It records 895 samples: 119 outside the executable, 776 inside,
377 distinct in-module addresses, no drops, and no sampling failures.

Among in-module samples, `commitReadyPipelines` is 22.29%, `queueVfWrite` 9.28%,
and `updateFmacFlags` 8.63%. `run` is 12.76%, `execUpper` 10.57%, and
`calculateFmacExactResult` 8.63%. These include replay setup/comparison and are
sampling estimates, not percentages of a production frame. An earlier profile
also places retirement near 22%. This prioritizes completion-cycle indexing of
pending queues before another broad arithmetic rewrite.

`tests/test-vu-sampler-report.ps1` checks attribution, percentages, mismatched
builds, missing identity, and empty samples using small synthetic fixtures.
