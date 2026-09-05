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

## Rejected Experiments

Two September 4 experiments preserved the real-game replay exactly but did not
earn integration. The ordinary gameplay executable was not replaced or launched.

- An eight-bucket completion-cycle index for flag/VF queues passed 100 focused
  VU tests. Nine alternating pairs at 512 repeats per case had medians
  2148.903 ms baseline / 2131.059 ms candidate. Seven longer pairs at 2048
  repeats had medians 7873.528 / 7956.781 ms. Results were noisy and did not
  establish a benefit. The derived indices and snapshot reconstruction were
  removed; slot-reuse, zero/one-cycle resume, and restart/reset tests remain.
- Returning cached instruction descriptions by reference passed 119 VU-related
  tests, including edited code on tracked, untracked, misaligned-PC, and
  nullable-memory paths. Nine alternating pairs at 1024 repeats per case had
  medians 3923.547 / 4080.658 ms, about 4% slower. The runtime change was removed;
  the new cache-path regression remains.

All measured repetitions kept digest `75d4ff1e67bbbc4c`. These shared-machine
timings do not justify another full-boot performance probe. The next larger
target is compiled VU execution, tested offline against the interpreter before
integration. Preserve cycle-budget boundaries, code invalidation, pending
arithmetic, and graphics-packet timing; do not relax the oracle to force a pass.

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
also places retirement near 22%. The completion-cycle index was subsequently
tested and rejected above; do not repeat it without new evidence.

`tests/test-vu-sampler-report.ps1` checks attribution, percentages, mismatched
builds, missing identity, and empty samples using small synthetic fixtures.

## Native Upper Prototype

The experimental `PS2X_ENABLE_VU_NATIVE_UPPER` CMake option is OFF by default.
It compiles constant upper-instruction words using the interpreter's own shared
arithmetic definitions. Lower instructions, cycle budgets, queues, hazards, and
PATH1 submission still use the interpreter. This is not yet a compiled-block VU
engine, nor a gameplay-speed claim.

The offline replay can generate a bounded private instruction recipe by setting
`PS2X_VU_REPLAY_UPPER_EXPORT` to `disc/vu-native-upper-words.inc`. The additional
cold pass uses one-cycle slices and must reproduce the original saved result.
Its counts include dependency-stall retries: they identify fetched candidates,
not executed-instruction frequencies. The existing 32-case capture yields 105
unique candidates. Never publish the capture, recipe, generated kernels, or the
retail-derived native DLL.

Pass the absolute recipe path as `PS2X_VU_NATIVE_WORDS_FILE` when configuring the
native build. Without a private recipe, it builds only public synthetic kernels.
Recipes are limited to 64 KiB and 512 unique words; only the fixed numeric macro
syntax is accepted. Generated translation units contain at most eight kernels,
with separate object-library targets to prevent MSVC's multi-file batching.
The initial forced-inlining build grew beyond 14 GiB of compiler working memory
and was stopped. The revised path uses template instruction selection and normal
inlining; do not restore forced inlining of the entire arithmetic graph or merge
these sources into a unity build. The build helper's default 2048 MiB per-compiler
private-memory watchdog has also been exercised on an oversized attempt.

The Windows x64 module uses an exact-build interface checked against source
fingerprints, compiler identity, configuration, and state layout. Unknown words
fall back to the interpreter. Tests and the opt-in runner use the same loader.
Set `PS2X_VU_NATIVE_MODULE` to the absolute path of the matching DLL to enable it
in a native-enabled runner; omit the variable to use its interpreter. An explicit
request with an unavailable/incompatible module fails before opening the game.
VU provider changes clear the decode cache, and the caller must detach/destroy
interpreters before unloading. This does not change ordinary builds, where the
CMake option remains OFF. The first game validation is recorded below.

Set `PS2X_VU_REPLAY_NATIVE=1` to test the native provider. Leave it absent for the
interpreted comparison in the same native-enabled test executable. Coverage
counts include the cold pass. `compare-vu-native.ps1` alternates both modes,
checks unchanged executable/module/capture hashes and the full replay digest,
and stores one overwritten report at `disc/vu-native-comparison.json`. It runs
only process-local tests at Normal priority on four logical processors, with
no profiler or image capture. Runtime binaries remain unchanged until a useful
gain and ordinary-game validation justify integration.

September 4 flag-specialization validation: all 122 VU-related tests pass. The
native-only synthetic replay now covers 173 instruction words with 32 register
patterns (5536 cases), including NaNs, infinities, denormals, signed zeros,
conversion limits, deterministic random bits, partial/empty masks, in-place
destinations, and VF0. Module mismatch,
reload, provider switching, code-cache invalidation, and interpreted fallback
checks also pass. All 32 retail records match exactly over 4096 timed slices;
all 5,172,513 upper instructions including the cold pass take the native path.

The first prototype's nine alternating 1024-repeat comparisons had medians
4476.139 ms interpreted / 4164.376 ms native, 6.965% less execution time. After
specializing the exact-result and product-sticky helpers, a new nine-pair batch
has medians 5232.074 ms interpreted / 4632.082 ms native (11.468% less execution
time). Native wins each pair. Every run checks 32,768 timed slices and retains
digest `75d4ff1e67bbbc4c`. Do not compare raw times across these shared-machine
batches as if they were an isolated before/after test.

The flag-specialization batch identities are test executable
`638FF47CFFB05447F12192EFF47A325DA2565505842B3E4EF2CBC29EB8B205DB` and module
`D9C4EFD73DB3FF58A2A00FA0E3D8123A7EA49929C25D9F887A58DF82D4A4CA36`.
The module contains 276 unique kernels and occupies 237,056 bytes. These are
warm-replay results, not game FPS. Scheduling and retirement still use the
interpreter; compiled-block execution remains open.

## Native Game Validation

September 4: the consistent 107-step runner rebuild completed under the unchanged
BelowNormal, four-logical-processor, one-worker, 2048 MiB compiler limits. The
separate `ps2EntryRunner.profile.exe` candidate rejects a relative/missing native
module with exit code 1 before window initialization. Its link retained the
existing `CloseWindow`/`ShowCursor` duplicate-symbol warnings; do not call this a
warning-free build.

Probes 2265 (native) and 2266 (interpreted) used that same candidate, full CPU
rasterization, host-clock pacing, the reversible `TitleGameplayFirst` movie
bypass, fast legal handling, and branch-hook bypass. Both also set
`PS2X_XMEN_START_FIRST_LEVEL=1` and `PS2X_DISABLE_HOST_INPUT=1`. They call the real
New Game handler; they do not directly load a map. No replay capture, phase
profiler, raster profiler, wireframe, or raster-skipping option was enabled.

External present-log observation measured indices 1152 through 1280:

| Mode | Seconds for 128 frames | FPS |
| --- | ---: | ---: |
| Native | 36.7985431 | 3.4784 |
| Interpreted | 38.0110288 | 3.3674 |

These two sequential shared-machine samples are not a deterministic workload or
a sustained-speed guarantee. Both final runtime-owned framebuffers show New York
and Wolverine, with existing black props, missing foliage, and HUD/effect defects.
Different character/effect states are not evidence of pixel-identical rendering.
The small timing difference does not establish practical playability or justify
replacing the saved gameplay executable. Exactness evidence remains the offline
state/memory/GIF replay, not comparisons between separate live screenshots.

`PS2X_RUN_VSYNC_LIMIT=1400` requested a normal stop in both runs; both joined the
game thread and exited with code 0. The guards restored the retail startup
scripts, and no owned runtime/observer/build process remained. Post-join counters:

- Native VU1: 1,550,972,856 native / 233,407,006 interpreted upper instructions
  (86.92% native across the entire run, not just the timed gameplay window).
- Interpreted VU1: 0 native / 1,290,629,286 interpreted. VU0 was 0/0 in both runs.

Candidate SHA-256:
`EA710AE476878943CD20C355A875A15AD7BB2D2EA426195C5975FEAB01CB01B7`.
Matching module SHA-256:
`1B7AFB2D0D4309F15BB63FBD893411A123A8029E4042787613748CD519B74FF8`.
Build fingerprint:
`fe38a2094e8cdf0dce32223b62420cb738135f588cd7c8b0189c51eabdbabc0e`.
Private fixed-slot timing reports are `disc/gameplay-native-rate.json` and
`disc/gameplay-interpreted-rate.json`. Native framebuffer checkpoints are
`probe2265-present1280.png` and `probe2266-present1280.png`; generated-image
retention still expires them after 12 hours.

The primary and staged Probe 2264 executables remain unchanged. Keep this
candidate opt-in. Next, remove per-pair interpretation/scheduling overhead with
compiled blocks in offline replay, preserving exact slice boundaries, pending
results, microcode invalidation, and PATH1 bytes/emission cycles before another
gameplay integration.

## Compiled-Block Recipe

The next-stage recipe exporter performs the same bounded one-cycle cold pass as
upper-kernel discovery, but records a pair only when its PC retires. Dependency
stall retries therefore do not inflate pair execution counts. Set
`PS2X_VU_REPLAY_PAIR_EXPORT` to a private output path while running the recorded
replay test. The writer accepts at most 4096 entries, validates aligned in-range
PCs and nonzero execution counts, and emits exact PC/lower/upper triples. It also
records replay entry PCs and observed retiring-PC successors. It does not emit
register, memory, or GIF payloads. The output is still derived from the retail
microprogram and must not be distributed.

All 32 current gameplay captures contain the same 16 KiB VU1 code image. Their
exact replay identifies 16 entries, 426 executed PCs, 439 edges (26 non-linear),
199 distinct lower words, and the same 105 upper words used by the existing native
recipe. Straight-line paths are partitioned at entries, non-sequential/multiple
edges, missing coverage, and an eight-pair compiler-unit limit. The result is 80
blocks averaging 5.32 pairs, with a maximum of eight. The manifest is 56,202 bytes
in the ignored fixed slot `disc/vu-native-pairs.inc`; it is not tracked. This is
substantially smaller than compiling all 1968 nonzero pairs or all 2048 addresses
in the uploaded image.

Validation after adding pair discovery: focused PS2VU1 suite 54/54; retail replay
32/32 at one measured repeat, 40,803 cycles, digest `75d4ff1e67bbbc4c`.
The replay reported 80,194 interpreted upper executions including its cold pass.
The pair exporter and partitioner alone are diagnostic preparation, not a speed
improvement.

## Native Pair Prototype

The opt-in `PS2X_ENABLE_VU_NATIVE_PAIRS` prototype consumes the ranked unique
pair records in the private recipe. It compiles constant lower and upper bodies
from the interpreter's shared implementations while retaining the interpreter's
hazard checks, pipeline queues, delayed writes, branches, cycle budgets, PATH1
ordering, code-generation invalidation, and unknown-pair fallback. The source
option defaults OFF. The current private build contains 64 replay-ranked pairs
plus three public synthetic pairs; no retail-derived recipe or generated source
is tracked.

The focused PS2VU1 suite passes 55/55. Pair mode disabled and enabled both replay
all 32 gameplay captures exactly at 40,803 cycles for one repeat, including every
register/pipeline field, all VU data, and every emitted GIF byte. Both retain
digest `75d4ff1e67bbbc4c`. The top-64 private set handles 62,982 of 80,194 retired
pairs in the one-repeat run (78.54%).

Nine alternating comparisons at 128 repeats per case retain the same digest.
Interpreter median/mean execution time is 501.040/501.156 ms; native-pair
median/mean is 465.445/468.259 ms. The median reduction is 7.10%, and every
native-pair run is faster than its paired interpreter run. This is an offline
replay gain, not a gameplay FPS result.

An instrumented 2048-repeat native-pair replay shifts the dominant sampled work
outside the specialized instruction bodies: `commitReadyPipelines` is 25.20% of
in-module samples, `run` is 17.07%, `queueVfWrite` is 10.16%, and
`updateFmacFlags` is 8.54%. The next compiled stage should reduce queue and
retirement crossings while preserving exact mid-slice state; merely compiling
more low-frequency pair bodies is unlikely to produce practical gameplay speed.

## Block Retirement Experiments

A generic native-block wrapper remained exact but made the two hottest blocks
18.37% slower in replay. A census of the hottest eight-pair block at PC `0x0B00`
found one scheduler-entry shape in 1,200 observations and no dependency stalls.
Replacing its generic pipeline scan with a fixed retirement schedule also stayed
exact, but a seven-round, 1024-repeat comparison measured 4,206.261 ms for native
pairs and 4,318.020 ms for the scheduled block at the median: 2.657% slower.

A second temporary prototype bypassed the pair wrapper's queue allocation and
committed this block's known early writes directly. Both modes still reproduced
all 32 captures at 40,803 cycles with digest `75d4ff1e67bbbc4c`. In a seven-round,
1024-repeat alternating comparison, native pairs measured 4,020.856 ms and the
direct-state block 4,200.546 ms at the median: 4.469% slower. The game-specific
prototype and its retail-derived words were then removed without a gameplay
probe.

These results reject dispatch-only and retirement-only block wrappers. The next
useful prototype must emit a complete block body, inline its arithmetic, and keep
intermediate vector values in host registers, with exact entry/exit materialization
for pipeline state and slice boundaries. The interpreter remains the fallback for
uncompiled or invalidated paths.

## Direct Whole-Block Prototype

The direct prototype now emits complete constant-word block bodies. It proves
internal VF, ACC, and VI dependencies at compile time, checks live entry hazards
and microcode words at runtime, advances the architectural branch delay slot, and
materializes queued writes and stores at their original cycles. Unsupported words,
changed microcode, pending resources, dependency hazards, and short cycle budgets
fall back before any partial native execution. Blocks can be enabled independently
from the exact-pair provider at runtime.

The current private build selects 16 replay-ranked blocks plus one public synthetic
regression block. The private blocks execute 49,182 of the 80,194 retired pairs in
the one-repeat gameplay capture (61.33%), across 2,682 successful block entries out
of 5,250 attempts. All 32 captures still complete in 40,803 cycles with exact state,
VU memory, GIF bytes, and digest `75d4ff1e67bbbc4c`.

Seven alternating 1024-repeat comparisons used exact-pair mode as the baseline.
Its median was 4,361.182 ms; enabling whole blocks reduced the median to 3,795.386
ms, a 12.973% reduction in replay execution time. Every run retained the expected
digest. This is an offline VU-slice result, not a game FPS measurement.

The public `PS2VU1` suite passes 53/53 and covers vector loads, delayed stores,
integer dependencies, an internal backward loop, branch delay behavior, and
too-small-budget fallback. Enabling the private replay adds one test for 54/54.
No retail-derived words are tracked in the repository; the private recipe remains
in the ignored fixed slot under `disc/`.

Doubling the private selection limit to 32 increased block-contained coverage to
53,170/80,194 retired pairs (66.30%), but it was counterproductive. A direct
seven-round alternating comparison measured 3,259.639 ms for 16 blocks and
3,580.251 ms for 32 blocks at the median, making the larger set 9.836% slower.
Every run remained exact. The active cache was restored to 16, and the temporary
comparison executable and orphaned generated targets were removed.

Constant-destination FMAC flag packing is now specialized in generated native
pairs and blocks while the dynamic interpreter retains the generic path. The
public `PS2VU1` suite passes 53/53, and all 32 gameplay captures retain 40,803
cycles and digest `75d4ff1e67bbbc4c`. A direct seven-round alternating comparison
against the pre-change 16-block binary measured 3,925.071 ms baseline and
3,643.335 ms specialized at the median, a 7.178% reduction. Every run was exact;
this remains an offline VU replay measurement rather than a gameplay FPS result.

Block-entry readiness now expands constant register and lane metadata through an
ordered template fold instead of rebuilding and indexing runtime metadata arrays.
The same live pipeline masks, deadlines, write-slot reservation, cycle budget,
and fallback rules remain in force. Public `PS2VU1` remains 53/53 and the 32
gameplay captures retain the exact cycle count and digest. Seven alternating
1024-repeat comparisons measured 3,266.214 ms for the pre-change binary and
3,167.319 ms for specialized readiness at the median, a 3.028% reduction; the
candidate won six of seven paired rounds. Its test executable grew by about
31 KiB. This is another offline VU replay result, not a gameplay FPS claim.

A direct preassigned-FMAC-flag-slot experiment kept the generic flag scan only
while entry-state flags drained, then retired each known four-cycle-old block
slot directly. It preserved all 32 gameplay captures, 40,803 cycles, and digest
`75d4ff1e67bbbc4c`, but seven alternating 1024-repeat comparisons measured
3,713.223 ms for the accepted build and 3,952.895 ms for the candidate at the
median. The candidate was 6.455% slower, so the change was removed. Play!
reference commit `83700b2c31e593bc94e845b4b31b797be84dda59` remains useful evidence for
precomputed block timing, but this narrow hybrid did not remove enough runtime
bookkeeping to pay for its added branch and state checks.
