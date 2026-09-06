# Isolated Play! VU Compiler Probe

This builds only the VU compiler, its supporting stream code, and the 21 existing
VU test cases from [Play!](https://github.com/jpd002/Play-), plus isolated contract
tests and an optional private VU-recording diagnostic. It does not link to
PS2Recomp, read the ISO, create a game window, or enable a replacement engine.
There is no gameplay FPS claim or interactive handoff yet.

## Sources

The ignored `.tools/Play-VU` checkout is pinned by CMake to these revisions,
with the required local CodeGen and memory-observer patches described below:

| Repository | Revision |
| --- | --- |
| Play! | `83700b2c31e593bc94e845b4b31b797be84dda59` |
| CodeGen | `a5009f7dca062695b8e5aebbd71e67b4ddfa9251` |
| Framework | `587f278917acc0026bf5fc34b39f995fc26bd015` |
| Dependencies | `8a5f6b1dea0b888b5a42b821e79470142bbea4e3` |
| xxHash | `e626a72bc2321cd320e953a0ccf1584cad60f363` |

Only Framework, CodeGen, Dependencies, and Dependencies/xxHash are initialized.
Keep the existing checkout; do not create parallel clones or build variants.
The complete reference plus this Release build occupies approximately 70 MiB.

Play!, CodeGen, and Framework retain their BSD-2-Clause `License.txt` files.
xxHash retains its upstream licensing, and `FpAddTruncate.cpp` retains its embedded
LLVM/compiler-rt attribution. The x64 CodeGen prolog/epilog and Play!'s optional
VU memory observer are patched. Their notices are also retained in
`CODEGEN-LICENSE.txt` and `PLAY-LICENSE.txt`. Preserve all relevant upstream
notices if these components are distributed.

## Build And Run

From the OpenXML1 root, apply the patch once to the pinned CodeGen checkout:

```powershell
$patch = (Resolve-Path xmen-legends/play-vu-probe/codegen-win64-simd.patch).Path
git -C .tools/Play-VU/deps/CodeGen apply --check $patch
git -C .tools/Play-VU/deps/CodeGen apply $patch
$observerPatch = (Resolve-Path xmen-legends/play-vu-probe/play-vu-memory-observer.patch).Path
git -C .tools/Play-VU apply --check $observerPatch
git -C .tools/Play-VU apply $observerPatch
```

CMake refuses configuration if either patch is absent. A reverse `--check`
confirms an already-applied patch; do not apply twice or reset unrelated edits.
Configure once with MSVC x64 and MASM. Lower the configuring shell's
priority before launching CMake, so compiler-identification children inherit it:

```powershell
$self = [Diagnostics.Process]::GetCurrentProcess()
$self.PriorityClass = 'BelowNormal'
$self.ProcessorAffinity = [IntPtr]0xF
cmake -S xmen-legends/play-vu-probe -B .tools/Play-VU/out/vu-probe -G 'Visual Studio 17 2022' -A x64
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_vu_probe
& ./xmen-legends/play-vu-probe/test.ps1
```

The normal build wrapper retains one worker and a 2048 MiB compiler limit. Tests
run without a console window at Normal priority on four logical processors.

## Verified Contracts

The test runner prints the executable SHA-256 for each invocation. Recorded
comparison identities below refer to the binaries actually measured.

- All 21 unmodified upstream test cases pass, including arithmetic, flags,
  branch delays, stalls, and mixed division/EFU behavior. This is not a claim of
  compatibility with every PS2Recomp replay or X-Men microprogram.
- A 66-pair NOP/end program runs all 66 pipeline cycles for each executor quota
  of 1, 2, 8, and 64. Remaining quotas are -131, -130, -124, and -68: this API
  charges instruction words at block boundaries, not exact elapsed VU cycles.
- XGKICK reports a qword address. Its callback runs after the following lower
  instruction: a following SQ has already changed the memory visible to it.
  The callback still sees `pipeTime=0`, while the completed four-pair program
  ends with `pipeTime=4`. The callback therefore does not supply an exact event
  timestamp suitable for PS2Recomp's streaming PATH1 transfer implementation.

These are characterization assertions of the pinned engine, not assertions that
its interface already satisfies PS2Recomp's scheduling requirements. Do not
replace `VU1Interpreter::resume` with `CVuExecutor::Execute` or copy only registers
while discarding pending writes, flags, or active graphics transfers.
The upstream test environment also selects round-toward-zero and flushes
denormals. Any in-process bridge must preserve and restore the caller's floating
point environment instead of changing EE, audio, or other host calculations.

## Windows ABI Regression

The pinned CodeGen uses XMM6-XMM15 without preserving their Windows nonvolatile
values. A public, synthetic twelve-vector addition program reproduces corruption
of all ten registers while its arithmetic output remains correct. This explains
why the 21 upstream VU tests alone did not detect the integration hazard.

`win64_register_test.asm` seeds and records these registers while preserving its
own caller, including unwind metadata. The regression fails without the patch
(`xmm-corrupt-mask=0x3ff`, exit 6) and passes with it (`0x0`). The patch reserves
160 stack bytes on Windows, moves local/spill offsets accordingly, and saves and
restores all ten registers. System V code generation is unchanged. All 21 VU
tests, budget checks and the XGKICK contract still pass. The unpatched diagnostic
produced invalid floating-point timing output; discard that timing completely.

## Private Replay Diagnostic

```powershell
& ./xmen-legends/play-vu-probe/test.ps1 -ReplayPath xmen-legends/disc/vu-replay.bin
```

The recordings are ignored, private artifacts and must not be distributed.
The bounded VUR1 reader accepts only the known inactive-PATH1 state layout with
no pending stores, VI/ACC writes, scalar operations, or branches. Pending VF
results and supported flag components up to three cycles away can now be imported.
Queue masks, entry validity, per-lane latest-write ownership and readiness must
agree. Fourteen of the original 32 records now qualify; this is not full coverage.

Case 19 reaches the same E-bit termination PC. ACC, Q/P/I/R, all integer
registers and all but one vector word match. There are 28 differing memory bytes
in 27 words and one differing byte in the 16 same-sized, ordered GIF packets.
The vector mismatch is one ULP. The arithmetic cause is not yet proven; both
engines already use round-toward-zero. Play! also omits initial STATUS bits
`0xb00`; flag mirrors need explicit pipeline retirement. Its instruction pipeline
reports 2420 cycles; the new transfer observer accounts for the last five cycles
and matches all packet completion times in this case. Arbitrary short-slice
timing and pipeline-state equivalence remain unverified. The diagnostic prints
`accepted=0`; exit zero means it ran, not that compatibility passed.

After the ABI fix, 256 warm runs reproduce the cold run's entire MIPS state,
memory and packet output. Three sequential comparisons at Normal priority on
four logical processors measured the following case-19 executor totals:

| Round | Current PS2Recomp (ms) | Patched Play! diagnostic (ms) |
| --- | ---: | ---: |
| 1 | 23.621 | 3.417799 |
| 2 | 32.560 | 3.829699 |
| 3 | 23.489 | 3.458299 |

The baseline test image was `572A59384879D900A6ECB8864457E52475464875350F668D0EFA198181A1FF93`;
the diagnostic image was `C9F27D92EE46D8F69A68B5E3CF82E4224FFC86A6296DA7BD1AC83AE521850590`.
Baseline replay passed all 32 records with digest `75d4ff1e67bbbc4c` in each run.
Median isolated time is about 6.8x lower, but the workloads are not yet semantically
equivalent: the diagnostic lacks correct scheduling/streaming and omits flag
behavior. Import, compilation and final comparisons are outside the timer;
packet-copy callbacks are inside. This is feasibility evidence, not an accepted
optimization or a gameplay FPS claim. A real bridge and broader workloads still
need measurement, and drawing remains a separate major cost.

## Transfer Observer

`play-vu-memory-observer.patch` adds an optional callback set before compiling
VU blocks. With no observer, no event calls are emitted. Once blocks have been
compiled, do not change observer presence without resetting the executor/cache.
Observed blocks cannot share generated functions across different addresses,
because each event embeds its instruction PC. Same-address block caching remains.
The callback receives PC, absolute VU pipeline time and one of four phases:
before a store (0), store commit at issue+1 (1), XGKICK issue (2), block end (3).
The existing delayed XGKICK callback and guest instruction execution are unchanged.

Store detection uses the pinned engine's instruction reflection for SQ, SQI,
SQD, ISW and ISWR, and excludes lower words used as upper I-bit immediates.
The observer does not modify guest state. Uninstrumented special nested-branch
and conditional E-bit delay-slot emission paths reject observer compilation
rather than silently omitting memory events. They still need implementation.

The diagnostic PATH1 timeline reads one qword every two cycles, starting one
cycle after XGKICK. It advances before stores, after commits and at block ends,
and drains remaining bytes after E-bit termination. It does not mutate guest
memory. Without the separate pre-issue wait hook described below, overlapping
transfers remain errors. Backward events, oversized packets and unterminated
chains are errors, not skipped work.
Callbacks catch errors inside the generated-code boundary and report failure
after execution. This is not yet a scheduler or a production bridge.

Eight compiled regressions verify preservation of an already-read GIF tag,
visibility of an early payload write, rejection of a late payload overwrite,
transfer completion after program end, VU-memory wraparound, linked-block timing,
exclusion of I-bit immediate words, and correct event PCs when the same code
is compiled at another address. The initial linked-block test failed
because the test executed before the assembler destructor resolved its labels;
the fixture was corrected without changing its expected transfer time.

In case 19, all 16 recorded packet completion times now match exactly. The
timeline finishes at 2425, accounting for the five-cycle final transfer tail.
The same single byte still differs: packet 14, offset `0x68`, the depth word of
a packed XYZF2 vertex. It is not texture or color data. The numeric cause remains
unproven. The run emits 942 observer events; final state, memory, streaming packets
and completion times repeat across 256 warm executions.

Three further sequential comparisons include the new observer and transfer
drain inside the timer (both engines at Normal priority/four logical processors):

| Round | Current PS2Recomp (ms) | Play! with transfer observer (ms) |
| --- | ---: | ---: |
| 1 | 25.036 | 6.215799 |
| 2 | 31.819 | 6.443599 |
| 3 | 26.854 | 6.556299 |

The baseline remains `572A5938...`; observer image:
`3E6A02EA33E6C3848C5CA9C872E18E437AF955A92ED474204C157098A53795F0`.
Baseline passes all 32 records, unchanged digest. About 4.2x lower median time
for this isolated case remains feasibility evidence, not a gameplay FPS gain.
Both old snapshot callbacks and new streaming reads execute in this diagnostic.
The earlier 6.8x figure excludes the observer and must not describe this version.

The eight transfer tests, 21 upstream VU tests, ABI regression, budget/XGKICK
contracts and private diagnostic also pass after adding rejection of unsupported
special delay-slot paths. No game binary was built or launched, and no images
were created during this work.
Transfer-observer checkpoint image:
`29709F90A6668746389D6CF033E97854B9791C978A6A433B3F9AF6C535B15489`.

## Pending-State Import Checkpoint

Pending VF values are placed in Play!'s early-result representation, with per-lane
FMAC masks delaying their use. Older overlapping writes cannot overwrite a lane's
newest result. Supported MAC, sticky Z/S, sticky reset and CLIP events enter the
flag pipelines at their recorded relative deadlines. Unsupported STATUS bits
remain unresolved. This representation is not an architectural snapshot suitable
for returning control to EE/VIF between short slices.

A public synthetic regression checks overlapping partial VF writes, a three-cycle
dependent-read delay, flag retirement at each deadline, sticky reset, and rejection
of inconsistent masks, out-of-range deadlines and VF0 writes. It passes alongside
the eight transfer tests, 21 upstream tests, ABI and budget/XGKICK contracts.

Final test image: `63D79D7DB0D7431E8489E29CA4CFA00B114888AF02454EE4493540F348A74745`.
The original capture now runs records 1/2/3/4/6/8/10/11/12/14/15/16/18/19,
matching all recorded packet completion times and reproducing each cold result
over 256 warm executions. Arithmetic, memory and packet-byte differences remain;
the summary explicitly reports `eligible=14 accepted=0`.

At this checkpoint, the spread capture ran records 5/9/12/17, then failed at
record 19: overlapping XGKICK at PC 6496, cycle 64 required a VU stall. The
following checkpoint resolves that failure, not the remaining arithmetic and
short-slice limitations.

## Pre-Issue Transfer Wait

The same reproducible Play! patch now adds optional `m_vuXgkickWait`, installed
before compilation. It returns elapsed wait cycles without modifying VU state.
Generated blocks call it before an XGKICK pair, advance pipeline time, and age
incoming FMAC hazard masks by the elapsed wait. Pending arithmetic can therefore
finish during the transfer wait without charging the same delay twice.

The opt-in executor partitions before XGKICK, or before a branch whose delay slot
contains XGKICK. The latter retains branch execution before the wait and currently
requires a NOP upper instruction on the branch pair. Other delay-slot forms reject
compilation rather than applying an incorrect wait. Short blocks carry unretired
incoming FMAC masks into their successors. Address-dependent generated code cannot
be reused at another address. Changing either callback's presence requires a
cache/executor reset. With neither callback installed, ordinary upstream tests
use the original execution path, apart from a bounds guard for one-pair blocks.

Seven compiled synthetic tests pass: consecutive transfers, an arithmetic result
partly retired during a wait, a dependent read after the wait, new arithmetic
issued after a long wait, incoming hazards carried through a short block, and
branch-delay transfers with and without a dependent upper instruction. They run
with the existing eight transfer tests, pending-import regression, ABI check,
21 unmodified upstream tests and budget/XGKICK contracts.

Verified image: `1B56D4693EF2EF5697C54384F313002FA5150AE8E01297911E2B733280BF7D0C`.
Both private diagnostics now complete: original 14/32 eligible, spread 8/32
eligible (5/9/12/17/19/21/23/29). All packet completion times match and all warm
runs reproduce cold output. Previously failing spread case 19 finishes its last
transfer at cycle 627 with nine packets; two packet bytes still differ. Spread
case 21 has identical packet bytes, while case 9 retains 78 differing packet
bytes and case 29 has 35. Both diagnostics still report `accepted=0`.

No game binary was built or launched. The wait-enabled path has no controlled
speed comparison yet; neither earlier speedup figure establishes its performance.
Do not promote it into gameplay on the basis of transfer timing alone.

## Idle Scalar Import Fix

A cold memory-write comparison identified a state-import bug, not a Play!
arithmetic bug: Q/P architectural values were copied but their idle pipeline's
held values remained zero. Play! republishes the held value on a read or WAIT,
even with no outstanding scalar operation. Import now initializes both mirrors
and held values, with zero remaining latency. Pending scalar operations are still
rejected by the importer.

A public synthetic test reads imported Q through MULq and executes WAITQ/WAITP.
Before the fix, all three results became zero (image `60CEF076...`, exit 8).
After the fix, VF2.x/Q remain 0.5, P remains 0.25, and the program takes four
cycles. All prior public tests and both private diagnostics still run successfully
on image `6E00516C8DD628CA03954A621328F11F0B9931B8883F2B820B094585A75CA681`.

Spread case 9's first divergent vertex write at PC `0x2b88`, cycle 7, offset
`0x27d0` now matches the baseline instead of writing zero for its third component.
Its packet-byte differences fall from 78 to 59, and final memory-byte differences
from 176 to 153. Case 29 falls from 35 to 16 packet-byte differences and now has
32 differing memory bytes. All 22 eligible records still match transfer completion
times. Numeric/state differences remain; `accepted=0` is unchanged.

For a bounded cold-only memory trace:

```powershell
& ./xmen-legends/play-vu-probe/test.ps1 -ReplayPath xmen-legends/disc/vu-replay-spread.bin -MemoryTraceCase 9
```

Only changed 16-byte memory rows are printed, capped at 4096 rows per selected
case. This uses the optional store observer; trace work is disabled before warm
repetitions. Matching baseline tracing is documented in `../VU-REPLAY.md`.
Private trace logs stay ignored and reuse two small fixed files, not new captures.

Next: bridge exact short-cycle budgets and validate architectural results,
memory writes, and packet ordering against the existing private recordings before
measuring throughput. Those recordings contain mid-program state, not fresh VU
entry snapshots, so importing their visible registers alone is invalid.

No game executable should be linked or packaged until the larger performance
change has measured benefit. The title/FPS counter stays queued for that build.
