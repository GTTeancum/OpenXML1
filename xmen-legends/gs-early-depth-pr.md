## Summary

Reject depth-failing triangle pixels before color interpolation, texture sampling, and fog. This applies only to enabled GEQUAL/GREATER tests; passing pixels retain the existing WritePixel path, including its depth test. Sprites, lines, alpha-test behavior, blending, framebuffer/depth masks, and depth-format conversion are unchanged.

`PS2X_GS_DISABLE_EARLY_DEPTH=1` restores the reference path at process launch for differential checks.

## Validation

- Windows x64 Release build: 427/427 tests pass.
- GEQUAL/GREATER/ALWAYS/NEVER comparisons, equal-depth boundaries, four depth formats, and ZMSK have explicit expected-store checks.
- A deterministic 128-case workload exercises palettized textures, point/linear filtering, UV/STQ, alpha tests, destination-alpha tests, fog, blending, and masks. The complete 4 MiB VRAM result is hashed after every case. Both paths produce digest `e1af4f1cfc948cc3` on this build.
- Run both complete suites and compare their digests with:

```powershell
cmake -DTEST_EXECUTABLE=C:/path/to/ps2x_tests.exe -P ps2xTest/cmake/CompareGsEarlyDepth.cmake
```

## Downstream Measurement

In an X-Men Legends bring-up branch with other runtime fixes, a same-executable on/off comparison across 301 gameplay frames reduced mean CPU raster time from 98.98 ms to 63.03 ms, approximately 36%. This is a downstream rasterization measurement, not a claim about whole-game FPS or upstream-main performance.

A separate downstream verification replayed all 23,042 triangle submissions in one live gameplay frame against private copies of their starting VRAM and CLUT state, comparing every VRAM byte after each draw. There were zero mismatches. That diagnostic harness and the game's data are not part of this PR.

## Limits

This is an incremental software-rasterizer optimization, not a fix for existing visual defects. Passing pixels incur an extra depth read. Low-overdraw workloads may benefit less or regress; the reference switch is retained for comparisons.
