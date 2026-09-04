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
  [PS2Recomp PR #248](https://github.com/ran-j/PS2Recomp/pull/248), with 426/426
  upstream-main-based tests passing. Replay diagnostics are not part of that PR.

These samples cover only captured VU work, not every game program or full-frame
cost. They do not verify GS rendering, audio, gameplay control, or hardware
accuracy. Synthetic tests and an ordinary full-rendering game run remain required.
Do not use a replay timing improvement as a gameplay FPS claim.
