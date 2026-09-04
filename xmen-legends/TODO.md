# X-Men Legends PS2Recomp TODO

Work resumed on 2026-09-04 at the user's request.

## Resume Point

- Keep SFD playback out of scope. The target remains basic first-level playability.
- Preserve the known-good primary runtime at `PS2Recomp/out/xmen-final3-build/ps2xRuntime/Release/ps2EntryRunner.exe`.
- Review the uncommitted `ps2_runtime.cpp` candidate before keeping it. Only environment-lookup caching remains. The unconditional early-dispatch experiment was removed; the original bypass gate and checkpoint batching are restored. The smaller change is compiled but not promoted to the primary executable or committed.
- Probe 2251 re-established textured first-level rendering with the known-good primary runtime, `TitleGameplayFirst`, host clock, fast legal handling, aggressive branch-hook bypass, and full CPU rasterization. `probe2251-present1099.png` is the current gameplay evidence.
- User testing confirmed that Wolverine can move and basic combat works in the first level, although gameplay is currently extremely slow.
- Do not use `PS2X_SKIP_CPU_RASTER_BEFORE_PRESENT` for correctness or visual validation with host-clock pacing. Probe 2248 reached the NYC package quickly but later entered an invalid guest state and rendered black.
- Previous selected-source performance conclusions are invalidated: the helper compiled objects without rebuilding `ps2_runtime.lib`, so candidate executables could still contain old code. Do not conclude that environment caching failed or checkpoint batching caused a fault from those runs.
- Fixed the helper to run `_Lib` without `SelectedFiles` after a successful static-library source compile. Ordinary and unity-build regression tests prove candidate behavior changes, untouched library code remains available, and the primary executable is preserved.
- Probe 2252 reproduced full-rendering first-level progression to present 1140 with the unchanged primary. Across presents 1000-1140, CPU rasterization averaged 94.57 ms (44.60 ms triangle lists, 46.35 ms strips), about 23,424 submissions per frame. This is raster time, not total frame time.
- Probe 2253 tested the verified rebuilt candidate with the usual bypass enabled. Its present-1140 native capture confirms textured New York and Wolverine with the existing black props/HUD defects. The corrupted image at present 768 was still loading, not a permanent world-rendering regression. First batches over 20,000 submissions occurred at present 964 in Probe 2252 and 1010 in Probe 2253; do not compare an arbitrary earlier present as if loading had finished.
- Probe 2254 tested the broader early dispatcher with per-branch checkpoints, reached present 1140, and closed normally under the guard. This experiment was not retained. Concurrent test/build work makes its elapsed time unsuitable for a clean performance comparison. No practical frame-rate improvement is established.
- Focused tests after restoring the original dispatch control flow: VU 91/91; GS 76/79; dispatch 2/5. The three dispatch failures reproduce with and without the early-path change: indirect-call registration/return and missing-target tests encounter existing non-code-call filters. The three GS failures concern CSR/IMR access and two T4 triangle sampling cases. The full suite was interrupted; do not report a full-suite pass.

## Performance And Correctness

- Measure dispatch/checkpoint costs using a verified rebuilt candidate before changing scheduler policy.
- Re-run the remaining environment-cache candidate only against a matched baseline. Keep startup flags, test load, and input conditions fixed, and compare completed gameplay rather than a loading frame.
- Investigate missing recompiled target `0x00504310`, reached by an indirect call at `0x001BD21C`. Probe 2251 continued and rendered, but this remains a correctness gap.
- Profile the runtime during actual first-level rendering, without thread suspension during correctness runs.
- Optimize the measured CPU triangle raster cost; preserve a full-rendering baseline for comparison.
- Profile VU1 only after the faster route reliably reaches the level; then optimize decode, hazard, execute, or retire work according to measurements.
- Improve sustained frame rate from the current single-digit range to practical interactive speed.
- Resolve the six focused test failures before promoting broad dispatcher or GS changes. Registered host callbacks and missing-function policy must not be swallowed by game-specific non-code-call filters.

## Gameplay QA

- Validate process-local keyboard/controller input through the title, New Game, loading, and first level.
- Confirm Wolverine movement, camera tracking, HUD updates, enemy behavior, music, ambient police sirens, and stable frame progression over a sustained session.
- Confirm the user can close the runtime normally and that every automated probe closes its own process and restores the retail archive.
- Retain global white-wireframe mode as a diagnostic for 3D world and character geometry; normal textured rendering stays the default.

## Project Hygiene

- Remove `ps2EntryRunner.profile.exe` (rejected broader experiment), the stale `ps2EntryRunner.next.exe.exe`, and the redundant `ps2EntryRunner.next.exe` once executable cleanup is permitted. The cleanup command was rejected by tool policy and these files remain; do not select the profile executable. Primary and staged hashes both remain `90D374181A33AFB9E872E44E7D5140E0685E4787AB654D33AB18EF5D56220105`.
- September 4 checkpoint: workspace is 6.03 GiB across 27,495 files. Guarded artifact cleanup ran; both build-test temporary directories self-cleaned. All launched runtime and test processes are closed.
- Run the integrated probe cleanup, retain only useful diagnostic milestones, remove generated images older than 12 hours, and verify repository size.
- Do not modify or revert the user's dirty `dev-overrides/intro_normal.gameplay-map.py` or `inspect-igb-scene.py` files.
- Keep all compiler, recompiler, CMake, and MSBuild work BelowNormal, affinity `0xF`, one worker, and headless.

## Delivery

- Update the public repository README with setup requirements, legal asset expectations, build/run commands, controls, current limitations, and screenshots including first gameplay.
- Commit and push accepted OpenXML1 changes.
- Keep PS2Recomp changes general and focused; submit suitable fixes through the public fork and upstream pull requests.
- Recheck current upstream PS2Recomp pull requests before the next integration pass.
