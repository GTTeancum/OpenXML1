# Compatibility Heap Investigation

September 6, 2026. Work is local only; no pushes or PRs. Movement was confirmed
by the user on an earlier build; attacking was not tested there. The performance
target remains 30 FPS. No result below is an interactive handoff.

## EFU Fallback Preparation (Current Work)

After the rejected whole-game native-selection result, inspect another sizable
measured gap: long reference fallbacks totaled 36.660 s in the prior budget
profile. This is an upper bound on the relevant opportunity, not measured EFU
time or a promised FPS gain. Short slices remain the larger cost (94.128 s).
Do not resume small native-recipe selection sweeps without new evidence.

Added isolated `play-vu-probe/efu_math.{h,cpp}` with the 13 arithmetic EFU
functions (0x70..0x7d, excluding WAITP), normalized operands/results and result
latencies. `evaluateRuntimeFused` explicitly targets the current runtime's
MSVC AVX2 arithmetic, NOT a hardware oracle. It is not called by the compiled
engine yet; `UnsupportedEfu` remains unchanged. No runtime/gameplay behavior
or compiler instruction support has been enabled by this checkpoint.

The first strict, unfused prototype failed ESADD function 112/component 0/
sample 35: result bits 925022378 versus reference 925022379. Matched-image
disassembly proves multiply/FMA/FMA for squared length, fused Horner polynomials,
and EEXP's reassociated first square. The helper now expresses those operations
explicitly with `std::fma`, compiled `/fp:strict`. Do not relax bitwise checks,
silently change the reference arithmetic, or replace this with `std::atan`.

Validation on test image SHA256
`E38171F5B40C6A82BD4484EBC4043C1A7CB605CDCC28E2E00A9231C654D6211A`:

- 4,056 helper/reference comparisons: all 13 operations, all four components,
  signed zero, denormals, finite limits, infinity/NaN normalization and seeded
  random words. Result bits and final drain cycles match exactly.
- All 13 repeated-producer tests prove issue availability at latency minus one,
  first-result visibility while the second is pending, MFP observing that first
  result, and final P/elapsed cycles matching the second result's deadline.
- All 165 VU tests pass. Fresh saved EFU replay passes 128 repetitions, 519,552
  total cycles, digest `6c07d94c17532259`; compiled commits remain ZERO as expected.
  This preserves fallback, not evidence of accelerated EFU execution.

Fixed logs: `vu-efu-math.log`, `vu-efu-suite.log`, `vu-efu-saved.log` in the
active build tree. Rebuild with `build-below-normal.ps1 -Target ps2x_tests`;
fresh test filter `EFU` selects the new and existing EFU checks. No new build
tree, image, game launch, push or PR. Game candidate remains `8065B73C...`,
the rejected 4.664292-FPS short-recipe experiment; 30 FPS is still unmet.

NEXT implementation requirements before lifting `UnsupportedEfu`:

1. Add an optional compiled EFU hook using the validated helper, preserving the
   original Play path when absent. Keep all staged outputs private until audit.
2. Correct the hook's operand metadata: pinned Play's vector EFU reflection
   uses encoded destination bits instead of the operation's actual source lanes;
   scalar EFU reflection lacks resource synchronization. EATAN (function 0x7c)
   lacks the normal implementation/reflection entry. Never ignore dependencies.
3. Model resource availability and result visibility separately. The existing
   single P counter cannot discard the first result when the next operation
   issues one cycle before it retires. MFP reads committed P without an implicit
   wait; WAITP waits for results. Carry both pending values through that overlap.
4. Preserve dynamic wait aging and transfer timing, including block boundaries
   and branch delay slots. The existing guarded Q-wait partition/aging path is
   a useful pattern, not a proof that substituting P is sufficient.
5. Validate public producer/wait/read/dependency/branch cases and the private
   saved failure plus full recordings before a game audit or FPS candidate.

## Short-Slice Native Selection (Previous Experiment)

The existing native block executor already preserves pending pipeline state
within a 64-cycle slice. The old weighted recipe executes zero blocks in the
16 short records from the current gameplay capture. Before changing the JIT
state contract, regenerate the bounded native selection from that workload.
This is code-word-validated acceleration, not a PC-only substitution or a
larger VIF service budget. The limits remain 64 private pairs / 16 private
blocks; public kernels remain included. No additional build tree is needed.

`export-short-vu-kernels.ps1` selects budgets <=64 from the bounded private
recording, validates those records through reference replay and exports the
existing native recipe format. Never publish recordings or generated recipes.
The reproducible output is 16 cases, 965 cycles, digest `2d4d4a5da3b943f3`.

- Source SHA256: `CBAE282147204131268441035DF5EA4F2D91AD32FF2A06F15C89AB4FC0FEC7C9`.
- Short recording: `0859EA8666882CD6188AE3037E639ED80EFB13947A7FB601762B4A67B3289AEC`.
- Recipe: `8EADCDC42103829E9951BD501F22B74CD704AB49C8ABFE8A270490E8DBFDEF4F`.
- New test image: `A6BB9ADFECB9C98C6A84D0AE3FEDCEE6995903571D451B1199FBC130CBB87BD4`.
- Prior test baseline: `97538CDF3DA3C3DBE8912A5E06086E1DF6370F219CB0B2A272065BB5F26B8FF9`.
- Candidate: `8065B73C93F2D36C5A6D1914D5ADAB52C642C450E6F56571EFA10B3D2561B111`.

All 163 VU tests and eight complete recordings at full/1/8/16/64-cycle budgets
pass (40 replay checks). Seven alternating comparisons of 2,048 repetitions
each give baseline/candidate medians 179.642/113.898 ms, 36.60% lower, 7/7 wins.
Digest matches; candidate executes 1,419,957 native block pairs including the
cold pass. This is an isolated workload result, NOT a game FPS measurement.
`compare-vu-blocks.ps1 -AllowUncoveredBaseline` explicitly allows zero baseline
block execution but still requires its counter and nonzero candidate execution.
Its focused regression and the gameplay reporting gate tests pass.

Local configuration (configure and build are separate operations):

```powershell
./xmen-legends/export-short-vu-kernels.ps1
./xmen-legends/build-below-normal.ps1 -ConfigureCache 'PS2X_VU_NATIVE_PAIRS_FILE:FILEPATH=C:/Programming/GitHub/OpenXML1/xmen-legends/disc/vu-native-pairs-short.inc'
./xmen-legends/build-below-normal.ps1 -Target ps2x_tests
./xmen-legends/build-below-normal.ps1 -LinkOnly -OutputName ps2EntryRunner.candidate
```

The previous recipe is `disc/vu-native-pairs-weighted.inc`. Keep the new choice
experimental until whole-game evidence supports it. The old profile executable
still contains the previous recipe and can run with profiling disabled for a
bounded comparison. Do not overwrite protected runtime slots for extra backups.

Whole-game result: **REJECTED for performance promotion**. Candidate `8065B73C...`
completes in 193.669247 seconds, exit 0, vsync limit reached, zero logged heap/
guest faults. The same 128-presentation window takes 27.442533 seconds,
**4.664292 FPS**, versus the earlier weighted recipe's 5.443341 FPS. These are
shared-host observations, not a controlled regression percentage, but there is
no demonstrated gameplay improvement. Native block coverage rises to 118,479,343
pairs; greater coverage alone is not a win. Compiled calls >=258,049, retries
>=77,825 and retained-cache hits >=576,594 verify the expected execution paths.
No profilers, audit, input or screenshots were enabled. Startup is restored and
the owned game is closed. All changes remain local; no handoff or goal completion.

NEXT: broader exact short-slice acceleration needs whole-workload attribution,
not more selection sweeps on this tiny corpus. Determine native block overhead
versus remaining reference execution before changing the partial-state bridge;
never widen 64-cycle service budgets. The short recipe remains experimental in
the active build cache, not the accepted default. The profile slot retains the
old recipe for comparisons without rebuilding. Temporary comparator executable
was removed (7,993,856 bytes), along with 208 regenerated Debug directories
(about 6 MiB); no new build trees or screenshots. Fixed logs use
`vu-short-*` and `gameplay-vulkan-rate-retry-cache-realloc.*` in the active tree.

## Remaining Execution Cost (Previous Profile)

Candidate `117EFB10...` completes the cached phase profile in 186.829 seconds,
and the combined phase/bridge profile in 189.566 seconds. Both have zero logged
heap/guest faults, restore startup and close their owned process. They are
diagnostics, not FPS measurements. In the combined run, the busy thread's 165
windows at ticks 566..1396 total 171,194.435 ms: VU exclusive 117,708.091 ms,
GS 17,358.420 ms, guest 19,031.973 ms, transfers 11,468.270 ms. Thus VU still
accounts for about 69%, but the old 96% breakdown is superseded.

Whole-run bridge totals: execute 20.525770 s / 631,173 calls; commit 13.997934 s
/ 488,590 calls; export 1.357072 s; copy 0.681458 s; import 0.397747 s; capture
0.335319 s / 992,454 attempts; scalar import 0.041144 s. Commit includes graphics
publication; these stage totals must NOT be added to overlapping phase times.
Copy/conversion is too small to explain the missing performance. Successful
compiled drains also do not account for most VU time. Investigate interpreter
fallback and short slices rather than repeating arithmetic-helper micro-tuning.

`-BridgeProfile` now exposes the existing runtime timer, requires all seven
stages, preserves totals in JSON and explicitly excludes FPS. `-BudgetProfile`
adds opt-in VU1-only short / long-reference / long-compiled elapsed totals and
the top eight entry PCs for each of the two noncompiled classes. A successful
retry includes its interpreted prefix in long-compiled time. Timings include
nested graphics work. The output is capped at 19 lines per active thread;
storage is fixed at 2 x 2,048 hotspot entries. Disabled mode emits nothing.
All 163 VU tests pass with budget profiling enabled (test SHA256
`97538CDF3DA3C3DBE8912A5E06086E1DF6370F219CB0B2A272065BB5F26B8FF9`); the current recording
matches digest `e941ad49d2248a18` with profiling off/on. Benchmark gates pass.
The candidate is unchanged; only the diagnostic slot was linked, SHA256
`0C9343406288BC57425CC1242CE90C0BB86C6218F1F250CCA174F79703633F65`.
The live budget profile completes at 227.854 seconds with zero logged heap/
guest faults. The user observed about 4 FPS during this DIAGNOSTIC run; do not
claim that instrumentation alone explains the difference from the earlier
5.44334 FPS candidate result. No new performance candidate was packaged.

Measured VU1 inclusive totals:

| Path | Calls | Seconds |
| --- | ---: | ---: |
| Short (budget <= 64) | 12,566,378 | 94.128147 |
| Long, reference fallback | 232,692 | 36.659568 |
| Long, compiled success (including retry prefixes) | 528,316 | 41.104551 |

Short slices dominate VU1 time, about 55% of its 171.892266-second inclusive
total. Top short entry PCs: 0x80 (799,619 calls / 6.188478 s), 0x230 (162,652 /
2.528774 s), 0x1788 (232,841 / 2.101593 s), 0x13d8 (203,164 / 1.928585 s).
Top long-reference entries: 0x3278 (3,480 / 1.244446 s), 0x5b8 (3,532 /
1.237617 s), 0x1a58 (3,516 / 1.226119 s). No single entry dominates, and PC
histograms aggregate different microcode images; never specialize by PC alone.
Full bounded hotspots and totals are in the fixed
`gameplay-vulkan-rate-retry-cache-budget-profile-realloc.{err.log,json}`.
The owned process closed and all startup entries were restored. Runtime
profiling changes are checkpointed locally as `553350a`.

NEXT PRIORITY: extend accelerated execution to the normal 64-cycle slices,
preserving exact suspension/resumption and pending pipeline/transfer state.
`ps2_runtime.cpp` deliberately issues MSCAL and nondraining service at 64 cycles;
`ps2_vu1_core.cpp` only attempts compiled drains for budgets above 64. Do NOT
replace the service budget with a full drain: VIF can change data between slices.
Investigate bounded compiled blocks and full pending-state export/import against
the existing VUR1 snapshots and 1/8/16/64-cycle replay tests. Full-drain-only
optimizations, broad kernel-count increases, and copying micro-tuning cannot
address most of this measured cost. Long fallback is the secondary target.
No screenshots, input, handoff, push or PR. Goal remains unmet.

The latest private recording executes zero existing AOT block recipes in its
native replay (`vu-current-native.log`: 134,919 attempts, zero executed). This
is a coverage gap, not proof that adding recipes would be faster. Earlier
32-block and residual-selection experiments were slower; preserve their
lessons. Current capture cases 23 and 31 contain ELENG at 0x1d68/0x20e0/0x2820,
EATAN at 0x3660/0x36b8 and ERCPR at 0x39a0/0x3a68. These are static code-image
observations, not evidence that every listed instruction executed.

## Retained Compiled Blocks

The current healthy-heap candidate's phase profile attributes 123,594.776 ms
of 128,468.865 ms to VU exclusive time on its busy thread across 89 windows,
ticks 558..634 (96.206%). This is not a GPU bottleneck measurement or FPS.
A bounded earlier capture now records canonical reference results starting
at an optional tick, preserving the original 16-short/16-long quotas and
4 MiB limit. `-CaptureVu -CaptureVuStartTick 550 -RuntimeVariant Profile`
completed at 225.989 seconds with no logged heap/guest faults. The private
`disc/vu-gameplay-current.bin` is 1,915,688 bytes, SHA256
`CBAE282147204131268441035DF5EA4F2D91AD32FF2A06F15C89AB4FC0FEC7C9`.
It has eight distinct microcode images and 32 cases, ticks 550..613. Reference,
native and compiled/retry replay agree on digest `e941ad49d2248a18`.

The opt-in `PS2X_VU_RETAIN_BLOCK_CACHE=1` / benchmark `-RetainVuCache` keeps
content-addressed Play blocks while unlinking active blocks on code changes
and unsupported EFU fallback. Defaults remain unchanged. Each session is
bounded to 2,048 blocks / 8 MiB generated code; exceeding either discards the
private attempt, clears the cache and uses reference fallback. Generated code
bytes exclude allocator/page overhead, so this is not a process RAM cap.
The first synthetic run exposed uninitialized lookup storage; constructor
initialization fixes it before range invalidation can occur.

Standalone `F45A493282A39C8E2B96ADCE8E1702CD5FD07D8FFC164E49B1FA060107296696`
passes all public checks. Across 256 alternating programs, retained/discarded
compilation counts are 9/512, 503 hits, with exact state/data/packet/timing
agreement; capacity rejection and subsequent recovery also pass. Synthetic
164.057/5.055 ms timings are not game FPS. All 163 VU tests pass with cache
off and on; eight recordings pass full/1/8/16/64-cycle replay (40 checks).
Runtime test SHA256:
`39639BBE1BA34814D9984E60CE7FF6B5F2F85C7112B2DBA78C87D05D9FBF415F`.
Logs: `vu-cache-{0,1}-tests.log`, `vu-cache-replays.log` in the active build.
The existing candidate slot now contains performance candidate SHA256
`117EFB1091AE41CB653CBD28AB3CCFA0F16E3FACE4E0166E22523D3E19EB8190`.
Runtime capture changes are checkpointed locally as `8b3e64d`.
The 300-second cache audit is INCOMPLETE, not a pass: it reached presentation
1152 at 260.454 seconds, with at least 258,049 compiled calls, 73,729 retries
and 549,355 cache hits, no logged heap/guest/compiled mismatch. The cache cleared
once for capacity, then stabilized around 1,173 blocks / 2,570,624 code bytes
at the last bounded statistics report. Audit FPS remains null.

The same candidate's unaudited cache run completes the full workload at
192.502 seconds, zero logged heap/guest faults. Presentations 1152 and 1280
arrive at 151.734187 and 175.249157 seconds: 128 / 23.514970 = **5.44334 FPS**.
This is shared-host approximate presentation timing, not an acceptable result
or proof of playability. It remains in the rejected single-digit range. The
older healthy-heap no-cache run did not finish the workload at 300 seconds;
this establishes better completion, NOT a same-image percentage FPS gain.
Both owned game processes closed and startup was restored. No input, screenshots,
interactive handoff, push or PR. Logs and JSON use the fixed stems
`gameplay-vulkan-{audit,rate}-retry-cache-realloc` in the active build.

NEXT: measure CURRENT cached execution with existing `-PhaseProfile -CompiledVu
-CompiledRetry -RetainVuCache -VulkanGs -InPlaceRealloc`, without rebuilding.
The previous 96% VU attribution predates cache reuse and must not be treated
as the new breakdown. If VU still dominates, separate compiled execution,
bridge conversion and reference fallback costs; existing bridge stage profiling
is in `play-vu-probe/bridge_profile.h`. Keep the cache opt-in until a complete
live audit. Do not send another single-digit candidate for interactive testing.

## Integer Load Retirement (19:44 UTC)

The tick-542 timing failure is fixed offline. ILW at PC `0x598` issues at
relative cycle 102; its four-cycle writeback must retire at 106 even though
the E-bit delay slot ends at 105. The compiled engine now records actual
ILW/ILWR retirement deadlines and includes them in its existing drain/budget
check. It excludes VI0 sinks and I-bit immediates. This is not a blanket extra
cycle and does not implement general cross-block VI hazard tracking.

Runtime test image `5119F04858CD0E9E4040503BC0817D54D28E5D648A808D1F2A627D99CBFD3EE2`
passes all 163 VU tests, including 84 load/end/branch/sink/immediate combinations.
Seven recordings pass full, 1-cycle and 64-cycle hybrid/retry replay (21 checks).
Reference, native and compiled versions of the saved failure all agree on
106 cycles and digest `0cfab35f3f93ce6f`. Fixed logs: `vu-load-*.log` in the
active build. An initial suite run from the wrong working directory failed
the source-enum inspection; rerunning from PS2Recomp passes the entire suite.

Standalone image `0645D379850172C04B33C8306052EF16262195F705AA04DD0B15709EE36B1CEA`
passes public checks and exact recorded architecture/memory/packet validation.
Its direct-versus-detached test also needed equal execution budgets; the prior
raw offset-12 mismatch was quota bookkeeping, not different arithmetic. CMake
now explicitly labels the register-test assembly as ASM_MASM so regeneration
does not silently omit it from the target. Optional traces remain bounded.

The private failure is retained as `disc/vu-lsu-tail-failure.bin` (58,560 bytes,
SHA `22FA0FF341D073B68F2C33CD756AE2403075C195A3EE91E81E7C5DA9DA8F8C20`).
Combined candidate `EC87DC7FD3AA9EC4CF5FAD3C49454CA189EB4C92B448C1B8966167628AE0D9EC`
hit the 600-second limit in the heap-gated compiled audit. At least 147,457
compiled calls and 24,577 retries passed before shutdown, with zero logged
allocation failures or guest/compiled faults. This is an INCOMPLETE audit,
not a full workload pass. The latest presentation marker was index 512 at
tick 531; higher call counts alone cannot establish matching gameplay progress
against earlier candidates. Startup was restored and the owned process closed.
The stale JSON from the previous candidate was removed after verifying its
old hash; current text logs belong to `EC87DC7F...`.

The benchmark now writes a fresh unverified running summary and records
timeouts/errors as incomplete with FPS null, preserving detailed reports
already written by ordinary workload-gate failures. Synthetic stale-summary
and preserved-report tests pass with all existing benchmark gates. The same
candidate also times out at 300.0145 seconds without audit/heap diagnostics:
86,017 compiled calls, 12,289 retries, zero logged heap or guest faults, New
Game and NYC package confirmed. Latest present is 640 at tick 677 (3,584,722
Vulkan submits). Thus it advances beyond the old failure, but does not reach
the 1152..1280 timing window. The new JSON correctly says Incomplete/FPS null.
Both owned game processes closed and restored startup; no controls handoff.

A process-only observation at 214.7 seconds showed 236.9 total CPU seconds;
the dominant thread later had 223.3 CPU seconds. This points to an occupied
CPU thread, not sufficient evidence to blame machine-wide contention. NEXT:
profile the CURRENT healthy-heap candidate using `-PhaseProfile -CompiledVu
-CompiledRetry -VulkanGs -InPlaceRealloc`, bounded, without another rebuild.
Use per-thread exclusive phase costs from the slow interval; do not reuse old
percentages from different heap/guest workloads or call this an FPS sample.
Phase reports emit every second; detailed VU sampling only starts at tick 1000
and will need an explicitly scoped earlier window if detailed data is needed.
The 30 FPS goal remains unmet. All changes remain local; no image or interactive
input was used. Runtime trace-only checkpoint: `285af18`.

## Allocation Replay And VU Blocker (19:20 UTC)

Local runtime commit `ccb3f60` repairs three sources of fragmentation: split
remainders keep their address order, a freed frontier is joined to untouched
space BEFORE advancing the bump pointer (not only at exhaustion), and alignment
gaps are returned to the free list. The arena boundary is unchanged. In-place
realloc is still opt-in; no FPS or full-level success is claimed.

Opt-in `PS2X_GUEST_HEAP_TRACE` records allocation/free/in-place-resize/failure
events under the heap mutex. The file has a 32-byte versioned header and 32-byte
records, capped at 262,144 events (8 MiB plus header/footer). It closes on the
first failure; the parser rejects truncated, capped and missing-footer traces.
It stores addresses/sizes/call origins, not memory contents or images. The
benchmark's `-HeapTrace` requires `-HeapDiagnostics` and is explicitly excluded
from FPS. `replay-heap-trace.py` checks bounds, alignment, overlap, free ownership
and resize ownership, then replays the captured lifetimes under separate models.
Alternative placements cannot predict guest control flow beyond that prefix.

The first trace, from candidate `5AD96907...`, has 143,269 events, 53,360 live
allocations, 13,806,696 requested / 14,116,480 padded bytes. The `runtime` model
matches EVERY recorded allocation address and the 32 KiB failure exactly.
Ordered splitting alone still leaves fragmentation; joining the frontier early
preserves 1,552,544 bytes of untouched tail after the failed request in replay.
This motivated the actual changes, not a speculative policy sweep.

That first trace is retained in `gameplay-heap-baseline.zip` (566,629 bytes),
containing a 4,584,672-byte `gameplay-heap-trace.bin`, SHA256
`A295ED6F977D8D4E60F293599A6550D4948F1AF5EA627AAD50D34A2086D15EF2`.
The second trace remains in the fixed `gameplay-heap-trace.bin`: 5,128,480 bytes,
SHA256 `56B32BAA4117D0F8C1F4651E27E1670DC90E2FBFFCD3ECC0325F2F214917E3A1`.
It comes from candidate `64DE1281...` after ordered splitting/frontier reuse,
before alignment-gap recovery. Its 160,263 events match `runtime-frontier-first`
with zero address differences and the later 298,384-byte failure exactly:
60,117 live; 14,941,553 requested / 15,285,088 padded bytes; peak padded
15,513,968. The largest unowned gap is 298,080, just below the request; the
runtime's largest tracked free extent is only 135,552. Recovering alignment
gaps in replay satisfies that request without enlarging the arena.

Reproduce the second proof:

```powershell
python xmen-legends/replay-heap-trace.py PS2Recomp/out/xmen-final3-build/gameplay-heap-trace.bin --expect-model runtime-frontier-first
```

Current test image
`D8864E50774DC7AD10D65D28DC2ED99E5883C5A02E20914FA302893C41B56BC6`
passes 59 fresh-process checks with diagnostics/trace and 59 without (118 total),
plus eight recorded ownership replays, 12 Python replay tests and benchmark
gate tests. The fixed heap-check log holds the last diagnostics-OFF run; ON
results were also observed. New regressions cover free-list split ordering,
frontier reuse before exhaustion and alignment-gap ownership.

Current game candidate:
`51C7B4CBC54DF1130662AAA4803D4B6BD6BDB93064A7F9175D5080AD3C7A3A1E`.
Its latest in-place/compiled-retry/Vulkan audit reports NO heap failure before
stopping on `[vu:compiled-audit-failed] accepted=29899 tick=542 pc=0x580
cycle=117875042`. This is a DIFFERENT blocker, not a healthy workload/FPS pass.
It does not prove no later heap failures exist. Four automated game runs this
turn total, all closed and startup restored. No input or images were captured.

The new private VU recording is `disc/vu-compiled-failure.bin`, 58,560 bytes,
SHA256 `22FA0FF341D073B68F2C33CD756AE2403075C195A3EE91E81E7C5DA9DA8F8C20`.
Fresh-process runtime replay at one repeat proves reference and native-pair
execution both pass (106 cycles, digest `0cfab35f3f93ce6f`). Compiled replay fails:
first differing state word `117875147/117875148`, state offset 625, data=1,
gifs=1. The reported first difference is one final cycle; do not assume all
remaining state fields match until enumerated. Standalone Play probe
`93F1B470...` also fails detached-versus-direct comparison for this recording.

NEXT: fix the saved compiled VU timing disagreement before another game run.
Use `MINITEST_FILTER=recorded VU slices reproduce`, `PS2X_VU_REPLAY_FILE` pointing
to this recording, `PS2X_VU_REPLAY_REPEATS=1`; compiled reproduction additionally
sets `PS2X_VU_REPLAY_COMPILED`, `PS2X_VU_COMPILED_RETRY`, `PS2X_VU_REPLAY_PAIRS`
and `PS2X_VU_REPLAY_BLOCKS` to 1. Keep the saved case until it is fixed. Then
complete the full audit and only afterward measure FPS. 30 FPS remains unmet,
movement remains user-confirmed on the earlier build, attacking untested there.

## Command Recording And Tail Join (18:51 UTC)

Local runtime commit `8520160` adds a bounded active call chain (maximum 12
entries, entry a0/a1 captured before nested calls) and repairs contiguous-space
handling. If the ordinary free-list and bump routes cannot satisfy a request,
the allocator can now join a free block ending exactly at the frontier with
the untouched tail. It preserves alignment prefixes, tracks the full requested
size, clears the returned storage and never crosses `0x01800000`. This is not
a heap expansion or a new placement-policy switch. Existing successful routes
are unchanged; the new route is reached only before an otherwise failed request.

Test image `E5A6FAAABDA1B315D7F23243A1A4F7AD1260422FA716A5B213D321D1D9089FCD`
passes 35 fresh-process checks both with and without diagnostics (70 total).
The new case requires a 256-byte-aligned allocation larger than either adjacent
free range, checks neighboring live data and the native boundary, reuses the
alignment prefix, and still rejects an oversized remaining request. Nested
failure attribution is asserted in normal/fast dispatch modes. Benchmark gate
tests also pass. The fixed heap test log currently holds diagnostics OFF;
the preceding ON run passed in terminal output.

Before the join fix, diagnostic candidate
`FE9F7F7BE004BC2D2BD162525676E95F01472AF1268A0E7D465211C06AC41EED`
confirmed this active chain at the original failure:

```text
0x2b9484 -> 0x2b7b60
0x2b7c60 -> 0x2744b0
0x274510 -> 0x273a80
0x273aec -> 0x2dd120
0x2dd20c -> 0x248040  a0=0x8000 a1=12
0x248068 -> 0x231ed0  a0=0x898ef0 a1=0x8000
```

This proves command-list initialization, not the `0x2dd510` growth site.
Retail `0x2dd2a0` finalizes the list: at `0x2dd440..0x2dd450` it computes
used bytes (end minus buffer base) and reallocates through `0x248090`; it
repairs the previous link when the buffer moves. `0x2ddc00` recursively
releases list buffers through `0x248080` (tail jump to public free `0x200f40`).
Category-12 singleton `0x7472a0` is assigned by `0x20caf0`, called from
`0x273ab4/0x273b78` when renderer field `+0x3ac` is nonzero. A matching release
routine exists; this is NOT proof that all live buffers are leaks.

Current candidate
`5EA2B9EE6EDEECE2B4D463968C61C4776346960F6E1C439B38DF8CC790828A85`
still fails a 32 KiB initialization after joining available tail space:
frontier 25,164,752; tail 1,072; free 1,582,080; largest hole 32,560;
live allocations 53,360 (previously 53,331). This fixes a real capacity defect,
but only advances allocation slightly; it does not resolve fragmentation.
The bounded runner stopped on failure, drained 12 failure lines, and restored
startup. New Game/NYC were reached; zero guest faults/compiled mismatches were
reported before the stop. Neither the complete arithmetic audit nor gameplay
workload passed, and no FPS is reported. Two automated runs this turn total,
no input or images, all owned processes ended. Current fixed in-place audit
logs contain this last candidate, not the earlier candidates described below.

NEXT: inspect the command-list allocate/shrink/release lifetimes and actual
ownership of native versus compatibility pools. A bounded allocation-event
trace suitable for offline replay could distinguish placement waste from live
memory pressure without repeated full-game policy probes. Do not enlarge the
arena, compact live guest objects, or skip failures without ownership evidence.
The default moving-realloc failure is not retested by this in-place run.
30 FPS and healthy first-level gameplay remain unmet; main VU execution cost
still needs substantial work once a valid workload can be measured.

## Failure Attribution (18:30 UTC)

Runtime and test changes are checkpointed locally in PS2Recomp commit `b4c0043`.

`PS2X_GUEST_BUMP_DIAGNOSTICS` now records the active dispatch source/target and
registers on the first allocation failure, plus up to 16 live requested-size
groups ranked by total bytes. The existing 16-failure cap remains. Context is
thread-local and restored on nested dispatch return/unwind; normal mode emits
neither these records nor builds the size histogram. This is diagnostic work,
not a claimed optimization. Its disabled-mode timing cost has not been measured.

`tests/test-compatibility-heap.ps1` passes 27 fresh-process checks both normally
and with `-Diagnostics` (54 total), including an exhausted-heap dispatch that
must retain the old allocation and identify source `0x800000`, target `0x200e10`.
Output bounds and disabled-mode silence are checked. Test image:
`A5EEE997A40B2BE0F20F79B41C1129303EFEC3AFDCA9796D9FDBFD32C9C18C9C`.
The fixed `heap-ownership-checks.log` currently contains the diagnostics-on run;
the preceding off run passed in terminal output.

Candidate `66BB7F1592362DFF83095180001AB14E2B3CF12E1C0E15D56C228C3FA310E429`
was used for one automated first-fit/in-place/compiled-retry/Vulkan run, with
heap diagnostics and compiled arithmetic auditing. It reproduces the previous
32,768-byte failure exactly: frontier 25,151,296; tail 14,528; free 1,590,224;
largest hole 32,560; live allocations 53,331. Caller record:

```text
source=0x248068 target=0x231ed0 ra=0x248070 sp=0x1f12550
a0=0x898ef0 a1=0x8000 a2=0x10 a3=0 s0=0x8000 s1=0
```

Retail `0x248040` takes a size in a0 and allocator category in a1, resolves the
allocator through `0x247fc0`, then calls aligned-allocation slot `0xd8` with
alignment 16 at `0x248068`. The two explicit fixed-32-KiB callers found in static
disassembly are `0x2dd20c` and `0x2dd510`, both passing category 12. Their routines
set up/grow command buffers using globals `0x750700..0x750710`, 32,752-byte end
offsets and linked packet storage. This identifies a command-buffer path to
investigate, but the immediate caller report alone does NOT distinguish those
two sites from other callers computing a 32-KiB size dynamically.

Category 12 at `0x247fc0` first checks allocator singleton `0x7472a0`, then falls
back to `0x747298`, `0x20c960`, and `0x203b60`. Investigate whether the original
allocator separation/lifetimes are lost when all wrappers allocate from one
compatibility arena; do not assume all those native arenas are free or expand
into them without ownership proof.

Largest observed live-size groups by requested bytes:

| Requested size | Live count | Total bytes |
| ---: | ---: | ---: |
| 16,384 | 48 | 786,432 |
| 32,895 | 20 | 657,900 |
| 479,220 | 1 | 479,220 |
| 32,768 | 13 | 425,984 |
| 6,112 | 65 | 397,280 |
| 8,192 | 47 | 385,024 |
| 44 | 7,773 | 342,012 |
| 1,024 | 326 | 333,824 |

These are requested-size totals, not padded occupancy or ownership/lifetime
attribution. Full 16-group output is in the reused
`gameplay-vulkan-audit-retry-realloc-heap-audit.err.log`. New Game/NYC and public
free execution are confirmed; 16 queued failure records were drained after the
intentional stop, exit -1, elapsed 19.15 seconds. No guest fault or compiled
mismatch before stopping, but neither the audit nor gameplay span completes.
No valid FPS, native image or interactive handoff. Startup restored; all owned
build/test/game processes ended. Allocator experiments remain opt-in.

NEXT: confirm the command-buffer caller and inspect the category-12 allocator's
ownership/lifetime boundary. Do not change placement policy again on this data
alone. The 298,384-byte singleton failure in default moving mode remains open,
as does the primary 30 FPS objective and substantial VU execution work.

## Ownership Dispatch Checkpoint (18:20 UTC)

Retail ELF program-header mapping was used to read the table at `0x6fcbe0`:
slots `0xd4/0xe4/0xe8/0x104/0x14c/0x150/0x1b4` contain
`0x231eb0/0x232020/0x232040/0x2336f0/0x233800/0x233710/0x233ed0`.
Disassembly confirms:

- Public free `0x200f40` and aliases `0x200f90/0x201080` query owner lookup
  `0x203f90` before calling slot `0x104`; `0x201090` follows the same owner path
  through `0x200fe0`. Host-tracked buffers must be released before that lookup.
- `0x2151b0` forwards a1 to the allocator's free slot, while `0x2336f0` forwards
  it to shared slot `0x1b4` with a2 set to **-1** (`0x2336f4`).
- Shared implementation `0x233ed0` branches on that sentinel at `0x234034..38`.
  Its prior compatibility hook incorrectly freed any owned a1, regardless of
  a2. Positive sizes now resize; only -1 selects its release path. The existing
  helper's zero-size policy is retained, not claimed as exact retail semantics.
- The unaligned public realloc entry `0x200e10` also queries native ownership;
  it now handles known compatibility blocks like the existing aligned entries.

All seven public/inner free entry points use host ownership only for exact tracked
addresses. Unknown pointers continue to the guest implementation. Direct/indirect
calls and tail jumps preserve their respective continuations. Two formerly
diagnostic-only addresses (`0x2151b0`, `0x2336f0`) were removed from the optimized
dispatcher's exclusion list because they now perform cleanup.

The new dispatch regression also caught a macro-precedence bug: passing
`virtualCall ? 5 : 4` to `GPR_U32` makes its unparenthesized register-zero test
return zero on virtual calls. The allocator now uses `getRegU32` for that choice,
as does the new public-free argument selection. No global macro/header rewrite.

Final test image `AE058BCADED7913DC9EE78EDC9D0C9186714CCFB3530BF1E626DECEEA7198284`
passes all **27 fresh-process checks** through `tests/test-compatibility-heap.ps1`:
three allocator tests across normal/fast dispatch, first/best fit, and moving/
in-place realloc, plus three existing normal-heap checks. Dispatch coverage
includes 28 owned free branch/entry combinations, seven foreign-pointer cases,
both allocation calling conventions, positive shared-slot resize and -1 release.
Initial tests caught the new macro call-site error and fast-path exclusions;
they were corrected before the final passing matrix. An initial test compilation
also needed the existing register accessor instead of a macro with `&ctx`.
Fixed evidence: `heap-ownership-checks.log`. Benchmark gates pass.

Candidate `4B16C52B0D89740B92912F5F9527B2051537B4DA24F7EAB6A0559AB3404F7B5A`
contains the ownership fixes, with both allocator experiments OFF by default.
Two first-fit real-level runs (compiled VU + retry, Vulkan, heap diagnostics,
compiled audit) reach New Game/NYC but still stop on allocation failure:

| Realloc mode | Failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Moving (default) | 298,384 | 4 | 24,997,888 | 167,936 | 253,264 | 108,912 | 60,113 |
| In-place (opt-in) | 32,768 | 16 | 25,151,296 | 14,528 | 1,590,224 | 32,560 | 53,331 |

The moving run records at least 40,961 public releases / 2,892,100 cumulative
requested bytes; the in-place run records 36,865 / 2,591,600. These counters prove
the new path executes. They are NOT simultaneous extra headroom or proof that
every one of those releases previously leaked; some native paths can reach the
already existing compatibility free hook. Neither run completes its audit or
produces valid FPS. Nine/sixteen queued allocation failures were drained after
intentional termination, exit -1; no guest fault or arithmetic mismatch was
reported before the stops. Elapsed 30.91/16.09 seconds is not an FPS result.

Current logs reuse `gameplay-vulkan-audit-retry-heap-audit.*` and
`gameplay-vulkan-audit-retry-realloc-heap-audit.*`; their prior-candidate contents
are replaced. Historical numbers below are recorded observations, not claims
that those fixed paths still hold the historical run. No new image or input.
Both game processes ended and startup was restored.

NEXT: obtain the exact caller of the failed 32 KiB request and allocation-lifetime
attribution at failure. Static inspection identified additional real dispatch
bugs, but has not identified that caller. Add bounded call attribution with the
next meaningful runtime change, rather than rotating placement policies. The
native heap boundary remains protected, the full FPS objective is unmet, and
there is no interactive handoff. All source changes remain local.

Local PS2Recomp checkpoint: `cfaf3af`. Cleanup found no additional stale files;
active candidate/test images and fixed evidence were retained. No owned build,
game or test process remains running.

## Reallocation Checkpoint (18:04 UTC)

Three compatibility realloc routes now use a shared owned-allocation helper.
The inner wrappers and null realloc slot previously freed the original block
even if allocating its replacement failed. Failure now retains that block and
its contents. Zero-size owned realloc frees it and returns zero; foreign guest
allocations retain their existing copy-only path and are not freed by this heap.

`PS2X_GUEST_BUMP_REALLOC` enables in-place shrinking, growth within existing
padding, and growth into an adjacent free extent. It is OFF by default. Fallback
still allocates/copies/frees on success. No live objects are compacted, no arena
boundary changes, and no guest call is bypassed. In-place growth clears newly
exposed bytes; shrinking returns the unused padded tail to the coalesced free
list. The benchmark's `-InPlaceRealloc` switch requires actual in-place execution
evidence, not just an enabled flag.

Test image `D094FC539746064CD17ABA51A8B01A139426020014C97FF388A8308BC73E3CE7`
passes eight fresh-process runs: realloc and fragmentation tests under all four
combinations of first/best fit and moving/in-place realloc. These cover retained
data, cleared extension, requested size, null/zero size, adjacent extent splitting,
out-of-memory/overflow ownership preservation and foreign-address rejection.
Three existing normal guest-heap, memalign and allocator-stub checks also pass.
Evidence: fixed `heap-realloc-checks.log`. Benchmark gate tests pass.

Candidate `FAAD524CF88FB7917A3BA58B0C99EA41C4C658CC68A19705DE5C94709B1E6427`
was linked in the existing slot, with the corrected New Game trigger unchanged.
Both bounded runs enable compiled VU + retry, Vulkan, realloc, heap diagnostics
and the compiled arithmetic audit. Both reach New Game and NYC, then stop on
allocation failure. Neither completes the audit or provides valid FPS:

| Policy with in-place realloc | First failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| First-fit | 32,768 | 16 | 25,154,768 | 11,056 | 1,525,552 | 32,560 | 53,641 |
| Best-fit | 32,768 | 16 | 25,153,824 | 12,000 | 1,485,872 | 32,560 | 53,543 |

Each run drained 16 queued failure records after the runner requested termination.
Exit -1 is that deliberate diagnostic stop. No guest fault or VU mismatch was
reported before stopping; this is not a full audit pass. Elapsed times 20.04 and
20.24 seconds are time to failure, not performance improvements. Relative to
the previous candidates there is more fragmented free space, but different
failure points prevent a like-for-like memory-saving claim. Neither experimental
policy is promoted. No new image or interactive handoff was made, and startup
was restored after both runs.

Local PS2Recomp commit: `4cf8284`. All owned builds and tests ended. Cleanup
removed one stale generated file and retained the active binaries/evidence.
No push or PR was made.

Fixed evidence: `gameplay-vulkan-audit-retry-realloc-heap-audit.*` and
`gameplay-vulkan-audit-retry-best-fit-realloc-heap-audit.*`. Next: identify the
ownership/call path of these 32 KiB requests and the lifetime of the live blocks;
do not keep rotating placement policies or expand into the native custom heap.
The remaining sections record the preceding investigations, not newer results.

## Observed Pressure

Candidate `7F5AE058415EFEB2812512F708DE7B2E85F8801E9556BB06E360E6F5AA298408`
was examined with read-only process memory access. No input, capture app,
breakpoints, memory writes or desktop automation was used. Its PDB is stale and
the candidate contains no matching CodeView record. Actual allocator machine
code, rather than that PDB, identifies the observed RVAs:

- allocator body `0x25bf0..0x25eed`;
- bump frontier `0x9cf3830`;
- free-vector header `0xb100c20`;
- allocation-map header `0xb0ff220`.

`observe-gameplay-heap.ps1` requires that exact executable path, SHA-256 and
instruction signature. It rejects later candidates. Reads are unsuspended,
so concurrent changes can invalidate samples; range checks and repeated
container-header reads do not constitute an atomic heap snapshot.

After level loading the observed frontier is **25,047,040**, leaving **118,784
bytes** before the arena limit. The largest observed free block is **109,056
bytes**; about 249,000-250,000 bytes in total are free across 23-24 blocks. The repeatedly
failed singleton request needs **298,384 bytes** (`0x48d90`) contiguously.
Neither the tail nor any observed free block can satisfy it. The arena must
not simply be enlarged into the separate custom game heap at `0x01800000`.

An allocation-list read validates 60,428 entries totaling 14,989,587 requested
bytes, or 15,334,640 bytes after the allocator's 16-byte size rounding. This
accounts for most of the arena; it is not proof that every allocation remains
semantically needed. The initial wrapper returned exit 1 after completing this
list because its five-second observation interval had elapsed before a separate
heap sample. The list data was retained, but that run is not described as a
successful complete observer run. The wrapper now distinguishes a validated
allocation list from a timed heap sample and bounds list traversal too.

Fixed private artifacts: `gameplay-heap-observation.json`,
`gameplay-heap-allocations.json`, and `gameplay-vulkan-retry-failure.*`.
The observed game repeat completed without a guest fault and reported 5.849623
FPS, but the observer overlapped it; do not present that as a controlled speed
comparison. The earlier fault remains unresolved by this successful repeat.

## Allocation Policy Experiment

`PS2X_GUEST_BUMP_BEST_FIT` is OFF by default. It chooses the smallest free block
that fits the request after alignment, preserving larger holes for larger
requests. The arena bounds, requested-size tracking, clearing, alignment,
splitting and free/coalescing behavior remain unchanged. It does not move live
objects or bypass failed guest calls. The first allocation emits positive
activation evidence. `PS2X_GUEST_BUMP_DIAGNOSTICS` separately enables at most
16 failure records with requested size and available-space information.

Test image `EB9D792A575CC8EC97D3363AF06BE405E88D47A6E3E2712D8D9BF562404B521F`
passes both fresh-process policy checks. In the synthetic fragmented arena,
first-fit consumes part of the large hole for a small request and cannot later
satisfy 327,680 bytes; best-fit uses the small hole and succeeds. Size tracking,
alignment, clearing and frees pass. This is a synthetic policy result, not proof
that the real first level has enough memory. See `heap-policy-checks.log`.

The benchmark now requires best-fit activation when requested, rejects observed
allocation failures, and excludes heap diagnostics from FPS reporting. Its gate
tests pass. A diagnostic run with no failure records alone cannot prove heap
health outside the exercised workload.

## Bootstrap Address Bug

First candidate with the allocator experiment:
`F086C87397144F059CBE6331CFA4DBF9FE6313180B05CE82ACCB2CCE86F7DBC4`.
It reached the bounded frame limit without an allocation-failure record or
guest fault, but **never started New Game or loaded NYC**. Its workload is
rejected, and its title-screen timing is not gameplay FPS.

The generated first-level test trigger hard-coded the level manager's former
heap address, `0x00b1a220`. Different allocation placement invalidates that
assumption. Retail getter `0x3246e0` instead reads the singleton at `0x764288`
and constructs it through `0x31d7d0`. The trigger now reads that singleton,
bounds-checks both pointer dereferences and retains its existing title-state
and 30-frame conditions. No manual-control behavior or game-level selection is
changed. The tracked `generated-first-level-probe.patch` reverse-checks cleanly
against the current generated source, including the function-table entry.

## Corrected First-Level Checks

Corrected candidate:
`E5C379F437D560B7358BE1A94469E30B15C890BC152BDB480919BDE61E8604C1`.
Both policies now reach the real New Game handler and NYC package. Both are
rejected on explicit allocation failures. The runner deliberately terminates
its owned game on the first observed failure record, drains queued output and
restores startup. Exit -1 here is that diagnostic stop, not a new host crash.

| Policy | First failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Best-fit | 66,720 | 4 | 25,124,864 | 40,960 | 113,712 | 64,352 | 57,649 |
| Original first-fit | 298,384 | 4 | 25,047,040 | 118,784 | 250,320 | 109,056 | 60,419 |

The first-fit failure matches the earlier read-only observation and the null
singleton's allocation size. Best-fit fails on an earlier, different request;
it is **not promoted**, and remains opt-in for comparison only. The title-only
run did not establish its suitability for gameplay. Both corrected runs had
compiled VU auditing enabled, with no mismatch reported before the allocation
stop, but neither completes the audit or yields valid FPS. No new framebuffer
was written: the best-fit run requested present 1280 but stopped before it.
Do not mistake the previously retained frame for evidence from this candidate.

Fixed evidence is in `gameplay-vulkan-audit-retry-best-fit-heap-audit.*` and
`gameplay-vulkan-audit-retry-heap-audit.*`. Original first-fit logs nine queued
failure records before termination; the first is the table entry above.

NEXT: investigate allocation ownership/lifetimes and the division between the
compatibility arena and the original custom heap. The current live allocation
inventory accounts for nearly all the compatibility arena; changing free-list
placement alone did not make the first level healthy. Do not enlarge the arena
across the custom-heap boundary without proving ownership, compact live guest
objects, bypass null dispatches, or count a run with allocation failures as a
complete gameplay validation. After memory health is established, finish the
compiled audit and resume substantial FPS work. The last clean control rate is
still 5.724173 FPS, not an acceptable interactive handoff.

Local PS2Recomp checkpoint: `92e3b7a`. Benchmark gates and observer syntax /
wrong-process rejection checks pass. Cleanup removed four stale generated files.
All owned builds, observers and game tests ended. No push, PR or new image.
