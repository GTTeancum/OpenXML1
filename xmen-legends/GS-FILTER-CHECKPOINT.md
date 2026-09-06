# Packed Texture Filter Checkpoint

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
