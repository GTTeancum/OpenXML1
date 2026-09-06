# CPU Texture Checkpoints

## Prepared Indexed Sampler

September 6 local PS2Recomp checkpoint `8308463`. This is an opt-in performance
change, not a new game build or a fix for existing graphics defects.
`PS2X_GS_PREPARED_TEXTURE` selects a specialized indexed sampler. It selects the
VRAM reader once per draw and reuses decoded palette colors. Ordinary CT32
palettes are read directly from the canonical GS palette; other interpretations
are cached until an actual CLUT load, reset, or changed CSA/CPSM/TEXA interpretation.
Texture indices are still read from live VRAM, including self-overwriting draws.
Pixel tracing keeps the original path.

`PS2X_GS_VERIFY_TEXTURE` compares every prepared sample against the original
sampler before publication, throwing on mismatch. It must be combined with
the prepared-texture switch. Do not measure FPS with this audit enabled.
The game benchmark runner does not yet expose or validate these new switches;
add its audit-evidence/FPS-exclusion gates before using a new combined game build.

Final test-only image, after locking the reference checksums:
`0E4A7F99CAB0C2881F34723DD8BF405B819B4ADC58D3CACF3B940E9152F2BE05`.

- GS suite: 90/91 both OFF and prepared+audit; sole failure is the historical
  CSR/IMR test. No full-suite pass is claimed.
- 1,280 cases cover five indexed formats, four palette formats, four CSA banks,
  both filters, CLD load/skip transitions, TEXA changes, reset and live feedback.
  Two consecutive draws exercise reuse. Fixed framebuffer hash:
  `da0ce5b7a3b6a9e5`.
- At least 7,340,033 texture samples matched the original sampler in the full
  audited suite. Existing 128-case depth hash remains `e5a1e2f16d5d1336`.
- All 161 VU tests pass with prepared texture/audit enabled.
- Four triangle workloads retain `e0b47b3066d49e9e` (large) and
  `0c1456a835c30feb` (small). Their checksums are now test assertions.

Timing used the same renderer code in pre-checksum-assertion test image
`8CB0E0CD3E67D86D68439270D70B40CDC1FEE839C42F2A6330230954C1538499`.
Seven alternating OFF/ON pairs across all four workloads gave process CPU-time
medians 734.375 / 609.375 ms, 17.02% lower; ON won six of seven pairs. This
includes process initialization and has coarse CPU-time resolution. Individual
wall timings were noisy: large-triangle median 367.451 / 281.647 ms, while
small/reloading workloads did not establish consistent per-scenario gains.
Do not turn these numbers into a gameplay FPS estimate or sustained guarantee.

The initial eager-cache version regressed 6.69% when reloading before every tiny
triangle. Direct access to ordinary CT32 palettes removes that needless decode.
The workloads include 512 large draws and 23,424 tiny draws, with no reloads,
reloads every eight draws, and reloads every draw. They are synthetic workloads,
not a captured gameplay frame. Fixed logs: `gs-prepared-checks.log`,
`gs-prepared-comparison.log`, `gs-prepared-cpu-comparison.log`, and
`gs-prepared-vu-checks.log` in the existing build tree.

Retain the change OFF by default for a subsequent performance bundle. Next
measure actual gameplay with verified audit gates, alongside further VU work;
do not launch another single-digit-FPS interactive handoff. Candidate `23A73821...`
is unchanged, movement is user-confirmed, and attacking on it remains untested.
All owned builds/tests ended. No game, input simulation, screenshots, extra
checkout/build tree, push or PR. Removed two untracked diagnostic PGM images
older than 12 hours (270,365 bytes); protected artifacts remain untouched.

## Packed Texture Filter

Local-only checkpoint, September 6, 2026. PS2Recomp commit `49442c6`.
No pushes or pull requests.

## Change

The MSVC AVX2 CPU renderer interpolates all four RGBA8 channels together instead
of calling scalar interpolation four times. Other compiler/architecture builds
retain the scalar implementation. Scoped precise floating-point compilation
prevents fused multiply/add contraction from changing channel rounding. Rounding
compares the fractional part against 0.5 rather than adding 0.5 before truncation.
The initial contracted versions failed differential tests and were discarded.

`PS2X_GS_VERIFY_BILINEAR` compares each filtered result against the old scalar
calculation before publication and throws on a mismatch. It is diagnostic only;
do not use audited runs for FPS measurements. This is a speed change, not a fix
for existing lighting, texture, HUD or other presentation defects.

## Verification

- Test executable SHA-256: `63AA8AB341D24E9F36A2FCDF1ADFEE0E74D034AA4253A18D6CA71C66DE0EBD5A`.
- 2,635,008 random/boundary color cases across four caller rounding modes match.
- Isolated 1,048,576-sample kernel: scalar 17.870 ms, packed 3.453 ms; both
  checksums `6a059184`. This is not a fivefold gameplay speedup.
- Full GS filter: 88/89 tests pass; the sole failure is the pre-existing CSR/IMR
  test. No full-suite pass is claimed.
- Existing depth differential: 128 cases, unchanged hash `e5a1e2f16d5d1336`.
- 161/161 VU tests and ten original capture/budget replay checks pass.
- Benchmark gate tests distinguish successful audits from FPS-eligible runs,
  reject missing sample evidence, and recognize either audit's failure tag.

## Combined Game Audit

Candidate SHA-256: `23A73821C4D6187A0C287EBFDFE4BC1EA81340357C3550FC59D7B61487559BCA`.
It combines this filter with the bulk timed VU transfers in outer commit
`c2a4776`. The existing game build tree and fixed diagnostic slots were reused.

At 11:33:28 UTC, `run-gameplay-benchmark.ps1 -CompiledVu -AuditCompiledVu
-AuditBilinear` completed: exit 0, 1,400-vsync limit, real New Game/NYC package,
both presentation markers, zero logged guest faults. At least 258,049 compiled
VU calls and 567,279,617 filtered samples matched their references. The runner
reported `AuditVerified=true`, left FPS null, closed its process and restored
startup. Host input was disabled; this is not an interactive controls handoff.

At 11:37:56 UTC, the same candidate completed an uninstrumented compiled-on
run: 128 presents in 21.1616848 seconds, **6.0486677318 FPS**. All workload gates
passed, exit 0, zero logged guest faults, 1,400-vsync limit; startup restored
and the owned process closed. Fixed `gameplay-compiled-rate.*` contains this run.
No new images were captured; no disc images older than 12 hours were found.

The earlier candidate measured 5.640851 FPS compiled on / 4.765298 off in one
shared-host pair. The latest 6.05 vs earlier 5.64 observations are not a matched
same-binary comparison or sustained-speed guarantee. Neither offline kernel
timing nor an audit establishes the 30 FPS acceptance target. Input remains
disabled in automated runs; interactive handoff is tracked separately in the TODO.

## Post-change Profile

At 11:41:43 UTC the same candidate completed its compiled-on phase/raster
profile, exit 0, zero logged guest faults, all workload gates, 1,400-vsync limit.
Fifty windows in ticks 1100..1400 cover 51,233.742 ms: exclusive VU 49.16%, GS
34.22%, guest 8.68%, transfers 5.31%. The 129 raster reports for presents
1152..1280 average 56.074 ms and 23,423.63 submissions. The preceding build's
64.159 ms raster observation is not a same-binary controlled comparison.
Raster cost still exceeds a 33.3 ms total frame budget; VU is also a major
remaining cost. The profile is not an FPS benchmark. Its process closed and
startup was restored before the separate user-controlled session was launched.
