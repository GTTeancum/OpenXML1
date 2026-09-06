# Headless GS Investigation

This isolated tool queries GPU capabilities. It does not render the game or
create a window, surface, logical device, or interactive input. No GPU backend
has been integrated into PS2Recomp. Reuse the existing Play VU build tree.

## Dependencies

- Play: `83700b2c31e593bc94e845b4b31b797be84dda59`, existing `.tools/Play-VU`.
- Vulkan-Headers: `ee2ec5fd83dafce291024683b50dc89219333076`, sparse checkout
  in `.tools/Vulkan-Headers` (include and licenses). CMake verifies the revision.
- Nuanceur: `d96578b5a18edc67a268ed4811f0a035c56de7a0`, initialized inside
  the existing Play checkout for subsequent renderer work, not linked here.

The capability executable dynamically loads the system `vulkan-1.dll`.
No full Vulkan SDK, separate emulator checkout, or game assets are required.

## Run

From the OpenXML1 repository root in PowerShell:

```powershell
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -ConfigureCache OPENXML1_BUILD_GS_PROBE=ON
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_capabilities
& ./xmen-legends/play-gs-probe/test-capabilities.ps1
```

Builds use the existing BelowNormal resource-limited wrapper. The hidden query
runs at Normal priority with affinity 0xF and a 60-second timeout. Its fixed
`capabilities.log` records the executable hash and output. A successful query
can report zero eligible GPUs; query success is not rendering success.

## Evidence

September 6, 2026 executable SHA-256:
`F80C6696E19B11BC71FC10049D813CB77F44DBD1798C3BD8A1A999A698E4BDAF`.

AMD Radeon 780M Graphics reports Vulkan 1.4.344, pixel interlock, fragment
stores/atomics, shader Int16/Int8, 8-bit and 16-bit storage/uniform storage,
swapchain support and graphics/compute on queue family zero. These match the
features explicitly requested by the pinned desktop Play CreateDevice path.
Rasterization-order extension support is absent; it is not part of this gate.
The summary explicitly records `rendering-tested=0 windows=0`.

## Next Gate

Build the existing Play `GSH_VulkanOffscreen` implementation in isolation and
verify actual primitive/indexed-texture output through framebuffer readback.
Its `GetScreenshot` is empty; use `GetFramebuffer`, which synchronizes VRAM.
Keep probe configuration local instead of touching the user's Play preferences.
Before game integration, preserve transfer ordering, CLUT load/skip events,
framebuffer aliasing and CPU/GPU ownership. A device feature check alone proves
neither correct pixels nor a gameplay speedup. CPU VU execution also remains a
major cost, so GPU rendering alone is not a promised route to 30 FPS.
