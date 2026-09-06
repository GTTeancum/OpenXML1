# VU Slice Replay

The bring-up runtime has an opt-in, process-local VU1 recorder. Use it to check
and time interpreter changes against actual game work without repeating startup.
This is not a replacement for first-level gameplay validation.

## Pending Native Store Optimization

The latest test build is a checkpoint, not an accepted gameplay integration.
SHA-256 `E9F3850029A44174E1075B8F31B61748230FF98E21073FC41D950909BCA8E711`
passes 144/144 VU tests, both private recordings at normal/1/8/16/64-cycle
budgets, and `tests/test-vu-native-store-trace.ps1` in both filter modes.
Recordings retain their exact cycles, digests and coverage. Regression `983d723`
exercises five store forms, all masks, wrapping bases, upper/source overlap,
short execution slices and simultaneous PATH1 reads.

Only guarded compiled blocks with empty incoming store queues write directly
to VU memory. No memory reader intervenes before the original pair boundary;
PATH1 still progresses after retirement. Individual native pairs, interpreted
instructions and targeted store tracing keep the queued path. Full-mask stores
use a 16-byte copy, while masked stores preserve untouched lanes.

The earlier scalar-write candidate `9AF11E51...` measured original medians
1656.766 / 1588.925 ms (4.095% lower, 7/7 paired wins), and spread medians
1361.817 / 1333.030 ms (2.114% lower, 6/7). These are not measurements of the
final full-width-copy refinement. Repeat both seven-round comparisons against
`ps2x_tests.flag-pack-base.exe`, SHA-256
`4D876140E14717E5E2A8D20E99B752BEFBB5C4DB8338F93C253FAA7DF5FF5022`,
before accepting this change. The game candidate is still `BF9DED00...` below.
The fixed execution profiles remain tied to the older `784D74F1...` image;
their addresses must not be interpreted with the current link map.

## Packed Result Normalization

`1395fb9` widens and classifies all four lanes together for native ADD/SUB/MUL
and multiply-add/subtract instructions, including broadcast, Q/I and ACC forms.
The original float result is retained for normal lanes; signed zero, underflow
and overflow replacements follow the existing scalar classifier. Inactive lanes
keep their exact bits and receive zero lane flags. Cross products and non-AVX2
builds retain the scalar path. The interpreter and delayed-write scheduler are
unchanged.

A direct regression exercises 18 boundary values across all 16 masks with
mixed lanes, including values immediately above/below the float range limits.
Existing full-state native/interpreter comparisons now start in nearest and
toward-zero caller rounding modes and check their restoration. Execution itself
always selects the console's toward-zero mode; these are not two different VU
arithmetic modes. The timed image
`650795E6440917576E0A1709AF0D79AAC49F0F29BF4CCC4747B9F2170EB480F7`
passes 143/143 VU tests and both private captures at normal/1/8/16/64-cycle
budgets, with identical digests, cycle counts and native/interpreted coverage.
The helper test also passed before enabling the runtime path.

Seven alternating comparisons against accepted packed-product code with the
new helper test but no runtime hook, comparator SHA-256
`A21CC04F90BB9F1EA463E885AAD4F6E44030141D865D41DF47C61C5091B21ACE`:

| Capture | Repeats | Baseline ms | Packed ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 1744.672 | 1654.873 | 5.147% | 7/7 |
| Spread | 2048 | 1474.394 | 1392.689 | 5.542% | 7/7 |

These are VU execution-only measurements, not whole-game FPS gains. The fixed
comparison JSON now contains spread results. In the final PE (timestamp
`0x6a9cf26c`), a native MADD apply path at RVA `0x2eb670` uses `vcvtps2pd`,
`vmulpd`, then `vaddpd`, followed by one packed normalization call at `0xd0f90`.
It retains widened non-fused arithmetic and replaces per-lane scalar classifier
calls. This depends on local native specialization, so it is not a standalone
upstream PR. Game integration is checked separately below.

The candidate links successfully with the existing duplicate raylib symbol
warnings: SHA-256 `BF9DED00BE2E4387B2DEF8640EF8A36D62781B4C9F9519FE26FA88A84F74037F`,
163,360,768 bytes, PE32+ x64, timestamp `0x6a9cf309`. At 2026-09-06T05:02:40Z,
the unprofiled first-level check exited 0 at vsync 1400 and passed every workload
gate. It executed 788,701,403 native block pairs. Presents 1152/1280 arrived at
172.774036/199.8058014 seconds: 128 frames in 27.0317654 seconds, **4.73517 FPS**;
total runtime 208.0320801 seconds. Host input was disabled, startup restored,
and the process closed. No invalid guest address was logged in this run.

The newly written runtime-owned present-1280 frame was inspected in the reused
PPM/PNG slots. Textured NYC/Wolverine and the known black props, absent foliage,
red player disk and malformed HUD remain. No visual fix or fresh movement/combat
test is claimed. The preceding 4.63 FPS run is a shared-host observation, not a
controlled baseline for this game result. Practical playability remains unmet.

`152b089` adds explicit caller-rounding restoration assertions to the expanded
arithmetic test. Final test SHA-256
`784D74F1BF49C65E9B863E14A2F85CB56DC6629F825EFCF7043F3AB45FDFF2E9`
again passes 143/143 tests and all ten replay/budget checks. This test-only
change does not alter the measured game candidate or the runtime optimization.

The fixed execution profiles were refreshed after this final test link, so
their matching map timestamp is now `0x6a9cf474`, not the earlier arithmetic
or pending-clear maps. Three 2048-repeat runs per capture produced 638 original
samples (5 external, 633 mapped) and 269 spread samples (5 external, 264 mapped),
with zero drops/failures and exact replay. Sampling excludes setup/serialization.

| In-module family | Original | Spread |
| --- | ---: | ---: |
| Instruction execution | 27.01% | 28.03% |
| Other VU execution | 22.91% | 32.20% |
| Native block bodies/guards | 20.22% | 12.50% |
| Pipeline retirement/advance | 14.38% | 14.39% |
| FMAC flag helpers | 10.58% | 10.61% |

The individual `run` symbol has 46/33 hits (7.27%/12.50%); generic pipeline
retirement has 34/23 (5.37%/8.71%), and pair-readiness scanning has 25/15
(3.95%/5.68%). Packed normalization has 36/8 (5.69%/3.03%). These are coarse
VU-only sample shares, not whole-game time or new timing comparisons. Next
inspect the matched hot instructions in `run` and its fallback/scheduling path
to remove repeated work at a larger granularity. Do not infer that flags can
be discarded, repeat rejected by-reference decode/queue-index experiments, or
broaden the kernel selection based only on execution counts.

## Packed Product Sticky Flags

`cb58d43` evaluates the four product lanes together when native VU arithmetic
is compiled with MSVC x64/AVX2. Operands are already normalized; products are
widened before multiplication, then classified for zero/sign/underflow/overflow
and reduced over the destination mask. Broadcast, Q/I, vector and cross-product
operand selection follows the existing scalar path. Current-result arithmetic,
flag queuing, pipeline deadlines and the scalar interpreter are unchanged.
Other builds retain the existing scalar implementation.

The standalone regression checks 12,800 input/mask/rounding combinations,
including signed zero, minimum/maximum values and randomized finite operands.
Volatile widened inputs prevent the /fp:fast scalar test oracle from narrowing
its multiplication. Both nearest and toward-zero modes are covered. Existing
native arithmetic boundary replays compare full serialized state against the
unchanged interpreter; both game captures remain exact at normal/1/8/16/64-cycle
budgets. Final test image `0EB3EFC0B0D15F3E32161E939F0E03D644CCE86B2E7E0359708646A2739AB2D3`
passes 142/142 VU tests and all ten capture/budget checks.

Seven alternating uninstrumented comparisons:

| Capture | Repeats | Baseline ms | Packed ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 1974.443 | 1817.065 | 7.971% | 7/7 |
| Spread | 2048 | 1499.442 | 1448.099 | 3.424% | 7/7 |

Comparator slot now holds accepted `1229e5f`, SHA-256
`B4C96193B519A08B3E2F7584DC44C7EB3D7B068D6E90EF57C8D1FDC923B82D40`,
not older `A7070757...`. Timed candidate was `704D93632F731C96207F063D0D8987B349D696346D6C1E272ED9627435D07015`;
the subsequent test-only rounding expansion produced the final image above.
Disassembly of the timed helper (timestamp `0x6a9cedd9`, RVA `0xd0f90`) shows
`vcvtps2pd` before `vmulpd`, followed by packed double comparisons and lane-mask
reduction. These are VU-only timings, not game FPS improvements.

This native-specialized path does not exist in current upstream main, so it
is not submitted as an unused helper or a dependent grab-bag PR. A general
interpreter adaptation would need its own normalization, correctness and
performance checks. Existing PR #252 remains the standalone pending-clear change.

### Game Integration Checkpoint

The linked candidate SHA-256 is
`77736D945AF593A6BE4DF2380863D3D3184D7C9035712F2F9CF3EDF6E4441280`.
The initial integration attempt did not reach the measurement window and logged
an invalid guest PC `0x4c004000` after present 640. The user reported closing the
window and requested a restart. That observation does not establish the cause
of the logged guest fault; keep it as an unresolved interruption-time finding,
not proof of either an arithmetic regression or a clean shutdown.

The requested rerun completed at 2026-09-06T04:49:25Z with exit 0 and vsync 1400.
The New Game handler, NYC level package, 785,009,483 native block pairs, and both
timing markers were verified. Presents 1152 and 1280 arrived at 178.8528643 and
206.4986906 seconds: 128 frames in 27.6458263 seconds, approximately **4.63 FPS**.
This is shared-host timing, not a controlled whole-game speedup claim against
the earlier 4.38 FPS run. Phase/coverage profiling and host input were disabled.
The invalid-address failure did not recur, and startup scripts were restored.

The current runtime-owned present-1280 dump was inspected: NYC geometry and
Wolverine render, but black props, missing foliage, the solid red player marker,
and malformed/white HUD elements remain. This was a timed integration check,
not a fresh interactive movement/combat validation. The test process has exited;
the gameplay goal remains incomplete. Next work should prioritize responsiveness
and reliable player control, with the interruption-time fault retained for
investigation if it recurs. No SFD work is required for this checkpoint.

## September 6 Arithmetic Rejection And Profile

The exact FMAC helper-inline experiment (`3b728bb`) passed all 140 VU tests
and both captures at normal/1/8/16/64-cycle budgets, but was slower in matched
seven-round alternating tests against accepted comparator `A7070757...`:

| Capture | Repeats | Baseline ms | Inline ms | Regression | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 1970.423 | 2141.593 | 8.687% | 0/7 |
| Spread | 2048 | 1999.975 | 2199.185 | 9.961% | 1/7 |

`e0abe98` removes the experiment. No game executable contained it. Restored
test image SHA-256 `98665AEB795D9C2240D9DED0A356296E4069B2A452C10F154D7DF477A26B13AD`
passes all 140 tests and ten capture/budget checks. The fixed comparator
remains `A7070757320A690E255846B8702C6C8785BB8B133435E569E620D2F49BDE6677`.

Refreshed `execution-profile-original.*` and `execution-profile-spread.*`
now belong to restored image `98665AEB...`, map timestamp `0x6a9ce90f`.
Each aggregates three execution-only runs of 2048 repeats. Original totals:
774 samples, 16 external, 758 in-module. Spread: 322 samples, 6 external,
316 in-module. All samples resolve, with zero drops/failures and exact replay.
These replace the pre-XGKICK-optimization profiles described below.

| In-module family | Original | Spread |
| --- | ---: | ---: |
| Instruction execution | 23.09% | 21.84% |
| Other VU execution | 21.24% | 27.22% |
| Native block bodies/guards | 20.71% | 16.14% |
| Pipeline retirement/advance | 17.02% | 22.15% |
| FMAC flag helpers | 14.51% | 10.76% |

The previous external copy hotspot is absent: original has one VCRUNTIME
sample, spread none. Remaining external samples are mostly UCRT sign helpers.
Sample shares guide investigation, not game-frame timing claims. Matched
disassembly shows repeated aggregate-zero stack construction and reloads in
pending VF/VI/ACC/store retirement and enqueue paths. Test direct clearing
there while preserving every field, deadline, mask and issue-order check.

## Direct Pending Entry Clearing

`280147c` clears pending VF/VI/ACC/store and scalar entries in place instead
of assigning an aggregate temporary. Both interpreted and compiled-block
enqueue/retirement paths keep all field values, readiness tests, slot order,
write-sequence checks and lane masks. A compile-time check confirms positive
float zero has the all-zero representation used by these entries.

Test image `79F54B78AF4C79FF21037B29F686DF780D35D53E5EEF12F4B92823A5C6A881F8`
passes 140/140 VU tests and both captures at normal/1/8/16/64-cycle budgets.
Recorded states, memory, packet data/cycles and replay digests remain exact.
Matched disassembly confirms aggregate zero temporaries are gone. General
retirement shrinks from 1648 to 1488 bytes, native VF retirement from 416 to
368, and native store retirement from 288 to 256. Partial-store merging still
uses its required data temporary; only zero-initialization copies were changed.

| Capture | Repeats | Baseline ms | Direct clear ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 2120.947 | 2049.752 | 3.357% | 7/7 |
| Spread | 2048 | 1637.766 | 1532.869 | 6.405% | 7/7 |

These seven-round alternating VU-only comparisons use unchanged `A7070757...`
as the baseline and do not establish game FPS. The fixed profile logs still
belong to pre-clear restored image `98665AEB...`; do not map them using the
new executable's linker map.

The updated game candidate SHA-256 is
`67C66DEBBB0286EC4A90EF40AC459FB4465CE91A68D99E6CD330919F624835BB`
(163,363,840 bytes, PE timestamp `0x6a9ceab1`). At 04:27 UTC it completed the
real New Game/NYC test, exit 0 at vsync 1400. Presents 1152/1280 arrived at
188.4271364 / 217.6270008 seconds: 128 frames in 29.1998644 seconds, 4.38358
FPS. Total 231.2623991 seconds, 775,779,683 whole-run native block pairs.
This shared-host observation is not a controlled gameplay gain. Runtime-owned
present 1280 still shows the known prop/foliage/HUD/player-effect defects.
The game closed and startup was restored; primary/staged binaries are unchanged.

Standalone [PR #252](https://github.com/ran-j/PS2Recomp/pull/252) is `1e73f01`,
based directly on upstream `14b1e5c`, without the local compiled-block path.
All 426 upstream-based tests pass before and after the change. Its additional
regression checks all 16 masks, raw signed-zero/NaN/infinity/subnormal bits,
and VF/VI/store visibility one cycle at a time. Baseline test image:
`95EB3AFA64C7291991D8DE152C07A12F46422740B76FE11CD382117B83DA897D`;
optimized: `F9B6B95759521479A49D56849A294811EE37D793D9D14A5ECEF9EA12FF2DF53A`.
The first test draft passed the budget in the TOP argument slot; that fixture
error was corrected and cycle-count assertions added before either passing run.

The same regression is retained locally. Final test image
`B4C96193B519A08B3E2F7584DC44C7EB3D7B068D6E90EF57C8D1FDC923B82D40`
passes 141/141 VU tests and all ten capture/budget checks. This test-only
addition does not alter the integrated game executable or the recorded timing
results. All owned build/test/game processes are terminal. Existing artifact
slots were reused; workspace remains about 8.000 GiB with no old disc images
eligible for the 12-hour cleanup threshold.

## XGKICK Storage Reuse

PS2Recomp `304e2a1` removes a 64 KiB temporary clear and copy from each
`startXgkick` call. Packet bytes remain in allocated storage; all transfer
metadata is reset, and `progressXgkick` overwrites each qword before increasing
the copied prefix. Transfer timing, packet lengths, state serialization, and
the reset/initialization path are unchanged.

The new regression sends 4096-, 32-, and 80-byte packets consecutively. It
checks every output byte and exact lengths, then compares serialized final
state across 4096/1/3/8/64-cycle budgets. It passes before and after the change.
The optimized image passes **139/139 VU-related tests** and both private captures
at normal and 1/8/16/64-cycle slicing, with unchanged digests/cycles/coverage.

Seven alternating, uninstrumented comparisons:

| Capture | Repeats | Baseline ms | Optimized ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 2727.913 | 2305.994 | 15.467% | 7/7 |
| Spread | 2048 | 2106.688 | 1734.131 | 17.684% | 7/7 |

The reused comparator slot now holds test baseline
`72653FAE930438FB5EBE21A95FA5A8980AF26F94FBCF58B0060B612F5D3402E4`.
The optimized test executable is
`F056E7FE393773086A3A91D3CCF86D46F4729AD290B9AD8497CCD68C1D2A3154`,
map timestamp `0x6a9ce024`. Binary inspection confirms that `startXgkick` no
longer calls memset/memcpy or reserves the old approximately 64 KiB stack frame.
The fixed comparison JSON contains the spread series. These are VU-only
measurements, not an FPS improvement claim.

### Integrated Gameplay Check

The opt-in candidate now includes `304e2a1`: SHA-256
`13715A67FF82743E96E8F9805A4E69696AEB5AE0868669D35FC5F4F91A3685F2`,
163,368,448 bytes, PE32+/x64 timestamp `0x6a9ce0d6`. Primary and staged hashes
remain unchanged. Linking used BelowNormal/one worker/affinity 0xF and retained
the existing duplicate raylib/User32 symbol warnings; successful startup and
normal exit were checked, not inferred from linker exit alone.

`run-gameplay-benchmark.ps1 -CaptureFrame` completed at 2026-09-06 03:46 UTC,
exit 0 at vsync 1400, with real New Game/NYC load and native blocks verified.
Presents 1152/1280 arrived at 216.9667881 / 248.4600351 seconds: 128 frames in
31.493247 seconds, **4.06436 FPS**, total 261.275584 seconds. Startup scripts
were restored and the owned process closed. The prior user-requested older
candidate rerun completed at 03:30 UTC at 3.71035 FPS. Shared-host timing and
different whole-run native-block counts preclude treating this pair as a
controlled FPS improvement: 630,871,823 block pairs now, 340,133,123 before.

The reused native `gs-present-1280.ppm`/PNG was inspected: textured New York,
Wolverine, fences, and yellow marker are present. Black props/missing foliage,
the solid red player disk, and malformed HUD/potion glyphs remain. Repeated
null-page memset warnings also occur in the older phase log; they are not new
evidence of an XGKICK regression. Practical playability remains unmet.

### Upstream Submission

[PR #251](https://github.com/ran-j/PS2Recomp/pull/251) is open, commit `9649cf4`
on `codex/vu-xgkick-storage`, based directly on upstream `14b1e5c` in the
existing `C:/Programming/GitHub/PS2Recomp` checkout. Its two-file diff contains
only the metadata reset change and a standalone synthetic test. No local
sampler, replay machinery, private kernels, or game data are included.

The upstream regression verifies full packet bytes and completion cycles
511/514/523 at all five budgets. Upstream resume has no persistent `isRunning`
API and can continue after a halted program; the test therefore stops when
all three packets are delivered instead of issuing an extra resume after halt.
The initial incompatible test assumptions were corrected before validation.

Release full suite: **426/426 pass** both with the new regression and original
runtime (test SHA `A3114F04D77002F216FEBBBC94FA3EEE9E04515951D58478A2177F3613CABE06`)
and after the optimization (`DE7184B9EC61652C23EB05D6E75538B2D42FC3726CA278EBAC8591CAB5173CE9`).
All builds stayed BelowNormal, single-worker, affinity 0xF, 2048 MiB compiler
cap. Existing build/log/executable/image slots were reused; final OpenXML1
inventory is 8.004 GiB / 30,327 files. No owned test/game process remains.

### External Sample Attribution

PS2Recomp `49347fe` adds bounded external module/RVA sampling to the test
harness only: at most 64 module identities and 4096 external addresses.
Metadata resolution occurs after resuming the target thread; no allocation,
logging, or loader calls happen while it is suspended. Unresolved and dropped
samples are explicit. Two tests cover live module resolution, private-memory
rejection, identity separation, capacity limits, and repeated hits at capacity.

`summarize-vu-sampler.ps1 -External -All` reports DLL path, PE timestamp/image
size, RVA, hits, and shares of external/all execution samples. Tests cover
module-ID reuse between runs, image mismatch, range/accounting errors, and
partial attribution. The ordinary in-module report still requires a matching
linker map and now rejects mixed image timestamps throughout a combined log.

The fixed `execution-profile-original.*` and `execution-profile-spread.*` logs
currently describe the **pre-optimization** sampler image
`06542E8302735645F0F9E21B93C179AD3C58877E9E34A6FAB486014198836B03`,
not the latest linker map. Three 2048-repeat runs per recording all remain
exact, with zero failures, dropped samples, or unresolved external samples:

| Capture | Execution samples | External | VCRUNTIME140 | ucrtbase |
| --- | ---: | ---: | ---: | ---: |
| Original | 1042 | 138 | 118 (11.32%) | 20 (1.92%) |
| Spread | 380 | 62 | 56 (14.74%) | 6 (1.58%) |

Percentages use all warm-execution samples. Matching DLL binaries identify
`VCRUNTIME140.dll` timestamp `0x4260df93`, image size `0x1e000`, and
`ucrtbase.dll` timestamp `0xc38f7a35`, size `0x14c000`. Disassembly finds the
dominant copy helper at RVA `0x1065b` (`rep movsb`) and memset stores around
`0x12814`; ucrtbase samples are mostly `_dsign`/`_ldsign` at `0x83190`.
The sampled IPs alone do not identify callers. Inspection of `startXgkick`
independently established the redundant bulk work, and the alternating
comparison above verifies that removing it benefits both recordings.

Older checkpoint sections below are historical; their references to current
binary slots or fixed profile logs must not supersede this section.

## Direct Deferred Output Rejected

The next experiment redirected compiled upper VF results into their pending
write slot, avoiding writes to the live VF bank followed by copy/restore.
Inactive lanes were initialized from the original register. Same-pair lower
reads retained the old bank, and suppressed lower writes still executed their
integer/address side effects before the old VF value was restored.

Experimental test image
`F07212539420F86C670AD955532B41A6C91ECFC271D389908DF157544CD16137`
passed 136 VU tests and both captures at normal/1/8/16/64-cycle budgets, with
unchanged cycles, digests, and block coverage. Comparator
`A66D5E855A30F810A6AB45CC77FBEAB712D70FE69101EB1001A4E51ED523A6D7`
was the accepted runtime plus the previous aliasing test. Seven alternating
comparisons per row gave:

| Capture | Repeats | Baseline ms | Experiment ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original, first series | 1024 | 3054.288 | 3080.983 | -0.874% | 4/7 |
| Spread | 2048 | 2233.983 | 2174.451 | 2.665% | 6/7 |
| Original, repeat | 1024 | 2324.312 | 2362.387 | -1.638% | 2/7 |

The broader recording improved modestly, but the original recording repeatedly
did not. The optimization was removed rather than integrating a mixed result
into gameplay. A binary check of two entry wrappers found unchanged primary
range sizes/call counts; it did not establish the slowdown's cause. No game
executable contained this experiment. The fixed comparison JSON retains the
last original-capture series.

Retained coverage adds one public two-pair block at 0x3700 and 112 cases across
16 inputs and seven initial budgets, each followed through one-cycle snapshots
and retirement. It checks an old-value SQ paired with ADD.x, followed by FTOI4.y
and a suppressed LQI reading deliberately different data through another base
register. The load must increment its base but cannot leak its VF result;
inactive lanes and integer bit patterns are checked independently. Initial
same-address test data could have concealed an overwrite, so it was corrected
before the final experimental verification. There are now 27 total blocks
(11 public synthetic, unchanged 16 private) and still 67 pair kernels (64 private).

PS2Recomp `de8b54a` retains only the synthetic block and regression test.
The restored runtime's test image is
`09BF14A27C3D58AF9ECB9461092ADB2E469BDF78548B595398951D902F9DEE81`.
All 136 VU tests and both captures at all five budgets pass after restoration.

### Refreshed Execution Profiles

Three execution-only sampled runs per capture, each with 2048 repetitions,
reuse `execution-profile-original.*` and `execution-profile-spread.*`.
All runs retain exact results; every image and the current linker map has
timestamp `0x6a9cdb48`. No dropped samples or capture failures were reported.
The unsuffixed `execution-profile.*` remains historical and does not match this
image. Profile timings are instrumented and must not be used as FPS evidence.

`summarize-vu-sampler.ps1 -All` now returns all attributed symbols; its default
Top behavior is unchanged and both modes are tested. The former top-100 output
omitted 180 original and 28 spread samples. All-symbol totals now reconcile:
237 symbols / 952 in-module samples on original, 128 / 386 on spread.

| Symbol family | Original hits / in-module share | Spread hits / in-module share |
| --- | ---: | ---: |
| Pipeline queues and retirement | 208 / 21.85% | 112 / 29.02% |
| Upper/lower instruction helpers | 237 / 24.89% | 87 / 22.54% |
| FMAC flag helpers | 137 / 14.39% | 53 / 13.73% |
| Other compiled block code | 247 / 25.95% | 66 / 17.10% |
| Other VU execution | 102 / 10.71% | 61 / 15.80% |
| Other | 21 / 2.21% | 7 / 1.81% |

Families group sampled instruction pointers by symbol name and, for opaque
compiled-block symbols, source object. They are not call-stack/inclusive costs
or whole-game time shares. Original recorded 1114 execution samples, including
162 external (14.54%); spread recorded 505, including 119 external (23.56%).
The sampler counts but does not identify those external addresses. Next close
that attribution gap with bounded process-local module/RVA reporting before
choosing another larger execution change. Preserve exact pending state; the
flag-liveness reference below is not permission to omit sticky flags.

## Interpreted Operand Reuse Rejected

The September 5 follow-up tested passing `execUpper`'s normalized VF/ACC/Q/I
snapshot to the dynamic FMAC flag helpers, as the native kernels already do.
The attempted implementation also guarded widened flag arithmetic with MSVC
precise floating-point semantics. Experimental test image
`D43D66CB731564E506EA8EE485276A857E58CD9EA72596277BD13F0A33D8CC3E`
passed 135 VU tests and both captures at normal and 1/8/16/64-cycle budgets.

Seven alternating comparisons against accepted `053b1bc` test image
`78076FBB69E84003A4C1C1B406C196413BFB43FAB8C7313992FC9DF74C91BFBB`:

| Capture | Repeats | Baseline ms | Experiment ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original | 1024 | 3428.418 | 3556.435 | -3.734% | 1/7 |
| Spread | 2048 | 2822.932 | 2732.752 | 3.195% | 2/7 |

These shared-host timings were noisy. The positive spread median is not a
consistent paired improvement: the experiment lost five of seven adjacent
comparisons there and six of seven on the original capture. With no reliable
benefit demonstrated, all three runtime source changes were removed. No game
executable ever contained the experiment. The existing comparison executable
slot now holds the accepted `78076F...` image; earlier identities are historical.

The retained regression test independently checks 288 combinations: six
MADD/scalar/cross-product/ACC forms, every lane mask, and three destination
registers including either input. It checks numeric results, untouched lanes,
MAC flags, and product sticky flags. No private instruction words were added.
PS2Recomp `711d5d2` contains this test only. The restored-runtime image
`A66D5E855A30F810A6AB45CC77FBEAB712D70FE69101EB1001A4E51ED523A6D7`
passes all 135 VU tests, both captures at all five budgets, and the two existing
budget-trace fixtures. The rebuild used BelowNormal, one worker, affinity 0xF,
and the 2048 MiB compiler cap.

The user-requested rerun of the unchanged `CE26EA1E...` game candidate completed
at 2026-09-06 02:43 UTC, exiting 0 at vsync 1400 with New Game, NYC loading, and
native blocks verified. Presents 1152/1280 arrived at 205.8493978 / 256.7630483
seconds: **2.5141 FPS** over 128 frames, total elapsed 283.8631807 seconds.
The wrapper restored the startup package. This supersedes the fixed
`gameplay-rate.*` report, not the earlier native framebuffer inspection. No new
gameplay image was requested and no host input was sent.

## Budget Trace Initialization

PS2Recomp `053b1bc` removes two unconditional clears of the 2,432-byte local
budget-trace array in `VU1Interpreter::run`. The matched pre-change binary
contained a `memset(0x980)` followed by an array-initialization helper on the
ordinary diagnostics-off path. The final binary contains neither. Every trace
entry is fully written before its count-limited reader can access it; this does
not change guest instructions, cycle timing, queues, or selected kernels.

The normal test image is
`78076FBB69E84003A4C1C1B406C196413BFB43FAB8C7313992FC9DF74C91BFBB`.
All 134 VU tests and both captures at normal and 1/8/16/64-cycle budgets pass.
`tests/test-vu-budget-trace.ps1` also launches two headless, process-local
fixtures with diagnostics enabled: budgets 3 and 40. It checks every retained
PC, opcode pair, and signed VI register value, including 32-entry ring wrap.

Seven alternating comparisons against `633cf92` test image
`2F9FA03552A04BC007AE7B376F676ABDFD2208ED8D3473AAA7D7EBCEDDCEC6B7`:

| Capture / slice budget | Repeats | Baseline ms | Candidate ms | Reduction | Wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Original / normal | 1024 | 2334.653 | 2315.661 | 0.813% | 4/7 |
| Spread / normal | 2048 | 2007.371 | 1960.860 | 2.317% | 5/7 |
| Original / 8 cycles | 512 | 2060.460 | 1912.508 | 7.181% | 7/7 |
| Spread / 8 cycles | 1024 | 1711.016 | 1626.306 | 4.951% | 5/7 |

`compare-vu-blocks.ps1 -SliceCycles 8` sets the same budget on both processes
and records it in the fixed comparison report. Normal-budget gains are small;
shorter slices expose repeated-call overhead but are not a substitute for the
game's actual workload mix. These numbers are not gameplay FPS improvements.

The subsequent opt-in game relink contains `053b1bc`, SHA-256
`CE26EA1E3D4586D61D6AFA855AD76E625174C9703965669CD155386C35488DAB`,
163,364,352 bytes. Its unprofiled run verified real New Game/NYC loading and
normal exit at vsync 1400. Presents 1152/1280 arrived at 193.0931207 and
225.2273819 seconds: **3.9833 FPS** over 128 frames. The runtime-owned framebuffer
still shows textured New York/Wolverine with the existing black props, missing
foliage, and HUD/effect defects. This is not a meaningful measured gameplay gain
against the earlier 4.14 FPS sample. Startup files are restored, the process is
closed, and saved primary/staged images remain unchanged.

## Residual Pair Profiling

The optional `PS2X_ENABLE_VU_PAIR_PROFILE` CMake switch adds diagnostics only to
the VU core and replay source files. It defaults to OFF; ordinary builds have
no per-pair collection hook. Build with the usual BelowNormal wrapper:

```powershell
& ./xmen-legends/build-below-normal.ps1 -ConfigureCache @('PS2X_ENABLE_VU_PAIR_PROFILE:BOOL=ON')
& ./xmen-legends/build-below-normal.ps1 -Target ps2x_tests
```

Use the replay setup below, enable `PS2X_VU_REPLAY_PAIRS=1` and
`PS2X_VU_REPLAY_BLOCKS=1`, and set `PS2X_VU_REPLAY_RESIDUAL_EXPORT` to an absolute
CSV path inside the ignored `disc` directory. The CSV contains decimal
`pc,lower,upper,native,interpreted` fields. **Keep it private:** these are retail
instruction words. A normal-budget export must leave
`PS2X_VU_REPLAY_SLICE_CYCLES` unset. Neither upper nor pair one-cycle export may
be enabled with this diagnostic; conflicting requests fail explicitly.

Collection observes the first replay pass at the same cycle budget as normal
execution. It counts only instructions actually issued outside successful
compiled blocks, after dependency waits. A pair's PC and both words form its
key, so different microprograms at the same address are not merged. The scoped
collector excludes warm repetitions and other VU owners; 4,096 unique keys is
the hard storage limit, and overflow fails verification rather than silently
truncating the profile. Warm replay still checks exact state, data, and packets.
The export test reconciles cold native/interpreted counts against the complete
execution counters, subtracting compiled-block pairs.

With 64 private pairs and the unchanged 16-private-block weighted selection:

| Capture | Residual PC/word keys | Native residual pairs | Interpreted pairs |
| --- | ---: | ---: | ---: |
| Original, normal budget | 322 | 6,578 | 1,265 |
| Spread, normal budget | 389 | 1,976 | 3,993 |
| Original, one-cycle budget | 425 | 30,895 | 8,598 |
| Spread, one-cycle budget | 486 | 9,663 | 5,719 |

These are cold-pass counts. The one-cycle results illustrate why tracing by
shrinking budgets is not a faithful measure of normal block fallback.
The instrumented image `5C5E7D0039CE3970A889B67F2E66B95BCC5B5BBEC6B24B0511EAFB1F49D75E93`
passes all 133 VU tests and both recordings at normal and 1/8/16/64-cycle budgets,
including counter reconciliation. Conflicting export modes are rejected.

Aggregating by instruction words and giving each capture equal normalized
weight predicts that a 64-word selection could cover 6,831 original and 3,753
spread residual pairs, compared with 6,578 and 1,976 today. That would replace
42 currently selected words. That selection has now been implemented and
**rejected on timing**, despite matching the predicted coverage.

`select-vu-residual-pairs.ps1` accepts `-ProfilePath` CSV files and `-RecipePath`,
optionally writing a private `-OutputPath`. It aggregates matching words across
PCs, weights each capture equally, and deterministically ranks ties by words.
`-Limit` controls the selected-set coverage report; the recipe retains the full
ranking and CMake's private-pair limit controls compilation. Only word-selection
lines change; block definitions, PC hit weights, provenance, and edges retain
their original order. The memory-only regression suite checks weighting, ties,
metadata preservation, malformed fields/columns, duplicates, and bounds.

The rejected recipe `disc/vu-native-pairs-residual.inc` has SHA-256
`297DBE13E21D77535A28155D3D89F719006E4955600E6D5C8710551B736FF7F0`;
test image `593A7B1CDE386330256E458F5ED0287BB3584D479FC8544E91F9BCDD343C4044`
passed all 133 then-current VU tests and both sliced captures. All 26 generated
block bodies and their dispatcher were byte-identical. Normal native/interpreted
counts were 78,170 / 2,024 original and 26,602 / 4,432 spread (cold plus one repeat).
Seven alternating comparisons against `2F9FA035...` measured
2294.803 / 2338.945 ms original (1.924% slower) and 1963.659 / 1980.650 ms spread
(0.865% slower), two wins of seven each. Tiny budgets also lost substantial
native-pair coverage when blocks could not execute. The original weighted
64-pair / 16-block selection is restored. No game build used the rejected recipe.

The preceding 64-to-128 private-pair experiment was rejected: seven alternating
comparisons measured 2516.006 / 2592.948 ms on original and 2046.555 / 2120.754 ms
on spread (3.058% and 3.626% slower, one win of seven each). All then-current
131 tests and both sliced replays passed, but normal interpreted counts only
fell from 2,530 to 1,100 on original and 7,986 to 7,260 on spread across the two
passes. Block coverage did not change. The game was never relinked with 128.
The comparison slot `ps2x_tests.flag-pack-base.exe` now holds accepted `955b393`,
SHA-256 `7DDD7C0294EEE2B785AE8CC3E9475AB07EF76F24855F056782C3329561CEE4BA`.
Older identities elsewhere in these notes describe historical comparisons.

After profiling, restore `PS2X_ENABLE_VU_PAIR_PROFILE:BOOL=OFF` and rebuild the
test target before timing. Do not compare an instrumented image against an
uninstrumented baseline or infer whole-game FPS from these instruction counts.

The final restored normal build is
`2F9FA03552A04BC007AE7B376F676ABDFD2208ED8D3473AAA7D7EBCEDDCEC6B7`.
It passes all 133 VU tests and both captures at normal and 1/8/16/64-cycle
budgets, with unchanged pair/block counts. A residual-export request is
explicitly rejected when profiling is not compiled in. All three gameplay
executables remain unchanged.

## Capture

Set `PS2X_VU_REPLAY_CAPTURE` to an absolute path inside the ignored extracted-disc
directory before launching a guarded first-level probe. The recorder samples
after guest vsync tick 1100, retaining at most 16 short slices (budgets up to 64
cycles) and 16 longer slices. Both classes use deterministic 1-in-256 sampling,
with at least four guest ticks between records in the same class. A filled quota
therefore spans at least 60 ticks instead of taking its first 16 eligible slices.
The complete file is capped at 4 MiB; individual records are capped at 1 MiB.
Recording is disabled when the environment variable is absent.

Probe 2262 created `xmen-legends/disc/vu-replay.bin`: 32 cases, 1,914,088 bytes.
It reached present 1200, closed under the guard, and restored the startup archive.
All 32 records in this original capture have tick 1100 and the same code image.
Keep it as the established correctness oracle, but do not treat its workload
mix as representative of the complete level. New spread captures use a separate
ignored file so they cannot overwrite the original regression input.
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

The game runner also accepts `PS2X_VU_NATIVE_BLOCKS=1` when built with
`PS2X_ENABLE_VU_NATIVE_BLOCKS=ON`. `PS2X_VU_NATIVE_PAIRS=1` enables compiled-pair
fallback outside those blocks. Both modes remain off when their variables are
absent, and their post-join counters distinguish actual execution from simply
selecting a mode.

`measure-gameplay.ps1 -Probe <unused-number> -Mode Blocks` runs the separate
`ps2EntryRunner.candidate.exe` through the real New Game handler, observes
native present-log indices 1152-1280, and requests a normal stop at tick 1400.
Use `-Mode Interpreted` with another unused probe number for a same-executable
baseline. The helper clears inherited experimental variables, disables host
input and profiling, keeps full CPU rasterization, and uses the guarded movie
bypass/restoration path. It rejects missing framebuffers, absent execution
counters, changed executables, abnormal exits, and missing/coalesced timing
endpoints. Each mode overwrites one small ignored `disc/gameplay-<mode>-rate.json`
report. These external wall-time samples are not deterministic frame comparisons
or a sustained-speed guarantee.

The September 4 runner integration is not yet live-validated. All 107 runner
compilation units first succeeded with global IPO enabled, but the linker exceeded
the 2048 MiB process limit both normally and with `/CGTHREADS:1`. The guard stopped
both links. `PS2X_ENABLE_RUNNER_IPO=OFF` permits disabling IPO on the generated
game target while leaving the runtime and native kernels optimized. Its default
is ON, preserving existing build behavior. On September 5, the active OFF cache
completed a fresh 107-unit rebuild with `/O2`; an audit found no `/GL` or feature-
define mismatches. The `/CGTHREADS:1` link then succeeded under the unchanged cap,
producing complete PE `ps2EntryRunner.candidate.exe`. The latest relink after
entry-stall support has SHA-256
`CBA24C9E8B38ABBC6D17B5769FF441812E0746EED5B5317D1DD82091E9028119`.

Resource-limited reconfiguration is available through:

```powershell
& .\xmen-legends\build-below-normal.ps1 -ConfigureCache 'PS2X_ENABLE_RUNNER_IPO:BOOL=OFF'
& .\xmen-legends\build-below-normal.ps1 -Target ps2_runtime
& .\xmen-legends\build-below-normal.ps1 -CompileOnly
& .\xmen-legends\build-below-normal.ps1 -LinkOnly -OutputName ps2EntryRunner.candidate
```

The earlier failed link left `ps2EntryRunner.profile.exe` as an incomplete 2 MiB file.
Its removal was policy-blocked; do not retry deleting or moving it. It is not a
runnable fallback. The primary and staged executable hashes remain unchanged.
The new measurement helper validates PE headers and section extents before
starting a run. Probes 2269/2270 used the same validated executable and both
reached textured first-level gameplay before exiting normally at tick 1400.
Across presents 1152-1280, native blocks measured 33.7064 seconds / 3.7975 FPS;
interpreted mode measured 37.7803 seconds / 3.3880 FPS. That is about a 12.1%
frame-rate gain in this controlled pair, not a sustained-speed guarantee.

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

A broader block-exit materialization candidate routed block FMAC and CLIP output
through local flag arrays, scheduled only exact entry-state flag/VF retirement
slots, and copied just the still-pending tail flags back to the architectural
pipeline. Public `PS2VU1` passed 53/53 and all 32 captures remained exact at
40,803 cycles and digest `75d4ff1e67bbbc4c`. It nevertheless lost all seven
alternating 1024-repeat rounds: the accepted build measured 3,265.104 ms and the
candidate 3,453.661 ms at the median, a 5.775% regression. The implementation
was removed. Future block work must generate direct state transitions without
building runtime schedule arrays or copying pipeline entries on the stack.

## Blocks During PATH1 Transfers

Temporary per-entry counters found 1,352 block attempts with active PATH1
transfers at 0x18c8, 0x1908, 0x1948, 0x1968, and 0x19a0. Those transfers were a
measured fallback cause; duplicate compiled suffixes alone do not explain the
lost coverage. Entry 0x0b80 also failed 210 attempts with a pending VI write.
PS2Recomp `e793e41` now retires such pre-existing delayed VI writes at their
original cycle inside a native block, while its readiness model still rejects any
read before the value becomes available. A public synthetic regression stages a
four-cycle ILW immediately before a compiled loop and verifies exact resumed
state and data.

PS2Recomp `6ce7a2a` advances an existing PATH1 transfer after the block's
architectural writes at each original cycle boundary. A block may consume the
already parsed packet payload, including completion of an EOP packet. It falls
back if it would need to parse another GIFtag, because malformed input could
stop execution before the block's assumed exit. This retains store visibility,
partial packet bytes, and original delivery cycles.

Coverage increases from 49,182 to 56,582 of 80,194 retired pairs (70.56%). Seven
alternating 1024-repeat comparisons measured 3,258.914 ms baseline / 3,118.863 ms
candidate at the median, a 4.297% reduction with seven candidate wins. Both
comparison binaries had the same temporary diagnostic hooks with reporting off;
those hooks were removed afterward. The final build passes 54/54 public PS2VU1
tests, and the 32 gameplay captures retain 40,803 cycles and digest
`75d4ff1e67bbbc4c` with normal and 1/8/16/64-cycle slicing. The new synthetic
test compares complete serialized records across 35 packet/budget combinations,
including stores into a live packet, completion inside a block, chained tags,
and malformed tags. The gameplay runner had not been updated or timed at that
checkpoint.

With pending-VI continuation enabled, current one-repeat coverage rises again to
58,870 retired pairs. All 122 VU-related tests pass, and the 32 private captures
remain exact at slice budgets 1, 8, 16, and 64. Seven alternating 1024-repeat
same-executable comparisons measured 3,714.337 ms for pair-only execution and
3,115.889 ms with native blocks at the median, a 16.112% replay-time reduction;
the candidate won all seven pairs. This is offline VU evidence, distinct from the
live gameplay comparison above.

## First-Pair VF Entry Stalls

After pending-VI support, a temporary per-reason trace found 2,174 preparation
refusals and 60 short-budget refusals in the one-repeat replay. Every preparation
refusal was an upper VF read in the first instruction, exactly one cycle before
its source became visible. The trace was removed after collecting that result.

PS2Recomp `7e2f840` computes the first pair's VF readiness from constant operand
metadata. When needed, it advances the same architectural cycles as the
interpreter, including pipeline retirement and PATH1 progress, before rechecking
all normal block preconditions. A public two-pair synthetic block stages an LQ
result one cycle before entry and verifies exact state, memory, cycle count, one
block attempt, and native execution.

All 122 VU-related tests pass. The 32 private captures remain exact with 1, 8,
16, and 64-cycle slicing. At the normal replay budget, block attempts fall from
4,014 to 2,060 and native coverage rises from 58,870 to 59,864 pairs. Seven
alternating 1024-repeat comparisons measured 3,620.144 ms pair-only and 2,834.312
ms with blocks at the median, a 21.707% reduction; blocks won all seven rounds.

The live candidate passed static PE validation and Probes 2271/2272 both reached
textured gameplay and exited normally. The same executable measured 3.4720 FPS
with blocks and 3.3964 FPS interpreted over presents 1152-1280, a much smaller
2.2% difference. Treat the replay gain as evidence for the VU path, not as a
whole-game speed claim.

`compare-vu-blocks.ps1 -BaselineExecutable <path>` runs matched block-enabled
binaries in alternating order at Normal priority with affinity 0xF. It checks
the capture identity, cycles, output digest, actual block execution, and input
file hashes, then overwrites the single ignored `disc/vu-block-comparison.json`
report. `-BaselinePairsOnly` compares pair and block execution in one binary.

## Compiled Entry Deadlines

PS2Recomp `f801b9c` computes the earliest required entry deadline for each VF lane,
ACC lane, and VI register at compile time. Repeated reads share one check; a VI
write inside the block removes the old entry deadline from later reads. The
existing static internal-hazard proof and runtime VF queue-slot reservation stay
in place. This removes repeated readiness checks and the per-entry virtual VI
array without changing block acceptance or execution timing in the saved replay.

All 123 then-current VU-related tests pass, including 270 new public synthetic
cases with delayed lane reads, VI replacement, and short budgets. All 32 original
gameplay captures retain 40,803 cycles and digest `75d4ff1e67bbbc4c` at normal
and 1/8/16/64-cycle slicing. Normal-budget block coverage remains 59,864 pairs.
Seven alternating 1024-repeat runs measure medians of 2631.679 ms before and
2432.532 ms after (7.567% less replay time), with seven candidate wins. Both modes
retire 30,680,300 block pairs including the cold pass. The candidate also contains
the new synthetic test block; this is a comparison of the complete builds, not
an isolated instruction-level timing. It is not a gameplay frame-rate claim.

The pre-change offline sampler had 370 in-module samples: native flag retirement
accounted for 9.46%, generic pipeline retirement 6.22%, and block preparation was
also prominent. These sampled percentages include replay overhead and guided
the entry-deadline change; they are not production-frame percentages.

## Spread Gameplay Capture

Recorder checkpoint `6e29441` uses a deterministic 1-in-256 selection in both
budget classes and waits at least four ticks between records in each class.
The quota remains 16 short and 16 long records, with the unchanged 4 MiB cap.
The scheduling regression also runs when native blocks are disabled. The current
VU-related suite passes 124/124.

Probe 2275 used interpreted VU execution through the real New Game handler and
recorded `disc/vu-replay-spread.bin`: 1,907,530 bytes, 32 records, two records per
tick at 1100, 1104, ..., 1160, with one code image. Its native present-896 capture
shows New York and Wolverine with the existing black props and HUD/effect defects.
The process exited normally at tick 1200 and restored the startup archive.
The original capture hash remains unchanged.

All 32 new workloads match the recorded interpreter state, memory, and graphics
packets at normal and 1/8/16/64-cycle slicing: 16,338 cycles per repeat and digest
`6c13c7a10069aeef`. The current compiled blocks cover 17,978 of 31,034 retired pairs
including the cold pass (57.93%), compared with 74.65% in the original capture.
The new private recipe `disc/vu-native-pairs-spread.inc` is 64,303 bytes and covers
487 PCs, including 185 absent from the original recipe; 124 original PCs are not
exercised by the spread capture. Keep both inputs for regression coverage.

Seven alternating 2048-repeat comparisons against the pre-entry-deadline build
measure medians of 2195.355 ms before and 2064.303 ms after (5.970% lower VU time).
The candidate wins five of seven rounds; later runs have noticeable shared-host
variation. Every run preserves the expected result and 18,418,461 block pairs
including the cold pass. This supports a replay improvement but establishes no
whole-game FPS gain. The next coverage experiment should rank the same bounded
kernel budget against the broader recipe and verify both captures.

`compare-vu-blocks.ps1 -CapturePath <path>` accepts either capture. The native
replay still checks every recorded state/memory/GIF result, and the helper rejects
cross-run changes in case count, cycles, digest, or input hashes. The report
records the compared replay identity instead of hard-coding the original digest.

The current candidate includes `f801b9c` and `6e29441`, is 163,238,400 bytes, and
has SHA-256 `42FFBDA55226B7A55AE07311A9BC35049165ADC6EA0DF46636B53BB49020108C`.
After the interpreted capture run, ordinary block-enabled Probe 2276 reached
textured New York/Wolverine, retained the known rendering defects, and exited
normally at tick 1400. Both startup restoration and runtime/observer closure
completed. Its profiler-free 128-present window took 32.2046665 seconds,
or 3.9746 FPS. This single shared-machine result is not an isolated before/after
comparison or practical play speed. Post-join counters record 629,440,682 block
pairs, included within 967,419,185 native pairs, plus 738,583,621 interpreted pairs.

## Internal-Wait Scheduler Checkpoint

Stopped on 2026-09-05 after recovering the completed BelowNormal test build.
Experimental PS2Recomp checkpoint `1d14571` computes internal VF/ACC/VI wait
cycles at compile time, includes them in entry deadlines and budget checks,
and advances architectural retirement and PATH1 through each required wait.
It retains interpreter fallback when the block cannot execute safely.

The build exited 0. All 125 VU-related tests pass, including 78 new cases for
internal waits, loop budgets, active GIF payload stores, and chained tags.
Both 32-record captures remain exact at normal and 1/8/16/64-cycle slices:
original 40,803 cycles / `75d4ff1e67bbbc4c`; spread 16,338 cycles /
`6c13c7a10069aeef`. Test executable SHA-256:
`7F4AC65C4B338F2131AD97DA6DEBEAF3DFDCAEF016BE3D39767436DDC55686F6`.

The broader recipe by itself was slower in the preceding three-round comparison:
2062.878 ms original / 2109.155 ms broader, a 2.243% regression with zero wins.
Both capture code images are byte-identical. The local cache currently selects
the broader recipe with 64 private pairs and 16 private blocks; the scheduler
adds a fourth public synthetic block, for 20 compiled blocks total.

Performance testing of the scheduler is still pending. Retain the temporary
`ps2x_tests.schedule-base.exe` (same broader recipe without scheduling, SHA-256
`96756F4C118671A2494D21D3B77F23DC1559683D817B2A242AEC155D43F3F58E`)
and `ps2x_tests.block16.exe` (original recipe, SHA-256
`8F7DB891A2FAEF6284E8093EDF072B4717CCAC389FCB399EB0C3CBAEED1B25D4`)
for isolated and end-to-end comparisons on both captures. Remove these temporary
test binaries after the comparisons; no game executable copies were added.

No gameplay run or candidate relink was performed for this checkpoint. The
primary, staged, and last live-validated candidate hashes remain unchanged.
Do not describe this build as a gameplay speed improvement or promote it before
benchmarking and subsequent game validation. All owned build/test processes
were closed before stopping.

## Broader Selection Timing Audit

The continuation after the checkpoint completed three seven-round alternating
comparisons. All recorded states, memory, GIF output, and cycles remained exact.
The scheduler-plus-broader-recipe executable was
`7F4AC65C4B338F2131AD97DA6DEBEAF3DFDCAEF016BE3D39767436DDC55686F6`.

| Reference | Capture / repeats | Reference median | Candidate median | Candidate result |
| --- | --- | --- | --- | --- |
| Same broader recipe without scheduler | Spread / 2048 | 2129.191 ms | 2138.865 ms | 0.454% slower, 3/7 wins |
| Accepted original recipe | Original / 1024 | 2433.920 ms | 2633.299 ms | 8.192% slower, 0/7 wins |
| Accepted original recipe | Spread / 2048 | 2024.147 ms | 2080.477 ms | 2.783% slower, 0/7 wins |

The scheduler did not increase block coverage in the broader selection:
16,562,067 block pairs over the cold pass plus 2048 timed spread repeats, with
or without scheduling. The accepted original selection executes 18,418,461
block pairs on that same workload. On the original capture, the candidate
executes 25,360,550 block pairs versus the accepted build's 30,680,300.
This is evidence against promoting the broader recipe, not evidence that more
sampled PCs automatically make a better compiled selection.

Restore the original `disc/vu-native-pairs.inc` selection and isolate scheduler
cost there before deciding whether to retain the new scheduling implementation.
Do not expand the block budget or launch another game probe for these results.

The original recipe was then restored with the same guarded build settings.
All 125 VU-related tests pass and both captures are exact at normal and
1/8/16/64-cycle slicing. The rebuilt test executable is
`A81E93D0867C631B145E98C996446DDBEDD5693BBF64786602BE040C52DF7A76`.
Seven alternating comparisons against the accepted original-recipe build give:

| Capture / repeats | Before scheduler | With scheduler | Candidate result |
| --- | --- | --- | --- |
| Original / 1024 | 2443.675 ms | 2420.845 ms | 0.934% lower, 5/7 wins |
| Spread / 2048 | 2022.707 ms | 2030.595 ms | 0.390% slower, 2/7 wins |

Both modes execute identical block-pair counts. Treat this as effectively
neutral, not a meaningful performance improvement. Keep the scheduler as an
experimental capability in source, but do not promote a new game build for it.
The broader recipe is not selected in the local cache. Temporary comparison
binaries can now be removed; their hashes and results remain recorded above.

A process-local sampler on 4096 spread repeats recorded 359 samples, 60 outside
the module, zero dropped samples, and zero sampling failures. The linker-map
timestamp matched the executable. Of the 299 in-module samples, pipeline
retirement accounted for 27 (9.03%), native flag retirement 18 (6.02%),
interpreter upper dispatch 17 (5.69%), queued stores 15 (5.02%), and readiness
calculation 10 (3.34%). Replay serialization and loading are also substantial
in this whole-test profile, so these are investigation leads, not production
frame percentages. The instrumented replay still matched all recorded results.
Investigate block fallback reasons and per-pair bookkeeping next rather than
reranking the same kernels or repeating whole-game boot timing for tiny changes.

Post-audit cleanup removed both temporary comparison executables and 186 inactive
Debug directories. The workspace is 7.710 GiB / 29,090 files; all eight protected
artifacts and 21 active block-source/dispatch files remain. The primary, staged,
and gameplay-candidate executable hashes are unchanged. No game was launched,
no screenshots were taken, and all owned build/test processes have exited.

## Integer-Load Block Prototype

A temporary per-block rejection audit checked both captures, including their
cold passes. Every refusal inside `canExecuteFast` was a short execution budget.
Pending ACC/store/divide/EFU operations, branch/end state, PATH1 boundaries,
entry-read deadlines, and VF queue capacity caused zero refusals. This does not
measure missing block lookups or failed code matches. The temporary counters
and diagnostic change to the test runner's immediate exit were removed.

An initial hypothesis that ILW stopped the hot 0x0a88 block was incorrect: that
block ends at its branch and delay slot. The unsupported load instead prevents
other entries, notably 0x18a0, from compiling. PS2Recomp `28a40cf` adds ILW with
four-cycle VI result visibility, compile-time dependency scheduling, existing
delayed-write queues, and a conservative queue-capacity guard. Results that
outlive the block remain queued; newer writes retain sequence-based cancellation.

All 126 VU-related tests pass. The new public block covers 198 combinations of
signed values, wrapped addresses, pending entry writes, VI0, cancellation,
branch delay-slot loads, and short resume budgets. Both private captures retain
their exact state/memory/GIF output and expected cycles/digests at normal and
1/8/16/64-cycle slicing. The test build is 5,705,728 bytes, SHA-256
`CE2728D5207DE273D814BBEA61A38A7A86ECC567F52DDDCB6DC91BB67AE1721A`.

The original recipe and 64-pair / 16-private-block limits remain active, with
five public blocks. Enabling ILW selects the 23-pair block at 0x18a0 and displaces
0x0b80. Normal-budget coverage becomes 59,726 pairs on the original capture
(previously 59,864) and 18,104 on spread (previously 17,978).

| Capture / repeats | Pre-ILW median | ILW prototype median | Result |
| --- | --- | --- | --- |
| Original / 1024 | 2502.122 ms | 2582.278 ms | 3.204% slower, 1/7 wins |
| Spread / 2048 | 2139.856 ms | 2125.355 ms | 0.678% lower, 4/7 wins |

These seven-round alternating comparisons preserve all exact outputs, but show
no reliable improvement; shared-host timing variation is also visible. Do not
promote this prototype to the game executable. Keep it as an explicit
experimental checkpoint while correcting overlapping-block selection, which
currently ranks entry frequency rather than marginal covered work.

The sole active comparison baseline was renamed in place to
`ps2x_tests.accepted-blocks.exe`, SHA-256
`A81E93D0867C631B145E98C996446DDBEDD5693BBF64786602BE040C52DF7A76`.
Retain that fixed slot for the next measured selection comparison; do not make
per-probe copies. The primary, staged, and live-validated game candidate remain
unchanged. No game process or screenshot was needed for this experiment.

Cleanup removed 187 inactive Debug directories. Final workspace size is
7.735 GiB / 29,131 files; all eight protected artifacts, the fixed comparison
baseline, and all 22 native-block source/dispatch files remain. All owned
build/test processes exited before cleanup.

## Marginal Coverage Selection

PS2Recomp `5bf8813` adds opt-in `PS2X_VU_NATIVE_BLOCK_SELECTION=coverage`;
`frequency` remains the source default. The exporter now records exact
per-PC retired counts. The private `disc/vu-native-pairs-weighted.inc` is
70,152 bytes, SHA-256
`2BFA7E6FDBFE36021083C664F8A4528411CE4FA2322BF49956876139CD676220`.
Removing its 426 new PC-count records reproduces the original recipe's content
and order exactly. Original recipes and both captures remain unchanged.

The greedy selector scores newly covered executions, capped by the candidate
entry's own count. Overlapping blocks do not receive credit for already covered
work; ties preserve recipe order. This is a coverage estimate, not measured
per-block execution cost. Eight standalone selection checks and seven invalid
input checks pass, including address zero, rare prefixes, deterministic ties,
public-block exemption, limits, and missing/invalid weights.

The active local cache selects coverage with the weighted original recipe,
64 private pairs and 16 private blocks plus five public synthetic blocks.
All 126 VU-related tests pass. Both captures remain exact at normal and
1/8/16/64-cycle slicing. Test executable SHA-256:
`415DBAFA25E21084FF1FF9F728FD556400BEBB8C07AEE91DFEA603E780E5D317`,
5,791,744 bytes. Normal-budget block coverage is 64,508 of 80,194 pairs
(80.44%) on original and 19,096 of 31,034 (61.53%) on spread, including cold
passes. The fixed pre-ILW baseline covered 59,864 and 17,978 respectively.

| Capture / repeats | Fixed baseline median | Coverage candidate median | Result |
| --- | --- | --- | --- |
| Original / 1024 | 2562.666 ms | 2491.862 ms | 2.763% lower, 7/7 wins |
| Spread / 2048 | 2098.022 ms | 2064.947 ms | 1.576% lower, 6/7 wins |

These seven-round alternating comparisons include the ILW support added since
the fixed baseline; they measure the combined build, not an isolated selector
instruction. All exact results and cycle counts match. The last spread round
has visible shared-host noise. These are modest offline VU gains, not gameplay
FPS evidence; the gameplay candidate has not been relinked.

A follow-up process-local profile records 366 samples, 62 external, zero dropped
or failed, and a matching linker-map timestamp. Among 304 in-module samples,
pipeline retirement contributes 7.24%, native flag retirement 6.58%, and VF
write queuing 4.28%. Replay serialization is prominent (18.75%) but lies outside
the benchmark's timed execution. Do not interpret whole-test sample percentages
as whole-game timing or spend effort optimizing test serialization for FPS.

## Constant Result Deferral

PS2Recomp `2ddfc04` passes the compiled distance to block end as a template
constant. Each instruction's VF-result deferral is now decided at compile time,
removing runtime end-cycle comparisons and unused temporary-copy paths. The
existing queue allocation, retirement, instruction order, and wait schedule
are unchanged. Both extended and short fallback blocks use their own schedule.

All 126 focused VU tests pass. Both captures retain exact state, memory, GIF
bytes/cycles, digest, and total cycles at normal and 1/8/16/64-cycle slicing.
Block coverage remains 64,508 original / 19,096 spread pairs. The test image
is 5,778,944 bytes (12,800 bytes smaller), SHA-256
`1737D0CF99186FF812E8BF58A8BF3F342CDBB162723371C499F7FFCCE5E3A102`.

| Capture / repeats | Coverage baseline | Constant-deferral candidate | Result |
| --- | --- | --- | --- |
| Original / 1024 | 2429.307 ms | 2396.670 ms | 1.343% lower, 5/7 wins |
| Spread / 2048 | 2006.897 ms | 1996.594 ms | 0.513% lower, 4/7 wins |

These are seven-round alternating same-selection comparisons. The original
workload shows a small benefit and spread is effectively flat with shared-host
noise. Retain the simpler generated code, but do not claim meaningful gameplay
acceleration from this result. The saved game executables remain unchanged.
The temporary `ps2x_tests.block16.exe` comparison copy is no longer needed.

Next: separate execution sampling from replay serialization/setup, then choose
the largest remaining execution hotspot. Existing whole-test profiles include
substantial test-only serialization cost. Do not optimize that overhead as if
it were part of a game frame, repeat rejected queue-index experiments without
new evidence, or run whole-game timing probes solely for these tiny changes.

Cleanup removed the finished comparison binary and 187 inactive Debug
directories. Workspace: 7.739 GiB / 29,166 files. All eight protected artifacts,
the fixed baseline, and 22 active block-source/dispatch files remain. Primary,
staged, and gameplay-candidate hashes are unchanged; owned processes are closed.

## Execution-Only Sampling

PS2Recomp `b024e1a` brackets warmed replay execution with an optional atomic
marker. The process-local sampler reads it while its own target thread is
suspended, alongside the instruction address. Cold passes, snapshot loading,
serialization, and comparison are excluded. Scope cleanup clears the marker
on unwinding; success and rejected-input checks pass. Ordinary gameplay is
unmodified. Reports label old logs `whole-replay` and new logs `warm-execution`.

The profiling baseline passes 126/126 VU tests and both captured workloads.
Its test executable SHA-256 is
`6107937DE1C06E58C4A511F43086951BB60B288ED113EA043B2C3930F96176DD`.
Original / 2048 repeats gives 301 execution samples (40 external), excluding
53 observations. Spread / 4096 gives 240 (34 external), excluding 98. Both have
zero dropped samples or capture failures, with exact original digests and
cycle counts. These are instrumented profiles, not speed comparisons.

Among 261 original / 206 spread in-module execution samples, native flag
retirement accounts for 11.49% / 13.59%, general pipeline retirement for
10.34% / 16.02%, and the leading flag-packing specialization for 9.20% / 5.34%.
Snapshot serialization is no longer a leading sample category. Symbol ownership
can reflect linker folding, and these small sample populations establish broad
priorities rather than precise game-frame percentages.

A 16-entry MAC condition-bit lookup table passed all 126 focused tests and both
captures at normal and 1/8/16/64-cycle slicing, but seven alternating comparisons
showed only 0.818% lower original median (2396.055 / 2376.456 ms, 5/7 wins) and
0.522% lower spread median (2001.170 / 1990.726 ms, 6/7 wins). That is not a
convincing practical benefit. The experiment was removed; no gameplay build
contains it. Its test hash was
`927F83A79B30D899EEA919390B7C937262F67C24A71F392AAA4B94CA557EFD53`.

The next investigation should address flag retirement rather than another small
packing tweak. Native blocks currently scan pending flag entries after each
pair. Their admitted lower operations do not include status/MAC/clip reads, but
any batching proposal must still preserve incoming pending flags, slot order,
sticky accumulation, internal waits, and the exact delayed tail at block exit.
Prior completion-index and preassigned-retirement experiments were slower;
do not repeat those approaches unchanged. This is an investigation, not yet a
validated batching design.

The restored `b024e1a` build passes 126/126 focused tests and both captures at
normal and 1/8/16/64-cycle slicing. Final test executable SHA-256:
`F7C221FF0EF41A0E9F6137F05E3B872DC7F6B5F670720973FBFC8985AFB31B61`.
All three gameplay executable hashes remain unchanged. The cleanup command was
rejected by execution policy before launch, so the 5,780,480-byte comparison
executable and inactive Debug directories remain; no deletion is claimed.

## Direct Flag Clearing

An unrolled fixed deadline pass was tried first, without cached state or changed
retirement order. All 127 then-current tests passed, including every 8-slot
occupancy/readiness combination at four cycle boundaries; both captures stayed
exact at normal and 1/8/16/64-cycle slicing. Seven original-capture comparisons
were effectively tied: 2401.464 ms baseline / 2401.870 ms candidate, 4/7 wins.
MSVC emitted a separate deadline helper call with eight scalar comparisons.
The experiment and its helper-specific test were removed. Do not repeat it as
an already-proven speed improvement.

Disassembly then exposed a concrete cost in flag retirement: `entry = {}` built
a zeroed temporary on the stack and copied it to the 40-byte integer/bool entry.
PS2Recomp `eef46ed` clears that entry directly in the interpreter and native
block paths. MSVC now emits a zeroed 32-byte vector store and an 8-byte scalar
store, with no aggregate temporary. Deadline checks, slot order, flag values,
pending tails, and occupancy changes are unchanged.

All 126 focused VU tests pass, and both recorded workloads remain exact at
normal and 1/8/16/64-cycle slicing. Candidate test SHA-256:
`BE50B67C2A9F55DF6C7D92ADA6F7D02CD0EA0B611F0559B1F84908FB3F99E267`.
The existing `ps2x_tests.flag-pack-base.exe` was reused without another copy;
its SHA-256 remains `6107937DE1C06E58C4A511F43086951BB60B288ED113EA043B2C3930F96176DD`.

| Workload | Baseline median | Candidate median | Result |
| --- | --- | --- | --- |
| Original / 1024 repeats, first run | 2491.277 ms | 2469.353 ms | 0.880% lower, 4/7 wins |
| Spread / 2048 repeats | 2135.250 ms | 2035.908 ms | 4.652% lower, 7/7 wins |
| Original / 1024 repeats, repeat run | 2600.269 ms | 2568.404 ms | 1.225% lower, 4/7 wins |

Shared-machine timing variation is substantial. The broader workload benefits,
while the original remains a small, noisy change. Retain the simpler generated
clearing code, not a claim of practical gameplay speed. Game executables remain
unchanged.

The generic counterpart is submitted as `c5d12f8` on existing upstream
[PR #245](https://github.com/ran-j/PS2Recomp/pull/245#issuecomment-5555475633).
Its upstream-based Release suite passes 427/427. It does not include private
captures, generated game code, or the native-block implementation. The existing
checkout at `C:/Programming/GitHub/PS2Recomp` was reused; no worktree/clone was added.

Next investigate duplicated arithmetic normalization and exact-result
reconstruction. A possible conservative fast path is ordinary nonzero,
non-boundary results of simple ADD/SUB/MUL operations, but it needs a proof of
identical status/sign behavior and boundary-focused differential tests before
implementation is accepted. Do not assume the same proof applies to multiply-add
cancellation, signed zero, the minimum normal, or maximum finite value. No such
arithmetic fast path has been implemented in this checkpoint.

## Rejected Whole-Block Slot Cache

The September 5 follow-up tested one thread-local slot-allocation plan per
compiled block, keyed by the exact incoming VF occupancy mask and each occupied
slot's deadline relative to the entry cycle. All existing eligibility checks
remained live. Only successful simulations populated the cache; hits reused
the upper/lower slot arrays without resimulating each instruction.

The 128-test VU suite and original gameplay capture stayed exact. Seven
alternating 1024-repeat comparisons measured 3274.625 ms baseline versus
3257.355 ms candidate, only 0.527% lower with 4/7 wins. This does not justify
the cache. It was removed without linking or running another gameplay build.
The rejected test hash was
`09B37A0822E9F0B97475EF86DA83C123CFB7DF5EC760293B3C7E49A1E9CD0BCE`.
The fixed ignored comparison JSON was reused, not duplicated.

Retained tests expand the mixed-write fixture from 48 to 768 cases. Three
prelude pairs independently select no write, upper VF write, lower VF load,
or both; all 64 patterns cross 12 budgets and subsequent one-cycle snapshots.
They assert pending input values and actual compiled execution at full budgets.
The restored runtime passes 128/128 VU tests and both 32-record captures at
normal and 1/8/16/64-cycle slicing, with unchanged digests and cycle counts.
Test SHA-256:
`37407B2032245B81C44E84E4510F124F89E3BC85CBB48895E07AD792162DFE0E`.

## Compiled-Flag Reference Audit

Inspected Play!'s current source on September 5 without adding a checkout.
[`ComputeSkipFlagsHints`](https://github.com/jpd002/Play-/blob/master/Source/ee/VuBasicBlock.cpp)
tracks which delayed MAC results can be consumed inside the block or after its
exit. This is a useful example of compile-time liveness analysis.
However, [`TestSZFlags`](https://github.com/jpd002/Play-/blob/master/Source/ee/VUShared.cpp)
still updates its separate sticky pipeline when a MAC update is omitted;
`GetStatus` also carries a TODO for additional flags. This is not evidence that
all flag arithmetic or retirement may be removed from PS2Recomp. Our unified
pipeline, sticky product flags, exact pending state and graphics-transfer cycle
contract need their own proof. No Play! code was copied or integrated.

## FMAC Producer Packing

First tested publishing each VF/ACC/VI readiness field only at compiled-block
exit. The interpreter/native instruction helpers do not read those arrays within
a block, and exact tests passed, but seven alternating original replays measured
2909.037 / 2906.008 ms: effectively tied. This experiment was removed. Its test
hash was `DEDA52ECA6566505845A858C8A2B5A4FFF5D543BF1016808EC0F769A6B2EDFB7`.

A fresh execution-only profile of that variant used 2048 original repetitions:
415 samples, 53 external, 362 in-module, zero dropped/failed samples, matching
image/map timestamp `0x6a9cb4f9`. Native destination-14 flag production was the
largest single symbol, with 34 samples (9.39%). Disassembly showed scalar bit
assembly and a zeroed 40-byte stack temporary copied into each new flag entry.
The initial 4096-repeat attempt hit the existing total execution-budget guard;
the successful rerun used 2048 without relaxing that guard. The fixed profile
log now intentionally belongs to an older image than the current linker map.

Accepted `110ed3a` uses portable integer swaps to transpose four flag nibbles
into Z/S/U/O lane masks. One shared `VUFlags::packFmac` serves interpreted and
native flag generation. Sticky accumulation, readiness, queue selection, and
retirement remain unchanged. Direct `memset` initialization removes MSVC's
temporary-copy sequence; all entry fields have zero integer/bool defaults.
The inspected native specialization still calls the packing helper out of line.

Tests exhaust 65,536 flag patterns across 16 destinations, plus 4,096 cases
covering high flag/destination bits. The complete focused suite passes 129/129,
and both recorded workloads retain exact state, memory, GIF payload/timing,
cycle counts and digests at normal and 1/8/16/64-cycle slicing.

| Capture / repeats | Accepted baseline | New producer | Result |
| --- | --- | --- | --- |
| Original / 1024 | 2462.786 ms | 2394.965 ms | 2.754% lower, 7/7 wins |
| Spread / 2048 | 2098.631 ms | 2012.671 ms | 4.096% lower, 7/7 wins |

These are seven-round alternating comparisons on the shared host, not gameplay
FPS or a measurement of the upstream-only subset. No new live gameplay run or
runtime executable was produced. Test hash:
`AE4D88555CD487A736551DC92B9A51D4F037084B59A97EF52F864FF15F029931`.

The generic subset is submitted as
[PS2Recomp PR #250](https://github.com/ran-j/PS2Recomp/pull/250), commit `3e50ad9`,
based directly on upstream main `14b1e5c`. Its complete Release suite passes
426/426. The existing contribution checkout and build directory were reused;
no game assets, private native kernels, new checkout, or extra binary slot is
included. The existing occupancy-mask branch is preserved separately.

## Native Operand Reuse

PS2Recomp `119706f` reuses the native operation's normalized VF/ACC/Q/I inputs
for FMAC flag calculation. The interpreted oracle is unchanged. An initial
fast-math version narrowed a widened product back to float and lost an underflow
sticky flag. The native-only `float_control(precise)` scope is required: the final
image/map timestamp `0x6a9cbcfe` and MULbc specialization at RVA `0x2ed530` show
conversion to double before `vmulsd`, preserving the flag input's range.

The disconnected test build initially failed recipe validation because new
synthetic PCs had eight hex digits instead of the required four. After that
format correction, the BelowNormal build succeeded and all 129 VU tests passed.
Arithmetic coverage now includes 3,216 seed/start cases with MADD/MSUB, ACC
inputs, and source/destination aliasing, alongside 768 mixed-write cases.
Test SHA-256:
`626C8504544A80009ED8923DDB8B9B9277019A6E26AF51F13F1B7C4806817B2C`.

Both private recordings remain exact at normal and 1/8/16/64-cycle slicing.
Normal cold-plus-one-repeat native pair counts are unchanged at 77,664 / 23,048;
block pair counts remain 64,508 / 19,096. Adding two public synthetic blocks did
not change coverage of either game recording. The private recipe stays at 64
pairs and 16 blocks; public blocks now number ten, giving 26 total blocks.

The existing `ps2x_tests.flag-pack-base.exe` slot now holds accepted `110ed3a`,
SHA-256 `AE4D88555CD487A736551DC92B9A51D4F037084B59A97EF52F864FF15F029931`.
No additional comparison executable was created.

| Capture / repeats | Baseline | Operand reuse | Result |
| --- | --- | --- | --- |
| Original / 1024 | 3308.108 ms | 3232.464 ms | 2.287% lower, 6/7 wins |
| Spread / 2048 | 2558.118 ms | 2519.449 ms | 1.512% lower, 5/7 wins |

These final-image, seven-round alternating comparisons show a modest shared-host
gain, smaller than the earlier 5.651% original-only result from the pre-expanded
test image `FC095762F3C6D82F6AB2749FEF2A8AC8FBF15910FF1671EC5D10BEA4C6C27282`.
Do not extrapolate either result to gameplay FPS or combine percentages from
different runs as a measured cumulative gain.

A new execution-only profile on the final image used 2048 original repetitions:
355 samples, 44 external, 311 in-module, zero dropped/failed samples, matching
timestamp `0x6a9cbcfe`. Top individual symbols were `commitReadyPipelines`
(24 samples, 7.72%), `normalizeFmacExactResult` (16, 5.14%), and `packFmac`
(13, 4.18%). Fixed `execution-profile.*` logs now describe this image, replacing
the earlier deadline experiment. These are sampled VU costs, not whole-game
percentages. The remaining major task is reducing compiled execution bookkeeping
without losing delayed-write, sticky-flag, or graphics-transfer semantics.

## Gameplay Coverage Windows

PS2Recomp `955b393` adds opt-in `PS2X_VU_COVERAGE_PROFILE` reporting at VU1
slice entry on the executing thread. It reads the existing native/interpreted
pair and block counters, not UI-thread copies. One sample per guest tick feeds
32-tick windows within ticks 1100-1400; startup counts are subtracted. Owner,
tick, and counter rollback reset the sampler instead of unsigned-underflowing.
No VU object layout or instruction semantics changed. The default is off.

The focused suite passes 131/131, including window/reset tests. Both recorded
captures remain exact with coverage enabled. Test SHA-256:
`7DDD7C0294EEE2B785AE8CC3E9475AB07EF76F24855F056782C3329561CEE4BA`.
The test and game links ran BelowNormal with affinity 0xF, one worker, and the
2048 MiB compiler cap. Candidate SHA-256:
`CE7E1C90D16606BCDA8D7343980857E660B93E40AEB13DF636B46ED597C1224C`.

Run `run-gameplay-benchmark.ps1 -CoverageProfile -PhaseProfile` for the combined
report. It reuses `gameplay-phase.*`, records no FPS for an instrumented run,
and requires contiguous coverage spanning the gameplay interval. The report
parser rejects malformed counters, duplicates, gaps, short intervals, empty
workloads, and incomplete spans. Its regression tests use in-memory fixtures.
An initial file-backed test left `.vu-coverage-test.log`; deletion was denied,
so it remains untouched. The first live finalizer tried to read a log while its
writer was still open. The wrapper now closes both writers before parsing.

The corrected full run exited 0 at vsync 1400, verified the New Game handler,
NYC package, native blocks, and both timing markers, and restored startup files.
Nine windows covering ticks 1100-1388 contain:

| Path | Instruction pairs | Share of all pairs |
| --- | --- | --- |
| Compiled blocks | 265,818,240 | 45.26% |
| Other native pair kernels | 123,013,207 | 20.95% |
| Interpreter fallback | 198,437,472 | 33.79% |

Block attempts/executions are 12,109,248 / 10,449,216. The earlier run, whose
game reached the limit but whose report finalizer failed, produced essentially
the same split: 66.21% total native / 45.27% blocks. Counts are not time shares.
The corrected run's 73 phase reports ending at ticks 1100-1388 cover 76,239.624 ms:
VU exclusive 48,057.24 ms (63.03%), GS 19,384.40 ms (25.43%), guest 4,295.09 ms
(5.63%), transfers 3,683.26 ms (4.83%); waits remain negligible. Boundary phase
reports can straddle the coverage interval, so this is a nearby phase estimate,
not an instruction-by-instruction cost attribution.

This shows substantially more fallback than the original offline recording.
Next test 128 private pair kernels versus 64 while retaining the same weighted
recipe and 16 private blocks; do not conflate pair expansion with previously
rejected block/recipe expansion. Recipe frequency inspection alone predicts
coverage, not performance. Require both exact recordings and alternating timing
before another gameplay integration. No frame-rate or rendering gain is claimed
for the coverage instrumentation itself. The last unprofiled run remains 4.14 FPS.
