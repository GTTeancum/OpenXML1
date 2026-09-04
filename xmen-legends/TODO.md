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
- Probe 2259 completed the sampled VU diagnostic through present 1200. Its 39 gameplay timing windows cover 44,364 ms. Among named sampled instruction stages, upper arithmetic and pipeline retirement are the largest. Do not treat the remaining outer-slice time as pure interpreter work: it includes instrumentation overhead, which is material for these very short helpers.
- Detailed VU instrumentation now requires the CMake option `PS2X_ENABLE_VU_DETAIL_PROFILE=ON` plus runtime variables `PS2X_RUNTIME_PHASE_PROFILE=1` and `PS2X_VU_DETAIL_PROFILE=1`. It samples 1/64 complete VU slices after tick 1000. Keep the CMake option OFF in ordinary gameplay builds so per-instruction profiling branches are absent.
- Operand-normalization inlining and an upper-NOP fast return passed all 93 local VU tests. Nine arithmetic-workload runs before/after retain digest `45e6d3166964d75e`; median execution time is 21.103 ms before and 19.971 ms after on this machine (about 5%). This is a synthetic workload, not a gameplay FPS measurement.
- Probe 2260 reached present 1200 and its native framebuffer confirms textured New York/Wolverine with the existing black-prop, HUD, and red-circle defects. It closed under the guard and restored the startup archive. Comparable complete diagnostic windows averaged 441.09 ms/frame before (2259, 98 frames) and 382.26 ms/frame after (2260, 96 frames), still about 2-3 FPS. These shared-machine, instrumented runs are not an isolated or sustained frame-rate guarantee.
- Submitted upstream PR #247, `https://github.com/ran-j/PS2Recomp/pull/247`, from commit `cf1efac` in the existing clean checkout. Both upstream-main-based test runs pass 427/427 with arithmetic digest `3308d7380e3bfe64`. The runtime change has no dependency on the occupancy-mask PR or X-Men-specific code. Bring-up commit `8cbe200` is pushed separately.
- The ordinary build with detailed profiling compiled out also passes 93/93 VU tests and preserves digest `45e6d3166964d75e`. Probe 2261 reached present 1280 with normal textured first-level output and existing lighting/HUD/effect defects. Neither phase nor raster profiler was enabled. External observation of native present-log entries 1152 to 1280 measured 128 frames in 46.576 seconds, approximately 2.748 FPS. This does not establish a meaningful overall improvement over the earlier roughly 2.7 FPS sample.
- Probe 2261's guard closed the runtime and restored the startup archive. Its tested ordinary binary is staged as `ps2EntryRunner.next.exe`; `probe2261-present1280.png` is the current native framebuffer checkpoint. The task remains active and practical interactive speed is not achieved.
- Probe 2258 reached present 1300, its native framebuffer shows textured New York and Wolverine with known black-prop/HUD/effect defects, and the guard closed the runtime and restored the startup archive. `probe2258-present1300.png` is the current checkpoint capture.
- Use `PS2X_RUNTIME_PHASE_PROFILE=1` for phase timings (`calls/inclusive-ms/exclusive-ms` per stage), `PS2X_GS_CPU_PROFILE=1` for raster-only timings, and `PS2X_GS_VERIFY_EARLY_DEPTH_PRESENT=<present>` for one-frame same-state triangle verification. Leave these disabled for ordinary play. The phase profiler reports only completed outer scopes and subtracts nested work.
- Added bounded process-local VU snapshot/replay in bring-up commit `eaee632`. Probe 2262 captured 32 real slices in 1,914,088 bytes; 4096 timed executions reproduce every register/pipeline field, all VU data bytes, and emitted GIF bytes/cycles, digest `75d4ff1e67bbbc4c`. See `VU-REPLAY.md`; the capture remains private in ignored `disc/vu-replay.bin`.
- Removed redundant same-cycle pipeline retirement scans and optimized contiguous PATH1 qword copying. Local VU tests pass 97/97, including boundary and zero/one-cycle resume checks. Retirement-only replay medians are 589.740 ms before and 564.147 ms after over nine interleaved pairs (about 4.3%). Packet-copy incremental timings were noisy; no independent gain or whole-game FPS improvement is claimed.
- Submitted upstream PR #248, `https://github.com/ran-j/PS2Recomp/pull/248`, commit `ebd1d34`. Clean upstream main passes 425/425 tests and the PR passes 426/426. It does not depend on earlier VU PRs or the replay diagnostics.
- Probe 2263 reached present 1280 with textured New York and Wolverine and the known black-prop, missing-foliage, and HUD defects. Native capture: `probe2263-present1280.png`. Replay and both performance profilers were off; detailed profiling was compiled out. External log observation measured 128 frames from 1152 to 1280 in 41.0026 seconds, or 3.1218 FPS. This is better than the earlier 2.748 FPS sample, but not an isolated or sustained-speed guarantee. The guard closed the runtime and restored the startup archive; the observer is also closed.
- Next performance candidate: replace the full 15-register scans in `calculatePairReadyCycle`, `markPairWrites`, and first-written-VI selection with iteration over their existing masks. Preserve VI0 exclusion, earliest dependency readiness, delayed branch reads, and one/four-cycle writes. Verify with the saved replay before another full boot. This change is not implemented yet.
- Small interpreter savings alone are insufficient for practical playability. Use the replay to quantify larger execution-path changes, and evaluate a compiled VU path if interpreter improvements plateau. Do not turn this into an unbounded series of full-boot micro-optimization probes.
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

- `ps2EntryRunner.profile.exe` and staged `ps2EntryRunner.next.exe` now match the Probe 2263 ordinary build, SHA-256 `FD9525591D6FD3773C8952C5CD679B9EE697D523D71AA3841DFAA507C6759EB1`. Detailed VU profiling is compiled out despite the candidate slot's filename. The primary executable remains unchanged at `90D374181A33AFB9E872E44E7D5140E0685E4787AB654D33AB18EF5D56220105`.
- The tested candidate is now staged as `ps2EntryRunner.next.exe`, which existing staged-runtime launchers prefer. The primary remains the fallback; diagnostics remain opt-in.
- The stale `ps2EntryRunner.next.exe.exe` still needs removal once executable cleanup is permitted. A prior cleanup command was rejected by tool policy; do not retry that deletion through a workaround.
- Cleanup of the temporary `ps2xTest/Release/ps2x_tests.vu-baseline.exe` and `ps2x_tests.vu-retire.exe` was also rejected by tool policy on September 4. These are about 10.4 MiB combined, not active runtime candidates. Leave them pending rather than retrying through another mechanism.
- September 4 checkpoint after Probe 2261: workspace is 6.039 GiB across 27,568 files. Guarded artifact cleanup ran again. All owned runtime, observer, test, and build processes are closed.
- September 4 checkpoint after Probe 2263: cleanup removed three old image artifacts (2.7 MiB); workspace is 6.050 GiB across 27,602 files, including the two policy-blocked benchmark executables. All owned runtime, observer, test, and build processes are closed.
- Fixed the 12-hour generated-image cleanup scope to include `xmen-legends` and its `disc` directory, not just inspection/build folders. A controlled old/fresh PPM fixture check proves the expired image is removed and the fresh one survives; both fixtures were cleaned up. Tracked README screenshots remain protected.
- Run the integrated probe cleanup, retain only useful diagnostic milestones, remove generated images older than 12 hours, and verify repository size.
- Do not modify or revert the user's dirty `dev-overrides/intro_normal.gameplay-map.py` or `inspect-igb-scene.py` files.
- Keep all compiler, recompiler, CMake, and MSBuild work BelowNormal, affinity `0xF`, one worker, and headless.

## Delivery

- Update the public repository README with setup requirements, legal asset expectations, build/run commands, controls, current limitations, and screenshots including first gameplay.
- Commit and push accepted OpenXML1 changes.
- Keep PS2Recomp changes general and focused; submit suitable fixes through the public fork and upstream pull requests.
- Recheck current upstream PS2Recomp pull requests before the next integration pass.
