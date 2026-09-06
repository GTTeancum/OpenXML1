# Headless GS Investigation

These isolated tools query GPU capabilities and test actual GPU drawing through
the pinned Play Vulkan offscreen renderer. They do not render the game, open a
window, or send interactive input. The rendering test creates a logical device
and shaders but no presentation surface. No GPU backend has been integrated into
PS2Recomp yet. Reuse the existing Play VU build tree.

## Dependencies

- Play: `83700b2c31e593bc94e845b4b31b797be84dda59`, existing `.tools/Play-VU`.
- Vulkan-Headers: `ee2ec5fd83dafce291024683b50dc89219333076`, sparse checkout
  in `.tools/Vulkan-Headers` (include and licenses). CMake verifies the revision.
- Nuanceur: `d96578b5a18edc67a268ed4811f0a035c56de7a0`, initialized inside
  the existing Play checkout; linked into the offscreen renderer.
- zlib: `5a82f71ed1dfc0bec044d9702463dbdf84ea3b71` and zstd:
  `f8745da6ff1ad1e7bab384bd1f9d742439278e99`, existing Play Dependencies
  submodules, needed by shared GS save-state support. Source remains unmodified.

The capability executable dynamically loads the system `vulkan-1.dll`.
No full Vulkan SDK, separate emulator checkout, or game assets are required.

## Run

From the OpenXML1 repository root in PowerShell:

```powershell
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -ConfigureCache OPENXML1_BUILD_GS_PROBE=ON
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_capabilities
& ./xmen-legends/play-gs-probe/test-capabilities.ps1
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_offscreen
& ./xmen-legends/play-gs-probe/test-capabilities.ps1 -Offscreen
```

Builds use the existing BelowNormal resource-limited wrapper. The hidden query
runs at Normal priority with affinity 0xF and a 60-second timeout. Its fixed
`capabilities.log` records the executable hash and output. A successful query
can report zero eligible GPUs; query success is not rendering success. The
offscreen mode instead requires all five rendering cases and 20,480 matched
pixels. Its executable hash/output reuse the fixed `offscreen.log` slot.
Probe configuration stays in the test working directory, not Play user settings.

## Evidence

September 6, 2026 executable SHA-256:
`F80C6696E19B11BC71FC10049D813CB77F44DBD1798C3BD8A1A999A698E4BDAF`.

AMD Radeon 780M Graphics reports Vulkan 1.4.344, pixel interlock, fragment
stores/atomics, shader Int16/Int8, 8-bit and 16-bit storage/uniform storage,
swapchain support and graphics/compute on queue family zero. These match the
features explicitly requested by the pinned desktop Play CreateDevice path.
Rasterization-order extension support is absent; it is not part of this gate.
The summary explicitly records `rendering-tested=0 windows=0`.

Offscreen renderer executable SHA-256:
`E41DD2A3F5886FD0AAC5CA4FA8AED7B1E7CE8DD52EAE7940F5D6189B4DCED082`.
All five cases pass, exit 0, with every pixel in each 64x64 target region checked:

- Untextured 16x16 sprite and a separate square drawn by two triangles.
- PSMT8 indexed texture covering all 256 CT32 palette colors with CSM1 mapping.
- Palette memory changed, CLD=0: previous loaded palette remains in use.
- CLD=1: newly uploaded palette becomes visible.
- Texture indices changed, CLD=0: new indices use the retained palette.

Each indexed case also checks that the triangles and untouched black pixels
remain unchanged. Data travels through the renderer's GS transfer/register
interfaces, not direct synthetic framebuffer writes. `GetFramebuffer` flushes
and synchronizes native GPU memory for verification. The initial sprite test
failed because it expected RGBA while Play `ReadImage32` explicitly exports BGRA;
the test now normalizes that documented source behavior before comparison.
No renderer source patch was needed. This proves these synthetic cases only,
not correct game rendering, gameplay FPS, depth/blending, or every GS format.

## Next Gate

Implement an opt-in adapter at the existing `GSRasterBackend` interface, with
synthetic equivalence tests before a performance candidate:

- `Submit` receives complete decoded state/vertices. Translate strips/fans as
  independent triangles, preserving provoking color and raw XYOFFSET units.
  Avoid submitting duplicated register state per pixel or synchronizing per draw.
- `LoadClut` already receives ordered TEX0/TEXCLUT events. Preserve their CLD
  decisions; setting TEX0 for a batch must not trigger another palette reload.
- Forward `BeginTransfer`/`UploadImage` in order. Establish authoritative GPU
  VRAM with explicit readback for CPU reads, snapshots and backend handoff.
  `GetRam` alone is not synchronized. Validate partial and aliasing transfers.
- Preserve PS2Recomp's existing presentation-selection/composition behavior,
  initially reusing CPU display conversion after a bounded native readback.
  Keep the existing CPU raster backend available and unchanged by default.
- Leave GS interrupt/timing ownership with PS2Recomp. No replacement input,
  scheduler, guest execution, or game logic is needed for this adapter.

The interface inspection supports this plan, not a claim that the adapter is
implemented. CPU VU execution remains a major cost, so GPU rendering alone is
not a promised route to 30 FPS. No gameplay candidate was linked this turn.

Regular cleanup removed 225 stale Debug directories and 29 obsolete files,
approximately 18 MiB. New zlib/zstd source working trees total 12.31 MiB; the
isolated GS build subtree is 39.67 MiB. No new images, emulator checkout, or
duplicate game executable. All work remains local; no pushes or pull requests.
