# X-Men Legends PS2Recomp TODO

Work resumed on 2026-09-04 at the user's request.

## Resume Point

- Keep SFD playback out of scope. The target remains basic first-level playability.
- Preserve the known-good primary runtime at `PS2Recomp/out/xmen-final3-build/ps2xRuntime/Release/ps2EntryRunner.exe`.
- The environment-cache change retains the original dispatch gate and checkpoint batching. The unconditional early-dispatch experiment was removed. Current candidate runs reach rendered gameplay; no standalone frame-rate gain is claimed for caching.
- Probe 2251 re-established textured first-level rendering with the known-good primary runtime, `TitleGameplayFirst`, host clock, fast legal handling, aggressive branch-hook bypass, and full CPU rasterization. `probe2251-present1099.png` is the current gameplay evidence.
- User testing confirmed that Wolverine can move and basic combat works in the first level, although gameplay is currently extremely slow.
- Do not use `PS2X_SKIP_CPU_RASTER_BEFORE_PRESENT` for correctness or visual validation with host-clock pacing. Probe 2248 reached the NYC package quickly but later entered an invalid guest state and rendered black.
- Previous selected-source performance conclusions are invalidated: the helper compiled objects without rebuilding `ps2_runtime.lib`, so candidate executables could still contain old code. Do not conclude that environment caching failed or checkpoint batching caused a fault from those runs.
- Fixed the helper to run `_Lib` without `SelectedFiles` after a successful static-library source compile. Ordinary and unity-build regression tests prove candidate behavior changes, untouched library code remains available, and the primary executable is preserved.
- Probe 2252 reproduced full-rendering first-level progression to present 1140 with the unchanged primary. Across presents 1000-1140, CPU rasterization averaged 94.57 ms (44.60 ms triangle lists, 46.35 ms strips), about 23,424 submissions per frame. This is raster time, not total frame time.
- Probe 2253 tested the verified rebuilt candidate with the usual bypass enabled. Its present-1140 native capture confirms textured New York and Wolverine with the existing black props/HUD defects. The corrupted image at present 768 was still loading, not a permanent world-rendering regression. First batches over 20,000 submissions occurred at present 964 in Probe 2252 and 1010 in Probe 2253; do not compare an arbitrary earlier present as if loading had finished.
- Probe 2254 tested the broader early dispatcher with per-branch checkpoints, reached present 1140, and closed normally under the guard. This experiment was not retained. Concurrent test/build work makes its elapsed time unsuitable for a clean performance comparison. No practical frame-rate improvement is established.
- Focused tests after restoring the original dispatch control flow: VU 91/91; GS 76/79; dispatch 2/5. The three dispatch failures reproduce with and without the early-path change: indirect-call registration/return and missing-target tests encounter existing non-code-call filters. The three GS failures concern CSR/IMR access and two T4 triangle sampling cases. The full suite was interrupted; do not report a full-suite pass.
- Probes 2255/2256 compare early depth rejection off/on in the same executable. Across presents 1100-1400, mean CPU raster time fell from 98.98 ms to 63.03 ms (36%). This is not total frame time. A 20-second gameplay sample with the GS profiler enabled still measured only about 2.7 FPS.
- Probe 2257 replayed all 23,042 triangle batches in gameplay present 1200 against private copies of their starting VRAM and CLUT, comparing all 4 MiB after every draw: zero mismatches. Earlier separate-run screenshots differ in dynamic effects/HUD state; they are not deterministic frame comparisons.
- Early-depth synthetic tests compare all VRAM bytes across 128 cases: identical on/off digest `e5a1e2f16d5d1336` in the bring-up branch. Corrected two T4 fixtures to request CLUT loading (CLD=1), without changing expected pixels. Current local GS suite: 80/81, with only the existing CSR access failure. VU: 91/91. Profiling helper: 2/2. The broader local kernel suite did not finish and was stopped; it is not a passing result.
- Submitted focused upstream PR #246, `https://github.com/ran-j/PS2Recomp/pull/246`, from the existing clean checkout. Upstream-main-based Release suite: 427/427. Both complete-suite runs match digest `e1af4f1cfc948cc3`; the digest differs from the bring-up branch because the rendering implementations differ.

## Performance And Correctness

- Prioritize VU execution cost. Probe 2258's 80 complete timing windows between gameplay presents 1101 and 1299 cover 88,161 ms: VU exclusive 65,177 ms (73.93%), GS submission/drawing 16,195 ms (18.37%), other guest execution 3,181 ms (3.61%), transfers excluding VU/GS 2,801 ms (3.18%), scheduler 218 ms, events 433 ms, and waits 0.1 ms. These are opt-in instrumented wall-time measurements, not a new frame-rate claim.
- Probe 2258 reached present 1300, its native framebuffer shows textured New York and Wolverine with known black-prop/HUD/effect defects, and the guard closed the runtime and restored the startup archive. `probe2258-present1300.png` is the current checkpoint capture.
- Use `PS2X_RUNTIME_PHASE_PROFILE=1` for phase timings (`calls/inclusive-ms/exclusive-ms` per stage), `PS2X_GS_CPU_PROFILE=1` for raster-only timings, and `PS2X_GS_VERIFY_EARLY_DEPTH_PRESENT=<present>` for one-frame same-state triangle verification. Leave these disabled for ordinary play. The phase profiler reports only completed outer scopes and subtracts nested work.
- Profile within VU execution (decode/cache, hazard handling, upper/lower operations, pipeline retirement) before selecting the next optimization. Prefer a bounded process-local VU snapshot/replay workload for rapid repeatable testing; do not publish game microcode or data.
- Preserve floating-point edge cases, flags, pipeline timing, XGKICK order, and self-modifying microcode behavior while optimizing VU execution. The existing occupancy-mask optimization is already integrated.
- Measure dispatch/checkpoint costs before changing scheduler policy, but the new broad profile does not identify dispatch or waiting as the dominant gameplay cost.
- Investigate missing recompiled target `0x00504310`, reached by an indirect call at `0x001BD21C`. Probe 2251 continued and rendered, but this remains a correctness gap.
- Profile the runtime during actual first-level rendering, without thread suspension during correctness runs.
- Optimize the measured CPU triangle raster cost; preserve a full-rendering baseline for comparison.
- Improve sustained frame rate from the current single-digit range to practical interactive speed.
- Resolve the remaining CSR/IMR and three dispatch-test failures, and identify the local kernel-suite stall before broad scheduler changes. Registered host callbacks and missing-function policy must not be swallowed by game-specific non-code-call filters.

## Gameplay QA

- Validate process-local keyboard/controller input through the title, New Game, loading, and first level.
- Confirm Wolverine movement, camera tracking, HUD updates, enemy behavior, music, ambient police sirens, and stable frame progression over a sustained session.
- Confirm the user can close the runtime normally and that every automated probe closes its own process and restores the retail archive.
- Retain global white-wireframe mode as a diagnostic for 3D world and character geometry; normal textured rendering stays the default.

## Project Hygiene

- `ps2EntryRunner.profile.exe` has been replaced with the current early-depth/profiling candidate, SHA-256 `E2FD51A20AA01E687BA781FC6183936AD83FE8716418A38557773D274F3245AA`. It is no longer the rejected broad-dispatch experiment. The primary executable remains unchanged at `90D374181A33AFB9E872E44E7D5140E0685E4787AB654D33AB18EF5D56220105`.
- The tested candidate is now staged as `ps2EntryRunner.next.exe`, which existing staged-runtime launchers prefer. The primary remains the fallback; diagnostics remain opt-in.
- The stale `ps2EntryRunner.next.exe.exe` still needs removal once executable cleanup is permitted. A prior cleanup command was rejected by tool policy; do not retry that deletion through a workaround.
- September 4 checkpoint: workspace is 6.04 GiB across 27,521 files. Guarded artifact cleanup ran after probe 2258. All owned runtime and test processes are closed; the stalled kernel-suite process was explicitly stopped.
- Run the integrated probe cleanup, retain only useful diagnostic milestones, remove generated images older than 12 hours, and verify repository size.
- Do not modify or revert the user's dirty `dev-overrides/intro_normal.gameplay-map.py` or `inspect-igb-scene.py` files.
- Keep all compiler, recompiler, CMake, and MSBuild work BelowNormal, affinity `0xF`, one worker, and headless.

## Delivery

- Update the public repository README with setup requirements, legal asset expectations, build/run commands, controls, current limitations, and screenshots including first gameplay.
- Commit and push accepted OpenXML1 changes.
- Keep PS2Recomp changes general and focused; submit suitable fixes through the public fork and upstream pull requests.
- Recheck current upstream PS2Recomp pull requests before the next integration pass.
