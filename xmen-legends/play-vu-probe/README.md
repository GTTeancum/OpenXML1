# Isolated Play! VU Compiler Probe

This builds only the VU compiler, its supporting stream code, and the 21 existing
VU test cases from [Play!](https://github.com/jpd002/Play-), plus isolated contract
tests and an optional private VU-recording diagnostic. A typed bridge uses the
PS2Recomp state header. The standalone probe does not read the ISO or create a
game window; the optional runtime extension below now connects it to the game.
Bounded first-level timing is recorded below. The user subsequently confirmed
movement on the performance candidate, but rejected its roughly 5 FPS; combat
was not tested in that session. See the current TODO before launching anything.

## EFU Compatibility Preparation

`efu_math.cpp` implements all 13 EFU arithmetic functions against the current
runtime's fused MSVC AVX2 behavior, with explicit normalization and result
latencies. `/fp:strict` plus explicit `std::fma` preserves the verified operation
order. This is a compatibility helper, not a hardware-accuracy claim.
All 4,056 differential numerical/latency cases and 13 overlapping-producer/MFP
timing cases pass; the full runtime suite now has 165 passing VU tests.

The helper is NOT wired into `CompiledVuSession`. Its EFU rejection remains
unchanged, and the saved real-game EFU case still makes zero compiled commits
while matching replay digest `6c07d94c17532259`. Do not remove the guard yet:
operand metadata, missing EATAN support, overlapping pending P values, dynamic
wait aging and graphics timing still need integration and exact validation.
See `../HEAP-CHECKPOINT.md` for the ordered prerequisites and current build hash.
No new gameplay executable, launch, or FPS result accompanies this preparation.

## Short-Slice Native Selection

The current experiment feeds the existing canonical-state native block engine
with the short slices of the latest private gameplay recording, rather than
extending the compiled drain bridge to unsupported partial states. Private
limits remain 64 pairs and 16 blocks. `../export-short-vu-kernels.ps1` reproduces
and validates the private recipe; do not commit its generated game data.
All 163 VU tests and 40 recording/budget checks pass. Seven alternating replay
rounds improve median short-record time 36.60%, with exact matching results;
this is not a gameplay FPS claim. Build identities, commands and live results
are recorded in `../HEAP-CHECKPOINT.md`.
The whole-game candidate subsequently measures **4.664292 FPS**, with no logged
heap/guest faults, versus the previous 5.443341 FPS observation. No demonstrated
gameplay gain: do not promote this recipe or present it as a playable handoff.

## Retained Block Cache

Current bottleneck (September 6): the bounded budget profile measures 94.128 s
in 12.6 million short VU1 slices, versus 36.660 s long fallback and 41.105 s
successful compiled runs (inclusive times). The compiled drain path excludes
budgets through 64 cycles. Extending exact short-slice acceleration is now the
priority; increasing the VIF service budget would change program behavior.
`run-gameplay-benchmark.ps1 -BudgetProfile` reports these categories and bounded
hotspots; `-BridgeProfile` reports the seven existing conversion/execution stages.
Both are explicitly excluded from FPS results. No new playable-build claim.

`PS2X_VU_RETAIN_BLOCK_CACHE=1` opts into content-addressed compiled block reuse
across microcode changes and unsupported EFU fallback. Active links are removed
before a new program is installed. The default still discards cached programs.
Each session caps retained blocks at 2,048 and generated code at 8 MiB; a capacity
rejection publishes no partial output and returns to the reference engine.
This byte count excludes host allocation overhead. Constructor initialization,
alternating programs, branch relinking, EFU recovery and capacity recovery are
covered by the public detached-session tests. Runtime benchmark flag:
`-CompiledVu -CompiledRetry -RetainVuCache`.

All 163 VU tests pass with cache off/on, and eight private recordings pass at
full/1/8/16/64-cycle slices. The synthetic switch test reduces compilations from
512 to 9 across 256 changes; this is not a live FPS claim. The combined candidate
completes the fixed game workload at **5.44334 FPS**, still unacceptable. Its
300-second compiled audit reaches presentation 1152 without a logged mismatch
but remains incomplete. Keep cache retention opt-in and do not treat this as
an interactive handoff. Current evidence is in `../HEAP-CHECKPOINT.md`.

## Bounded Compiled Retry

September 6, 19:44 UTC: the saved tick-542 failure is fixed. An ILW issued at
relative cycle 102 must retire at 106, one cycle after the E-bit delay slot.
Compiled execution now carries the actual ILW/ILWR retirement deadline into
the drain/budget check, excluding VI0 sinks and I-bit immediates. All 163 VU
tests pass, including 84 new load/end/branch combinations; seven recordings
pass at full/1/64-cycle slices. Reference/native/compiled replay all agree on
106 cycles and digest `0cfab35f3f93ce6f`. The retained private regression is
`disc/vu-lsu-tail-failure.bin`, SHA256
`22FA0FF341D073B68F2C33CD756AE2403075C195A3EE91E81E7C5DA9DA8F8C20`.
Standalone validation passes too, after correcting unequal direct/detached
test budgets and explicitly assigning ASM_MASM to the ABI test source.
Candidate `EC87DC7F...` times out after 600 seconds of combined audit and
300 seconds without audit/heap diagnostics, with no logged heap/guest faults.
The normal run reaches present 640/tick 677, beyond the old failure, but not
the timing window. No full audit or new FPS pass. Next profile this current
candidate's busy CPU thread, not older heap-broken workloads. Timeout reports
now overwrite stale summaries with an explicit incomplete result and FPS null.
See the [checkpoint](../HEAP-CHECKPOINT.md) for full identities and evidence.
General cross-block VI hazard tracking
is not introduced by this load-retirement fix.
Historical successful-audit claims below predate the allocation-failure gates
and must not be used as evidence that current level loading is healthy.

September 6: `PS2X_VU_COMPILED_RETRY=1` enables one additional compiled-drain
attempt after at least eight cycles of normal VU1 execution. It is OFF by
default and requires compiled mode. The remaining budget must still exceed
64 cycles. VU0, short slices, stopped programs and ended programs do not retry.
Prefix instructions, pending operations and packets are actually executed, not
discarded or approximated. Successful publication retains the existing typed
state validation; the caller's rounding mode is restored on the early return.

Profiling identified expensive recordings rejected at entry, before any private
compiled execution. State conversion/copying was much smaller than execution.
The prefix allows pending-entry work to retire and makes those recordings
eligible without extending the typed ABI to every pending pipeline shape.
Compiled coverage rises from 14 to 16 of the 32 original cases, and from 8 to
15 of the 32 spread cases. Short-slice cases still use the original engine.

Final test image:
`7AE3D3C9E7B73D9E23D7367DC60457C1BCA1BFC76911948EA7CCD5C6AFD95983`.
All 162 VU tests pass, including 28 new boundary combinations for pending DIV,
XGKICK, branches and E-bit termination across 1/64/65/72/73/128/4096 budgets.
They compare architecture, elapsed cycles, all 16 KiB data, packet counts,
bounded attempts and caller rounding. Both complete recordings retain their
state/memory/timed-packet checks and digests. Eight short-slice replay runs at
1/8/16/64 cycles and the four saved EFU/entry-wait/Q-call/FTOI failures pass.
Fixed evidence: `vu-retry-checks.log` and `vu-retry-regressions.log`.

Five alternating same-image ON/OFF pairs per recording, 1,024 warm repeats:

| Recording | OFF ms (rounds 0..4) | ON ms (rounds 0..4) | Median paired reduction |
| --- | --- | --- | --- |
| Original | 1081.007, 1179.441, 1149.195, 1234.479, 1185.652 | 787.838, 838.092, 644.721, 868.300, 722.351 | 29.66% |
| Spread | 767.919, 775.679, 679.052, 780.846, 673.937 | 484.182, 477.495, 472.206, 491.112, 548.733 | 36.95% |

Every pair improved in this shared-host experiment. These are replay execution
times, NOT whole-game FPS or a guaranteed sustained speedup. The fixed
`vu-retry-comparison.json` records all identities and rounds. All work is local.

### Game Validation: Not Promoted

Combined Vulkan/retry candidate:
`7F5AE058415EFEB2812512F708DE7B2E85F8801E9556BB06E360E6F5AA298408`.
The full first-level compiled audit passes: at least 258,049 compiled calls,
110,593 accepted retries, zero mismatches or logged guest faults, present 1280
and the 1400-vsync limit. Audit timing is deliberately excluded from FPS.

The uninstrumented retry run FAILS before the measurement window: guest PC
`0xa3a310`, RA `0x396e84`, `s0=s1=a0=v0=0`. Host exit 0 and the eventual vsync
limit do not make this a successful game run. Fixed private evidence is retained
in `gameplay-vulkan-retry-failure.{err.log,out.log,json}`. No retry gameplay FPS
or stability gain is claimed, and the option remains disabled by default.

Same-executable Vulkan control with retry disabled completes at
2026-09-06 17:04 UTC: all workload gates, zero logged guest faults,
128 presents / 22.361309 seconds = **5.724173 FPS**. This is an approximate
shared-host baseline, not a measured retry speedup or an acceptable handoff.
Both benchmarks and the audit close their owned processes and restore startup.
Input was disabled; movement remains user-confirmed only on the earlier build,
attacking untested there. No new image, interactive input, push or PR.

Disassembly narrows the fault investigation: `0x396dfc` obtains the singleton
from `0x38cfd0`; the latter requests `0x48d90` bytes through `0x14cae0` and stores
the result at `0x79a980`. The fault snapshot has a null singleton in `s1`.
`0x396e2c` obtains a pool slot through `0x396c40`; `0x307a70` and `0x398630`
both simply return their second argument, so neither repairs a null pool slot.
The subsequent virtual dispatches dereference that result. The logs contain
16 rejected null-page memsets of size `0x48d90` in BOTH the successful audit
and failed retry run; that marker alone does not distinguish them. Next trace
the allocator result and singleton/pool state at these boundaries, including
why the fault path is reached only in some runs. Do not bypass null dispatch,
assume heap exhaustion, or dismiss the retry's possible contribution because
earlier candidates failed nearby. The original Vulkan failure is still retained.

The candidate also assembles each black-present diagnostic into one stderr
write, addressing the previously observed activation-marker interleaving.
This is a logging correction, not a rendering change or a general atomicity
claim for all diagnostics. Benchmark gates require positive retry execution
and keep audits and guest-fault runs out of FPS reports.

### Bridge Diagnostics

`PS2X_VU_BRIDGE_PROFILE=1` adds per-thread, opt-in capture/copy/import/scalar-
import/execute/export/commit timings, emitted at thread teardown. Rejections
and cold execution are included; these are not warm-only or whole-runtime
totals, and they exclude ordinary fallback execution. No per-instruction timer
is added. Disabled mode produces no bridge profile records.

The initial profiling image `97BB6360...` passes both recordings with profiling
ON and OFF. At 512 repeats, measured execute stages total 273.5004 / 194.0928 ms
(original/spread); capture 2.2478 / 2.3632, copy 6.2811 / 4.1337, import
2.4409 / 2.1768, scalar import 0.3301 / 0.2234, export 12.6075 / 10.5244,
commit 11.1031 / 7.4421. Those stage logs retain their original executable hash.

```powershell
& ./xmen-legends/run-vu-bridge-profile.ps1 -Capture Original -Profile
& ./xmen-legends/run-vu-bridge-profile.ps1 -Capture Spread -Retry
& ./xmen-legends/run-vu-bridge-profile.ps1 -Capture Spread
```

The runner uses hidden, bounded test processes at Normal/0xF, clears inherited
PS2X settings, requires 32 cases and the known recording digest, verifies the
executable identity, and reuses fixed logs. It does not launch the game or
capture images. Build only tests through the BelowNormal wrapper for this stage.

## Direct Arithmetic Experiment

September 6: `PS2X_VU_DIRECT_FMAC` enables an experimental JIT emitter for
ADD/SUB/MUL only. It remains OFF by default and is not in the game candidate.
The emitter handles vector/broadcast/Q/I operands, masks, aliases, VF0 sinks
and accumulator destinations. Signed zeros and bounded operands use direct
packed arithmetic; all other values retain the existing helper. Queued flags
and sticky status are preserved. MADD/MSUB and cross-product operations keep
their original helpers, including the runtime's fused arithmetic semantics.

Standalone image
`93F1B4708FE1CAE2A11E5AA9EAE0517F14B42255069B5D367A3B6B0B6A05ABB2`
passes 60,480 complete-state comparisons: 25,531 execute without calling the
helper and 34,949 exercise the fallback. A mixed direct/helper session also
verifies dependent arithmetic and a subsequent memory store. The existing
149,760 scalar/vector comparisons and 21 upstream tests pass.

Runtime test image
`D61A3F6D7955B446664608D5125CBB3EFABD3560AAFD31D20195A6FBC2E22D92`
passes 161 VU tests with the emitter enabled, both original recordings at
full/1/8/16/64-cycle budgets, and four saved failure records. Replay digests
remain unchanged. Full-drain hybrid acceptance remains 14/8 cases; short
budgets and the EFU record retain the original engine. Fixed
`vu-direct-checks.log` records those checks.

Five alternating same-binary, 1,024-repeat ON/OFF pairs did NOT establish a
useful performance gain. Original-recording execution was slower in four of
five pairs (median paired time change +9.77%); spread was faster in four of
five (-3.38%). Absolute times shifted sharply during the run: original OFF
samples ranged 673.647..1348.453 ms and spread OFF 468.552..863.141 ms. This
shared-host timing variation makes aggregate medians unreliable; these are
neither stable speedup estimates nor gameplay FPS. The fixed
`vu-direct-comparison.log` retains all rounds. No game was built or launched.

Keep this as a disabled, correctness-tested experiment, not a performance
promotion. Before extending it, inspect generated branch/flag overhead and
whether checks can be amortized across a compiled block. Do not repeat the
same per-instruction experiment or substitute unfused MADD. The CPU renderer
also remains a mandatory performance target: its measured cost alone exceeds
the complete 30 FPS frame budget. All checkpoints remain local, with no PR.

## Arithmetic Cost Checkpoint

September 6 offline investigation: a matched-map sample of test image
`63AA8AB341D24E9F36A2FCDF1ADFEE0E74D034AA4253A18D6CA71C66DE0EBD5A`
on the original recording covered 145 warm execution samples, 26 outside the
image (17 unresolved), zero sampling failures/drops. Individual compiled FMAC
helpers, interpreter execution and memory-observation callbacks all appeared.
This is directional evidence, not an exact whole-game cost breakdown. The map
has since been rebuilt; do not attribute that old log through the current map.

A guarded helper experiment avoided widened flag arithmetic for bounded normal
operands, with the exact path retained for edge cases. It matched 149,760
scalar/vector cases and both full private replay sets. Its isolated arithmetic
loop improved 67.010 -> 52.750 ms with identical checksum `01ad7e00`, but this
did not translate into useful replay gains. The first version was 8.5% slower
on the original recording and 1.0% slower on spread. Allowing exact zero results
for the fused model reduced that overhead, but five alternating 1,024-repeat
pairs still gave only these noisy median changes:

| Recording | Original helper | Guarded helper | Reduction |
| --- | ---: | ---: | ---: |
| Original | 687.305 ms | 670.326 ms | 2.47% |
| Spread | 466.364 ms | 455.285 ms | 2.38% |

The final experimental test image was
`18FA6AF55FB1FE41C77A4BDC5861B51D34CF1B233B9ADBEB41867FF5FF1D2754`.
Digests remained `75d4ff1e67bbbc4c` and `6c13c7a10069aeef`. Fixed
`out/xmen-final3-build/vu-bounded-comparison.log` retains that comparison.
The experiment, its selector APIs and environment switch were removed. Only
the expanded scalar/vector boundary tests remain. No new game was linked,
launched, packaged or offered for user testing; no FPS gain is claimed.

Next investigate avoiding the per-instruction native helper calls themselves.
The existing CodeGen API has packed add/subtract/multiply operations; the
current multiply-add path uses separate `MD_MulS`/`MD_AddS`, not fused arithmetic.
Do not silently replace the runtime's fused model with that path. A direct
emitter must preserve masks, source aliases, result/status rounding, queued
flags and exceptional-value behavior, with full replay/audit validation.
The direct-emission experiment above supersedes this next-step note; it has
not demonstrated a useful overall speedup.

The restored standalone image
`3BCC93677C79C609E444A4DE5718B10458AC23D7FD9E9C507D7CC99A05A69164`
passes the expanded 149,760 cases and the existing 21 upstream tests. The
wrapper's expected case count was updated; an initial harness failure was its
old hardcoded count, not an arithmetic failure. All checkpoints remain local.

Restored runtime test image
`07F696C3ABBCDCD8B6AA4E3A1A82955C5E8C22BD515BC53EA9F7B3F60B1269BF`
passes 161/161 VU tests, both original records at full/1/8/16/64-cycle budgets,
and all four saved failure records. Hybrid full-drain execution accepts 14/8
original/spread cases; the short budgets retain the original engine. The EFU
record also stays on the reference path; entry-wait/Q-call/FTOI records compile.
The first full-suite launch used the executable directory and could not find
`instructions.h`; rerunning from the PS2Recomp source root passes. Fixed
`vu-restored-checks.log` holds that final successful run. The game candidate
remains `23A73821...`; no new gameplay or FPS validation occurred here.

## Bulk Transfer Checkpoint

The existing `A8B0EF85...` game candidate completed a compiled-on phase/CPU-raster
profile at 2026-09-06 11:13 UTC, with verified gameplay markers, exit 0 and zero
logged guest faults. Exclusive measured work over ticks 1100..1400 was 47.59%
VU, 36.82% GS, 8.08% guest and 5.04% other transfers. The 129 raster reports for
presents 1152..1280 averaged 64.159 ms and 23,423 submissions per frame. This
profile is not an FPS benchmark. Both VU and rendering need substantial savings
to reach 30 FPS; VU-only work cannot remove the current raster cost.

A bounded replay sampler also identified byte-vector appends and transfer
observation among the hot functions. Its successful 2,048-repeat run covered
all 32 original records (101 execution samples, 34 outside the test module,
15 unresolved external addresses). This is directional evidence, not a complete
game profile. A preceding 4,096-repeat attempt hit the replay cycle budget and
was discarded; the fixed sampler log contains only the successful run.

The local transfer path now copies ready payload blocks instead of appending
each byte. Copies stop at the observation cycle, GIFtag boundary and memory
wrap; `finish` advances whole known payloads. Session and bridge outputs move
packet ownership instead of copying payloads twice, and an expected session
rejection returns normally rather than throwing another exception.

Verification:

- 372 new standalone cases compare bulk observations with single-cycle reads,
  including intervening memory stores, all GIF formats, zero-loop tags, odd
  REGLIST counts, 16-register encoding, wrapping and chained tags.
- All existing standalone contracts and 21 unchanged upstream VU tests pass.
  Probe SHA: `C68B5924E548D18695331E739D85BD8412FF05C5A8626F9EF419374E8598B79A`.
- Runtime SHA: `323E5CEB707D62E88ED6BE9B712E6058E36FAAD568F01C838214ED5BB4E3A4C7`.
  All 161 VU tests, ten original replay/budget checks, hybrid captures and four
  saved failure replays pass with unchanged bytes, state, cycles and digests.
- Serial three-round 256-repeat hybrid medians changed from 173.960 to
  162.568 ms (original capture) and 115.178 to 108.471 ms (spread), about 6.5%
  and 5.8% lower execution time. Original-engine controls remained near
  382.709/382.984 ms and 161.987/160.966 ms. An earlier after-change timing run
  overlapped the VU suite and was discarded before the serial measurements.

No new game executable was linked for this isolated improvement. Current game
FPS remains the prior 5.64-on/4.77-off pair below, not an extrapolated rate.
Keep this transfer improvement for the next performance bundle. Next target
the CPU raster path's repeated per-pixel texture sampling and write-state work,
with differential framebuffer/depth validation before a combined game audit.
No images, additional checkout/build tree, push or PR were created. All owned
profile/build/test processes are closed and startup scripts are restored.

## Q, Native-Call And Conversion Corrections

The two subsequent game recordings exposed separate compiler defects, now
reproducible and fixed locally. The engine remains opt-in/off by default;
compiler tests alone do not establish gameplay speed or interactive playability.

- Native calls could observe a deleted earlier CPU-state store, or a later
  generated read could reuse a pre-call constant. `codegen-context-calls.patch`
  preserves relative stores across calls and invalidates their known versions.
  Both direct regressions fail before/pass after; read-only-before-call tests
  also cover 32/64/128-bit reloads. This repairs the paired-immediate discrepancy
  without changing the game's immediate instruction ordering.
- Runtime-mode Q synchronization now occurs at compiled entry boundaries,
  including isolated branch/delay pairs. Actual elapsed waits age incoming VF
  masks. Busy Q after local upper arithmetic conservatively rejects private
  execution via the generated epilogue, not an exception through JIT frames.
  Twelve DIV/SQRT/RSQRT gap cases and five pending-write/paired-upper/branch/I-bit
  cases verify values, flags, timing, and clean fallback.
- Immediate storage matches the runtime's finite-operand rules, with 12 raw
  input cases. FTOI0/4/12/15 now saturate positive overflow to INT_MAX instead of
  host conversion's INT_MIN. The correction is emitted as SIMD operations,
  not a per-conversion native callback; 192 scale/mask/value cases pass.

Runtime test SHA-256:
`0A68DF003B202B8E0E01246A37EDA330D700422B0F3FBFD5BF3BD48C2CD987F1`.
All 161 default VU tests, including 14 compiled integration cases, pass.
Both original recordings retain exact results at normal/1/8/16/64-cycle budgets.
All four saved failure cases now pass hybrid replay: EFU through unchanged
fallback, and incoming waits/Q-call/FTOI through compiled execution. The Q-call
record now matches all 2,874 cycles and 13 timed packets; the FTOI record matches
all 263 cycles, registers, data and three timed packets. Private record names
are `vu-efu-failure.bin`, `vu-entry-wait-failure.bin`, `vu-q-call-failure.bin`
and `vu-ftoi-failure.bin`; never stage these game-derived captures.

Final standalone probe
`D3D906DD159A8201BEF3B76338198730D67FDBD1FD2A57EE6794FB3607D5C17E`
passes all public contracts and 21 unchanged upstream VU tests. The unchanged
CodeGenTestSuite passes (exit 0), SHA-256
`94A77D0059161E3BC34A9762ED0E78DBA68F201FD55349CEEF23D5F4444BF966`.
The GS suite remains 86/87 with the previously documented CSR/IMR failure.
It is not a full-suite pass.

Candidate `A25C7698...` (before FTOI correction) stopped its fourth audit at
5,991 accepted calls / tick 381 / PC `0x16a8`, saving the now-fixed FTOI case.
New Game and NYC package markers appeared; no valid FPS was produced. The
candidate with all corrections completed its fifth audit at 11:02 UTC:
`A8B0EF858621D1ECB202E100A4E3B622B3A8B4D5DEA7E7066FD0FD1A7502F043`.
At least 258,049 compiled calls matched the original engine before publication;
the run reached its 1,400-vsync limit, New Game, NYC package and both presentation
markers, with runtime exit 0 and zero logged guest faults. This bounded run did
not reproduce the earlier null dispatch; it does not prove unrestricted play.
The harness deliberately excludes audits from `WorkloadVerified` and FPS and
ends with its non-benchmark exception even when the runtime finishes cleanly.
The subsequent same-binary pair completed without logged guest faults:

| Mode | Recorded UTC | 128-present interval | FPS |
| --- | --- | --- | --- |
| Compiled on, no audit | 2026-09-06 11:06:02 | 22.6916101 s | 5.640851 |
| Compiled off | 2026-09-06 11:09:33 | 26.8608598 s | 4.765298 |

This one shared-host pair shows about 18.4% higher FPS, not the 30 FPS target
or a repeated-trial confidence estimate. Both runs verified New Game, the NYC
package, native blocks, present markers 1152/1280, runtime exit 0 and the
1,400-vsync limit. The non-audit compiled run accepted at least 258,049 calls.
Input was disabled and no visual-fidelity or interactive-control claim is made.
Fixed `gameplay-compiled-rate` and `gameplay-rate` logs/reports retain the pair;
the older 4.97750 FPS result belongs to the preceding candidate.
All owned game/build/test processes have ended and startup scripts are restored.
Next profile the remaining whole-game cost with this correctness-checked engine,
prioritizing substantial VU and GS savings over more detached correctness probes.
Do not promote compiled mode or announce a controls-enabled handoff yet.

Automatic first-nonblack and preset-frame screenshot dumps are disabled in the
new performance candidate. Explicit `PS2X_DUMP_PRESENT_RANGE`, latest-frame
capture, and `PS2X_CAPTURE_FIRST_NONBLACK=1` remain available when needed.
No capture app or desktop input was used. All source changes and commits stay
local; no pushes or PRs. Nested checkpoint `09d1cf1` contains the capture change.
The sections below retain earlier checkpoint evidence.

## Earlier Shadow-Audit Checkpoint

As of 2026-09-06 10:35 UTC, all changes remain local: no PS2Recomp push or PR.
Local PS2Recomp commit `e49ab1d` provides the private pre-publication audit.
The optional engine is still off by default. Run
`run-gameplay-benchmark.ps1 -CompiledVu -AuditCompiledVu` to compare each
accepted result against private original-engine execution before publishing
state or graphics. The first mismatch saves one bounded private replay and
the benchmark closes only its owned process, then restores startup. Audit
runs disable host input and are explicitly excluded from FPS measurement.

Two game failures are now reproducible and covered:

- PC `0x22b0`, after 100 accepted calls: EFU arithmetic differs. Reached EFU
  blocks now reject the entire private attempt, including staged writes and
  packets, and use the original engine. Rejection caching is entry/code-specific;
  other entries still compile and code changes clear it. EFU math is not fixed.
- PC `0x528`, after 4,918 accepted calls: an incoming VF wait did not age the
  other pending writes, overcharging two cycles. The Play source patch now
  resolves the longest incoming dependency first and ages all pending masks.
  All 72 read-order/register-group/gap variants pass, and the real recording
  matches registers, memory, timed packets and all 276 cycles without fallback.

Final test SHA-256:
`CF73728C2E12926AC13E3140B945BA592C02F7289833353D772081C37A09583C`.
All 156 default-mode VU tests and nine compiled integration tests pass, as do
both original 32-record captures at normal/1/8/16/64-cycle budgets. The audit
regression rejects corrupted registers, data, packet content and packet timing
without modifying live state or GS. Standalone probe
`831AC8DBBC775B24E0456B19A4177201E7C0C09AFE074003A8AE70A365E07C20`
passes all 21 upstream tests, the existing contract suite, and the real
incoming-wait recording with complete architectural equality. The saved Play
patch reverse-applies cleanly; scoped attributes preserve its LF line endings.

Latest game candidate:
`9CC0649BC344544A6A39F0DF85E6DF65836F6A25C2EBE400BC9DC31909842B44`.
Its third audit passed 7,148 compiled calls, reached New Game and NYC package
markers, then stopped at tick 469 / PC `0x540` / cycle 37118928 before publishing
a mismatching result. Original replay passes with digest `ddf5b50851320b9f`.
Compiled output differs in Q, 12 VF words, 88 data bytes, packet bytes and
completion (2854 vs 2874 cycles). This is the next isolated investigation;
Q readiness and static/incoming waits are hypotheses, not established causes.
The fixed private `vu-compiled-failure.bin`, `gameplay-compiled-audit` logs and
`play-vu-failure.log` preserve it; earlier EFU and incoming-wait captures remain
in two separate small private files. None are staged in Git.

No new valid gameplay FPS or control handoff is claimed. Last valid baseline
remains 4.97750 FPS. All owned build/test/game processes have ended. The original
compiled-on null-object failure below has not been shown resolved. The following
sections retain earlier checkpoint evidence; their next-step text is historical.

## Experimental Runtime Hook: Not Ready for Gameplay

Local PS2Recomp commit `e7408e9` adds the opt-in hook and replay validation.
The full-drain hook is compiled only when `PS2X_VU_COMPILED_ENGINE_DIR` points
here, and executes only with `PS2X_VU_COMPILED=1`. It is **off by default**.
Unsupported entries retain the original engine; short slices through 64 cycles
never enter the adapter. Existing standalone libraries and one build tree are
reused. No runtime class layout or generated guest source changed.

Configure using `build-below-normal.ps1 -Target ps2x_tests -ConfigureCache`
with `PS2X_VU_COMPILED_ENGINE_DIR=C:/Programming/GitHub/OpenXML1/xmen-legends/play-vu-probe`.
Keep the existing `PS2X_VU_COMPILED_TEST_DIR` setting to include integration tests.
Set `PS2X_VU_REPLAY_COMPILED=1` for hybrid replay validation. The first pass
always verifies the original engine against the complete recorded state;
compiled passes compare completed architectural state, memory and timed packets.
Inactive scheduling payloads may differ and are not called raw-state matches.
Fallback passes still require raw-state equality. The replay digest identifies
the recording, not raw compiled output equality.

Final test image `86FC5144826AF17612F221054FC1D071969EE4D4CB4004519275E1DC04572281`
passes all 153 default-mode VU tests, including six producer integration tests.
Both 32-record captures pass original-engine normal/1/8/16/64-cycle checks.
Hybrid checks commit 14 original/eight spread cases, with exact architectural,
memory and packet matches; 64-cycle hybrid checks use only verified fallback.
Globally enabling the engine for the older PS2VU1 suite gives 81/82 passes:
the existing mixed-size XGKICK test compares inactive serialized bookkeeping.
It is retained unchanged. A separate paired test verifies the mixed-size
packets, registers, memory and completed cycles against short-slice execution.
This does not establish equivalence for unrecorded game workloads.

Three alternating 256-warm-repeat runs measured the actual hybrid adapter,
including capture/commit, copying, fallback and packet observation:

| Capture | Original engine ms | Hybrid ms | Median ratio |
| --- | --- | --- | ---: |
| Original | 377.809 / 387.518 / 396.911 | 172.172 / 169.875 / 171.689 | 2.257x |
| Spread | 163.085 / 158.544 / 157.904 | 111.808 / 111.216 / 114.248 | 1.418x |

These omit cold compilation and full GS drawing and are **not gameplay FPS**.
Measurement image was `7EBE9221D09DB4AE5DF638E92F274646EF297E2852DF3FDE98F27F9E7532A630`.

Game candidate `AAAC937D19F676137A9650BFFFC1F814DDEBBACD4FB049D660D6F8A02218CE6A`
includes this opt-in performance experiment and the queued title/FPS counter.
Its compiled-on run committed at least 208,897 calls but failed before the
1152/1280 measurement markers: null-object virtual dispatch at guest call
`0x396e7c`, return `0x396e84`, missing target `0xa3a1d0`. Its 99-second total
runtime is not a speedup. Fixed `gameplay-compiled-failure` logs preserve it.
The same executable with the engine off completed at 2026-09-06 09:56 UTC,
zero guest faults, all workload gates, 128 presents in 25.715718 seconds
(4.97750 FPS, approximate shared-host timing). Earlier builds sometimes failed
at a similar call; that does not exonerate the new engine.

Next isolate the first divergent state or ordering in the compiled-on workload,
including singleton allocation at `0x38cfd0` and its allocator dispatch through
`0x14cb28/0x14cb3c`. Existing allocator diagnostics are available in the runtime.
Do not patch around the null pointer or promote this candidate as a verified
speedup. Controls were disabled in both benchmarks and both processes ended.
All commits stay local; no push or PR. Sections below describe older checkpoints.

## Real Runtime Boundary Tests

Local PS2Recomp commit `29310f3` adds an opt-in external test extension only.
The new `runtime_adapter.cpp` now exercises the actual capture/commit boundary,
not a copied runtime state implementation. It reuses the standalone session/core
libraries and compiles the two runtime-facing translation units with the real
runtime's conditional class-layout definitions. No additional checkout, core
build directory, game executable or default execution hook is introduced.

```powershell
./xmen-legends/build-below-normal.ps1 -Target ps2x_tests -ConfigureCache @('PS2X_VU_COMPILED_TEST_DIR=C:/Programming/GitHub/OpenXML1/xmen-legends/play-vu-probe')
./xmen-legends/build-below-normal.ps1 -Target ps2x_tests
```

Run `ps2x_tests` with `MINITEST_FILTER=PS2VU1CompiledProducer` for the four
integration cases, or `MINITEST_FILTER=VU` for the full focused suite. Tests
need no game input, screen capture, ISO or window. Build and test processes
were hidden, bounded, and limited to the established four-processor affinity;
build priority stayed BelowNormal.

Final test image:
`EDD4F1D4899AB1D4213541DCF1FF4E1BBDBB705E38F1022C0FB001B6F95D7522`.
All **151 VU tests pass**, including real pending VF/flag import, completed
state/memory commit, normal-engine continuation consuming signed VI values,
and a compiled XGKICK packet reaching GS SIGNAL exactly once. Short/over-budget
attempts leave live state, queues, memory and graphics unchanged; subsequent
interpreter execution matches the reference. A synthetic graphics sink exception
propagates after commit rather than returning false and inviting unsafe fallback.

The first graphics assertions failed because the test fixture had no memory-to-GS
callback on either path. Connecting the fixture's actual graphics sink fixed
those assertions; no expected results were weakened. Existing raw replay tests
remain unchanged: both 32-record sets pass normal/1/8/16/64-cycle runs with
digests `75d4ff1e67bbbc4c` and `6c13c7a10069aeef` respectively. These replay tests
still run the original engine, not the compiled adapter.

Next connect this tested adapter to an opt-in full-drain execution hook and
verify hybrid recorded workloads before measuring a game build. These synthetic
runtime tests do not establish broader workload coverage or gameplay FPS. The
game candidate remains `61E24D60...`, unchanged. All commits remain local;
no push, PR, game launch or screenshot was made. No old disc images required
cleanup. The previous detached-only and partial-flag notes below are history.

## Runtime Arithmetic Compatibility

Current image: `CA7AB282F405BBAA70265C0D0DA59223731E13080231B446054F2D8BD36ACEF0`.
All **22 eligible recordings now match architectural values, memory, graphics
packet bytes and completion timing** through the typed producer. Verify with:

```powershell
./xmen-legends/play-vu-probe/test.ps1 -ReplayPath xmen-legends/disc/vu-replay.bin -RequireRecordedMatch
./xmen-legends/play-vu-probe/test.ps1 -ReplayPath xmen-legends/disc/vu-replay-spread.bin -RequireRecordedMatch
```

The old differences were caused by multiply/add contraction. Inspection of the
unchanged runtime baseline `77E6FDB3...` and its timestamp-matched map
(`0x6a9d20cb`) found FMA instructions in `execUpper`, native upper kernels and
other VU code. A temporary fused-helper experiment eliminated every recorded
VF/memory/packet/Q difference, but failed the separate-rounding underflow test.
That experiment returned failure (exit 12); it was not promoted as a passing
implementation. The temporary test-runner behavior was removed.

Sessions now choose an immutable arithmetic policy at construction:
`Separate` remains the default, while `RuntimeFused` matches the existing
runtime's host arithmetic. The typed runtime bridge and recording comparison
explicitly use `RuntimeFused`; neither policy depends on captured expected
values or a game/program identity. FMA selection checks CPUID/OS support, with
a scalar `std::fma` fallback. Both modes retain the same widened flag model.
This is compatibility with the current runtime, not a claim that fused host
arithmetic reproduces every hardware exception or rounding detail.

All 39,168 scalar/vector comparisons pass in both modes. Another 128 compiled
tests distinguish the modes across MADD/MSUB, accumulator writes and all masks.
Existing separate-rounding regressions remain unchanged and pass. Complete
STATUS/MAC export (`0xfff/0xffff`) now includes U/O current and sticky bits;
4,096 status round trips and 64 independent pending/reset cases pass, as do
the prior timing, ownership, ABI and rejection tests.

Architectural comparison covers every VF/ACC/scalar word, all 16 VI bits, full
flags, PC, elapsed cycles, TOP/ITOP, halt/branch state, data memory and timed
packets. Inactive branch target/delay payloads are not architectural output.
VI host containers can differ in sign extension (`00008000` versus `ffff8000`);
those differences are separately printed, not hidden as raw-state equality.
Runtime branch/address code explicitly truncates VI reads to 16 bits. The real
commit/resume tests above now cover this handoff; no game replacement engine is enabled yet.

Final three-round timings, same complete-call scope and 256 warm repetitions:

| Recording | Round | Runtime Eligible ms | Typed Call ms |
| --- | ---: | ---: | ---: |
| Original | 1 | 304.709 | 83.327886 |
| Original | 2 | 314.777 | 82.756086 |
| Original | 3 | 299.253 | 87.018986 |
| Spread | 1 | 79.651 | 28.757792 |
| Spread | 2 | 81.383 | 26.963692 |
| Spread | 3 | 78.298 | 27.453192 |

Median eligible runtime/compiled ratios are approximately 3.66x/2.90x, not
gameplay FPS. All rounds required recorded architectural matches. Runtime
capture/commit, GS, cold compilation and returned-output disposal remain
outside this timer. Actual commit/resume and fallback tests now pass as described
above; a hybrid execution hook and measured game candidate remain next.
General VI/store timing and exceptional arithmetic still need coverage beyond
these recordings. No game build, screenshot, push or PR was made. Older
partial-mask and numerical-mismatch checkpoints below are historical.

## Arithmetic Throughput Checkpoint

Current image: `2FBC117747FA8D516DD5BAA954B26299B05E8C9C45E624553FF06D31ACE07CD2`.
The AVX2 FMAC helper now inlines classification, normalizes magnitudes with
integer min/masks, reverses all four flag nibbles together and constructs the
write mask with a vector comparison. Disassembly confirms no internal calls
in the AVX2 arithmetic object. Arithmetic expressions, strict FP settings,
scalar fallback and timed flag queues are unchanged. The JIT-to-helper call
still exists; this is not fully inline compiled arithmetic.

Parity coverage now includes 19,584 deterministic edge/random input cases,
all operation masks, source/destination aliases and VF0 reads/writes. All pass
against the unchanged scalar implementation, alongside the six independent
range cases and all prior tests. This proves implementation parity, not full
hardware fidelity.

The opt-in RSQRT path also emits `numerator / sqrt(abs(radicand))` directly,
instead of multiplying by a rounded reciprocal. A new regression failed before
the change: `3 / sqrt(abs(-2))` returned `0xff7fffff`, not `0x4007c3b6`.
All 256 finite-input/component/sign tests now pass, including the old-Q read at
cycle 12, new-Q read at 13, and invalid-input flag timing. No new callback is
needed. Without the FMAC compiler selector, upstream emission remains unchanged.
The nonzero calculation order is also used in
[PCSX2's VU interpreter](https://github.com/PCSX2/pcsx2/blob/master/pcsx2/VUops.cpp).
Zero/denormal/exception semantics are not declared resolved by these tests.

Three-round complete-call measurements, 256 warm repetitions, Normal/F affinity:

| Recording | Prior Helper ms | Current Helper ms | Runtime Eligible ms |
| --- | ---: | ---: | ---: |
| Original, round 1 | 125.526986 | 85.372686 | 311.021 |
| Original, round 2 | 125.765786 | 84.514186 | 303.337 |
| Original, round 3 | 121.906186 | 83.202486 | 302.587 |
| Spread, round 1 | 37.790192 | 27.466492 | 79.770 |
| Spread, round 2 | 37.125892 | 27.362292 | 80.348 |
| Spread, round 3 | 38.009492 | 27.468792 | 78.203 |

Prior helper image is `B7C7B9BD...`; runtime baseline remains `77E6FDB3...`.
Before/after series were sequential, not interleaved. Median complete-call time
drops about 33%/27%; current eligible runtime/compiled ratios are about 3.59x/2.90x.
The existing timer scope still excludes runtime capture/commit, GS, cold compile
and returned-output disposal. These are not gameplay FPS measurements.

All 22 eligible recordings retain full MAC/STATUS matches and exact completion
timing. The three existing Q differences and the spread recording's vertex,
memory and packet differences remain; the RSQRT fix did not remove those.
Acceptance masks remain partial and runtime-accepted remains zero. Next trace
the first differing arithmetic inputs/results, and finish exceptional FMAC and
VI/store semantics before integrating. No game binary, screenshots, extra
checkout, push or PR was created. The range prototype below is prior history.

## FMAC Range Prototype

The detached path now selects host-compiled arithmetic functions for ADD/SUB,
MUL, MADD/MSUB, their accumulator/broadcast/Q/I forms, and cross products.
Selection occurs when compiling a block, not on every execution. Functions
snapshot operands before aliased writes, normalize input encodings, retain
unfused float results and use widened calculations for range flags. Returned
current and product-sticky lane masks enter the existing timed flag queues.
Full incoming MAC and Z/S/U/O current/sticky state is now preserved independently.

`fmac.cpp` is compiled as scalar/SSE2 and AVX2 objects in the same build. CPUID,
OSXSAVE and XCR0 checks gate the AVX2 selector; unsupported hosts keep the scalar
implementation. There is no extra checkout or game build. This prototype does
make one arithmetic function call per FMAC instruction, unlike the earlier
incomplete inline arithmetic path. Its cost is material and is not hidden below.

Six explicit range/value cases cover signed underflow, overflow saturation,
current versus product-sticky flags, accumulator writes, four-cycle visibility
and reset timing. The pre-helper test failed with MAC `0x004d` instead of
`0x2c4d` and STATUS `0x0c3` instead of `0x3cf`. All six now pass, along with
1,152 scalar/AVX2 comparisons across operation forms, masks, aliases, VF0 and
edge encodings. Independent initial/pending/reset state tests expand to 64 cases.
The AVX2 path was exercised on this host. All prior public tests still pass.

Final image `B7C7B9BDD388C423D7C98246C00BF316DB92A086B42F07C0B9E851389BE1FB72`
matches **full MAC and STATUS values in all 22 eligible recordings**, with exact
completion cycles and repeatable typed outputs. Existing Q, vertex and memory
differences remain. Export acceptance masks deliberately remain `0xcf3/0x00ff`;
recording agreement is not evidence for promoting all arithmetic forms or timing
states into the game. Runtime-accepted remains zero.

Before widening those masks, audit exceptional MADD/MSUB product/ACC overflow
interactions, including overflow followed by cancellation, cross-product mask
semantics and remaining VI/store timing. A widened final expression is not a
complete model of every two-stage VU exception. The distinction between final
and product-sticky flags is described in the
[VU manual, sections 3.3.2 and 3.3.6](https://docs.alexrp.com/mips/ee_vu.pdf#page=40).
No full hardware-fidelity or gameplay-readiness claim is made here.

Final three-round measurements, same baseline `77E6FDB3...`, 256 warm repetitions
and the established complete-call timer scope/exclusions:

| Recording | Round | Baseline All ms | Baseline Eligible ms | Typed Call ms |
| --- | ---: | ---: | ---: | ---: |
| Original | 1 | 388.873 | 311.138 | 129.886786 |
| Original | 2 | 388.283 | 310.581 | 127.142986 |
| Original | 3 | 388.110 | 310.970 | 125.856286 |
| Spread | 1 | 161.709 | 81.200 | 38.781792 |
| Spread | 2 | 167.665 | 85.481 | 39.166792 |
| Spread | 3 | 165.170 | 83.733 | 38.926492 |

Eligible median ratios are about 2.45x/2.15x, down from the preceding incomplete
path's roughly 5x/4x. The scalar-only prototype was slower still (approximately
170/51 ms in its initial observation). Do not package this as a gameplay FPS
improvement. Reduce arithmetic-call/classification cost and resolve the remaining
correctness gaps before integrating a measured runtime replacement. No push,
pull request, game run or screenshot was made.

## Independent MAC and STATUS

The opt-in compiler now retains current STATUS lane bits in the high half of
the existing sticky pipeline values; the low half retains accumulated sticky
lane bits. MAC continues to use its own pipeline. No MIPS state layout, extra
pipeline, or per-arithmetic callback is introduced. FSSET keeps the previous
current STATUS and replaces sticky bits; its simultaneous upper arithmetic
still produces the vector and MAC result, but not a STATUS update. Lower words
used as I-bit immediate data do not trigger this suppression.

This follows the flag-setting priority rule in the
[VU User's Manual, section 3.3.4](https://docs.alexrp.com/mips/ee_vu.pdf#page=40)
and the four-cycle FSSET definition on page 157. The rule is not inferred
solely from matching the existing runtime. The public paired regression failed
before the fix (`STATUS=0x02` rather than preserved `0x01`, with `MAC=0x80`).
Sixteen paired/immediate cases now pass, plus sixteen typed import/export cases
where initial MAC and STATUS differ, pending writes affect only MAC or also
STATUS, and a following sticky reset preserves current STATUS.

Final image `7C43EA3C79BA8C7EAA64187E1203C88AC15BA26AD68363BC1CC7537968433A2E`
passes these cases and all previous public tests. All 22 eligible recordings
retain supported STATUS/MAC matches, exact completion cycles and repeated typed
outputs over 256 warm calls. The known Q differences in original cases 6/14 and
spread case 29 remain, along with the other numeric/memory differences. STATUS
coverage remains `0xcf3`, MAC `0x00ff`, and runtime-accepted remains zero.

Three sequential comparisons, using the same baseline `77E6FDB3...` and timer
scope/exclusions described below (milliseconds across 256 warm repetitions):

| Recording | Round | Baseline All | Baseline Eligible | Typed Call |
| --- | ---: | ---: | ---: | ---: |
| Original | 1 | 376.097 | 300.827 | 55.912086 |
| Original | 2 | 375.357 | 300.250 | 56.541786 |
| Original | 3 | 384.247 | 309.141 | 56.426186 |
| Spread | 1 | 156.921 | 78.439 | 20.144892 |
| Spread | 2 | 164.653 | 83.909 | 19.881392 |
| Spread | 3 | 158.840 | 80.432 | 20.017892 |

Eligible median ratios remain about 5.33x/4.02x. This is not a measured hybrid or
gameplay speedup. Next address FMAC overflow/underflow and the remaining numeric
and VI/store timing differences before runtime acceptance. Everything remains
local; no game build, push, pull request, or image capture was made.

## Arithmetic Sticky Reset Ordering

The opt-in compiled FSSET path queues sign/zero sticky resets in the existing
four-cycle flag pipeline instead of immediately clearing the live sticky state
and all pending arithmetic. This emits native pipeline writes, not a callback
per arithmetic instruction. Without a status observer, the original Play! FSSET
implementation remains unchanged.

Eight public cases cover all four sign/zero reset combinations, arithmetic
before the reset, reads before/at retirement, and optional later arithmetic that
sets sticky bits again. The uncorrected compiled session failed the first case:
at cycle four, FSAND returned `0x01` instead of `0x41` because the reset had
discarded the older pending zero flag. All eight cases pass after the change.

Image `1F22FC558565019D3C9E062E39F1A1F233B3C039E44FEB122E560FCC27B53CB7`
passes the public suite and both existing recordings (14 original/eight spread
eligible cases), including repeated typed outputs and scalar-status checks.
This earlier checkpoint did not yet cover same-pair upper arithmetic/FSSET
STATUS suppression; that is addressed above. FMAC overflow/underflow and the
numeric/timing differences listed below remain unresolved.
No game build, compatibility acceptance, or gameplay FPS gain is claimed.
The timing table below belongs to the preceding scalar-status image.

## Timed Scalar Status

The local bridge now tracks invalid-operation/divide-by-zero status and their
sticky bits (`0xc30`) independently of Play!'s legacy boolean division flag.
An optional, compile-time-installed status callback observes DIV, SQRT, RSQRT,
FSSET, FSAND and FSOR. Absence of the callback retains the original Play! path.
Changing callback presence requires resetting the compiled-code cache. The patch
is included in the existing `play-vu-memory-observer.patch`; it is no longer a
memory-only patch. No PS2Recomp commit or pull request is required for this local
experiment, and no game runtime is linked or enabled.

The bounded queue retires scalar flags with Q, defers sticky resets by four
cycles, preserves incoming sticky state and pending FSSET events, and applies
FSSET before FDIV at an equal completion cycle. Reads merge the retired scalar
bits before FSAND/FSOR apply their immediate operand. End-of-program draining
includes pending scalar-status deadlines in the budget. Errors are caught inside
the callback and reject the detached execution without publishing output.

Behavior was checked against the [PCSX2 VU interpreter reference](https://github.com/PCSX2/pcsx2/blob/master/pcsx2/VUops.cpp):
DIV zero/zero is invalid, negative square-root operands set invalid, and RSQRT
zero/zero sets both invalid and division-by-zero. Only status behavior is changed
here, not Q's numeric implementation. PS2Recomp's existing RSQRT zero/zero handling
differs from that reference and still needs a separate fidelity decision. PCSX2
was inspected, not linked or copied into this implementation.

Thirteen public cases verify both sides of the 7/13-cycle visibility boundary,
FSAND/FSOR, delayed FSSET, signed zeros, normalized denormals and negative roots.
The no-callback baseline demonstrably fails: zero/zero reports `0x020` immediately
instead of remaining clear until the result retires with `0x410`. Additional
checks cover same-cycle retirement ordering, an incoming sticky-reset tail after
E-bit completion and rejecting that tail when it exceeds the execution budget.
All prior public tests, including 21 unmodified upstream tests, also pass.

Final local image:
`E327761FDA2417E359622919BE06F627671CDAC161E905D8A6CA708339DFB646`.
All 22 eligible recordings match the new scalar-status bits with zero mismatches;
combined typed outputs remain repeatable over 256 warm calls. STATUS coverage is
now `0xcf3`, MAC remains `0x00ff`, and runtime-accepted remains zero. FMAC overflow/
underflow, full sticky/reset interactions, general VI/store timing and existing
numeric differences are not solved by this change. Next address those semantics,
not another conversion wrapper or an inactive game build.

Three sequential timing comparisons on the existing 256-repeat setup:

| Recording | Round | Baseline All ms | Baseline Eligible ms | Typed Call ms |
| --- | ---: | ---: | ---: | ---: |
| Original | 1 | 393.512 | 314.822 | 57.805686 |
| Original | 2 | 388.948 | 311.269 | 58.397386 |
| Original | 3 | 399.766 | 319.092 | 57.742886 |
| Spread | 1 | 163.490 | 82.907 | 20.485192 |
| Spread | 2 | 162.462 | 80.857 | 20.537092 |
| Spread | 3 | 164.514 | 81.451 | 20.570892 |

The added work retains about 5.45x/3.97x eligible median ratios against the same
baseline image `77E6FDB3...`, not a gameplay speedup. Timer scope and exclusions
are unchanged from the typed bridge section below. The game executable remains
unchanged, all owned tests/builds are closed and no captures were generated.

## Typed Runtime Bridge

`play_vu_runtime_bridge` now translates `VUCompiledState::Input` directly into a
detached compiled session and returns a staged `VUCompiledState::Output`. Its
library has no recording parser, `TestVm`, GS callback, or host input dependency.
It imports pending VF values with per-lane ownership/readiness checks, pending
flags in stable deadline order, idle Q/P held values, and integer branch backup.
Invalid queue masks, missing/duplicate owners, unsupported deadlines, malformed
entry state and elapsed-time overflow reject before execution. Exports include
registers, completed time, memory, and ordered packet bytes/completion times.

The PS2Recomp side is commit `3060eab`: capture rejects unsupported running states;
commit validates the complete batch before any memory/state/graphics publication.
It requires full MAC/STATUS masks and completed incoming deadlines. State checks
compare fields and raw float bits, not struct padding. VF0 uses canonical bits,
including rejection of negative zero and NaN even with fast floating-point builds.
The API assumes serialized ownership of the interpreter and its code/data memory;
the state token is not a concurrent memory transaction. No execution hook is set.

**Current outputs are not acceptable for game execution:** STATUS coverage is now
`0xcf3` as described above, MAC coverage `0x00ff`. Unknown bits are not copied from the expected replay
or fabricated. General VI/store timing and existing arithmetic/state differences
also remain unresolved. The strict commit path therefore rejects every current
compiled output. Next work must address these semantics, not add another wrapper
or relink the game merely to expose an inactive bridge.

The earlier typed-bridge checkpoint below predates timed scalar status.
Public bridge regressions cover pending values, stable flag ordering, scalar and
branch state, immutable inputs, staged output, malformed-entry rejection and
recovery. Both recordings verify exact typed import against the independent byte
importer and exact typed export against the completed compiled diagnostic: 14
original and eight spread records. All 22 combined bridge calls repeat identical
outputs over 256 warm executions. This is parity with the compiled diagnostic,
not proof of PS2Recomp or game compatibility. Play! image:
`DF4A313485CCB15E4DFC23D5B38B2A772E00CE68B250B4E5CA97F5F7622BAC69`.

PS2Recomp test image
`77E6FDB365436C8B1E38E218E9DC3A0106FCB0D54CD6ACAB4CB019A8EEE95782`
passes all 147 VU tests and both captures at normal/1/8/16/64-cycle budgets,
including commit rejection and resuming through the existing runtime afterward.

Three sequential comparisons, 256 warm runs per record, Normal priority and
affinity `0xF`, in milliseconds:

| Recording | Round | Baseline All | Baseline Eligible | Typed Bridge Eligible |
| --- | ---: | ---: | ---: | ---: |
| Original | 1 | 399.855 | 320.304 | 54.734586 |
| Original | 2 | 407.188 | 326.109 | 54.151586 |
| Original | 3 | 400.754 | 319.729 | 55.899986 |
| Spread | 1 | 168.598 | 85.822 | 19.830692 |
| Spread | 2 | 163.993 | 82.432 | 19.481892 |
| Spread | 3 | 166.057 | 84.409 | 19.450092 |

The typed timer surrounds `evaluate`, including import/export, internal copies,
FP save/restore and graphics staging. It excludes cold compilation, runtime
capture/commit, real graphics submission and disposal of the returned output.
Eligible median ratios are about 5.85x/4.33x. This is not a measured hybrid runtime
or gameplay FPS increase; the recordings are not gameplay-frequency weighted.
Unlike the older direct diagnostic, the reusable session does not perform a
second legacy packet readback, so these figures are not a same-work comparison
against that older diagnostic timer.

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

The local `PS2Recomp` checkout must contain `3060eab` (or a compatible descendant
of `codex/xmen-legends-bringup`) for the typed state header used by the bridge.
This does not build or link the game runtime into the probe.

From the OpenXML1 root, apply the patch once to the pinned CodeGen checkout:

```powershell
$patch = (Resolve-Path xmen-legends/play-vu-probe/codegen-win64-simd.patch).Path
git -C .tools/Play-VU/deps/CodeGen apply --check $patch
git -C .tools/Play-VU/deps/CodeGen apply $patch
$contextPatch = (Resolve-Path xmen-legends/play-vu-probe/codegen-context-calls.patch).Path
git -C .tools/Play-VU/deps/CodeGen apply --check $contextPatch
git -C .tools/Play-VU/deps/CodeGen apply $contextPatch
$observerPatch = (Resolve-Path xmen-legends/play-vu-probe/play-vu-memory-observer.patch).Path
git -C .tools/Play-VU apply --check $observerPatch
git -C .tools/Play-VU apply $observerPatch
```

CMake refuses configuration if any required patch is absent. A reverse `--check`
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

## Completed Control-State Retirement

The diagnostic now computes the final drained time from the instruction clock,
transfer tail, scalar deadlines, flag queues and outgoing VF hazard masks. It
selects retired flag values instead of returning stale Play! mirrors. Q/P come
from their held results. This is a nonmutating diagnostic conversion, not a
production state exporter: integer/store scheduling, unsupported flags and
short-slice architectural visibility still need a runtime bridge.

A public test checks delayed Q/P, wrapped flag-ring ordering, sticky Z/S,
division status, CLIP, VF-only drain, a longer transfer tail and no mutation of
the source state. All public tests and both diagnostics pass on image
`16A8B4C85C187B1B9EFB651822A327D1C1110F1651F3E0C6055F6735F9326950`.
All 22 eligible records match drained time, supported MAC bits, CLIP and supported
STATUS bits. Nineteen also match both scalar results. Original cases 6/14 and
spread case 29 retain Q differences of one/two/one ULP respectively. STATUS
coverage is explicitly limited to mask `0x0e3`, MAC to `0x00ff`; unknown bits are
not filled from expected output or called compatible. Full-state acceptance
remains zero.

## Guarded Integration Feasibility

Three sequential comparisons of the existing 32-record sets measured 256 warm
runs per case, at Normal priority on four logical processors. Baseline image
`E399C97D...` retains exact replay digests; compiled image `6E00516C...` includes
the wait/scalar-import fixes but not the later cold-only control report.

| Capture | Round | Baseline all cases ms | Baseline eligible ms | Compiled eligible ms |
| --- | ---: | ---: | ---: | ---: |
| Original | 1 | 395.502 | 316.301 | 82.074786 |
| Original | 2 | 397.280 | 317.560 | 80.261686 |
| Original | 3 | 399.951 | 321.666 | 79.991086 |
| Spread | 1 | 167.285 | 83.932 | 24.409492 |
| Spread | 2 | 169.159 | 84.584 | 24.743192 |
| Spread | 3 | 169.579 | 84.666 | 24.610292 |

Eligible work accounts for roughly 80%/50% of baseline time in these two bounded
recordings. Adding compiled eligible time to unchanged fallback time projects
about 160/109 ms, versus 397/169 ms baseline medians. This is arithmetic on
separate measurements, not a measured hybrid runtime. Import/export, compilation,
unknown flags and correctness gaps remain; sampling of the original captures is
not gameplay workload frequency. No gameplay FPS prediction follows from it.

This supports prioritizing a guarded full-drain integration with the current
engine handling unsupported cases, while retaining exact short-cycle handling
as a separate requirement. Both paths must preserve guest-visible state and
graphics ordering. It does not justify installing the diagnostic unchanged.

## Detached Session Library

`play_vu_session` is now a reusable static library containing `CompiledVuSession`
and the transfer timeline. It uses the pinned Play! core directly, not `CTestVm`
or upstream test sources. A session owns its code/data memory and compiler cache;
changed code invalidates the cache before execution. Each call copies input state
and data into private storage. No GS, EE, IOP or host input callbacks are exposed.

Successful execution returns staged memory, raw Play! state and ordered packets;
the caller must still validate/convert them before committing anything to the
game. Unsupported entry, failed compilation, non-E termination or exceeded cycle
budget returns a rejected result with no staged packets/data. The budget includes
known scalar, flag, VF and transfer tails. Short slices remain unsupported.
General VI/store retirement and unknown STATUS bits remain bridge limitations,
not silently accepted behavior. A session is single-owner, not thread-safe.

Every call saves the caller's floating-point environment, masks exceptions during
VU work, selects toward-zero/FTZ/DAZ, then restores the original rounding, exception
flags and exact MXCSR on success or rejection. Graphics staging is bounded to
1 MiB of completed packets plus at most one 64 KiB in-progress packet. Excess
output rejects the execution; partial packets never escape a rejected result.

Public tests exercise caller inputs remaining unchanged, multiplication rounding
under an upward-rounding caller, warm cache reuse, changed-code invalidation,
short-slice rejection, elapsed-budget rejection after graphics have been staged,
scalar-tail budget rejection, recovery after rejection, and the packet limit/reset.
The final test image `E7C86144FCAD459DD2E7F626266EBF452DA515FAC1420B19EF08EC1BB1A43C72`
passes these and all prior public tests. Across 22 eligible private records,
the session matches the direct probe's full raw MIPS state, final memory, staged
packet bytes, completion times and transfer end. This is parity with the probe,
not PS2Recomp compatibility: its existing arithmetic/flag differences persist.

This is the earlier detached-library checkpoint. The typed adapter and complete
call measurements above supersede its next-step plan. The session is still not
linked into the game. Current engine fallback must happen before external side
effects. Two obsolete probe-target object files were removed after moving their
sources into the library; the existing checkout/build is reused. Recordings
contain mid-program state, not fresh VU entry snapshots, so importing their
visible registers alone is invalid.

No game executable should be linked or packaged until the larger performance
change has measured benefit. The title/FPS counter stays queued for that build.
