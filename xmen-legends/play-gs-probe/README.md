# Headless GS Investigation

These isolated tools query GPU capabilities and test actual GPU drawing through
the pinned Play Vulkan offscreen renderer. They do not render the game, open a
window, or send interactive input. The rendering test creates a logical device
and shaders but no presentation surface. No GPU backend has been integrated into
PS2Recomp yet. Reuse the existing Play VU build tree.

The runtime adapter is now implemented and tested in isolation through the
actual `GSRasterBackend` interface. It is not selected by a game executable yet.

## Adapter Checkpoint

September 6 adapter test SHA-256:
`221DADAD0AA9023B9E935DE350CE34A29470B70666F1E1D1FFECDCE1BFA762C8`.
Twelve checks pass: sprite, independent strip triangle, split indexed upload,
palette load/skip/reload, local copy, local-to-host bytes, CPU presentation,
CPU clear/write imported to GPU, and reset preserving VRAM. Ten cases compare
all 4 MiB of VRAM; the other two compare transfer bytes and presentation pixels.

The adapter translates decoded batches into ordered register writes, caches
unchanged state/vertex attributes, and keeps GPU VRAM authoritative. CPU reads,
snapshots and display conversion synchronize it explicitly. The CPU delegate
retains transfer bookkeeping and display composition. Direct diagnostic writes
and clears import synchronized memory back to the GPU. These slow diagnostic
operations must not become per-pixel game rendering paths. No input, interrupts,
guest execution or scheduler logic was replaced.

Six alternating same-executable synthetic GPU/CPU timing pairs, three per
workload, include final full-memory readback and retain exact VRAM equality.
CPU reference is AVX2 with prepared indexed sampling enabled:

| Workload | GPU ms (three runs) | CPU ms (three runs) |
| --- | --- | --- |
| 23,424 small 8x8 triangles | 7.082, 11.631, 6.917 | 36.595, 41.703, 29.984 |
| 512 large 160x112 triangles | 5.653, 6.280, 4.436 | 156.694, 160.334, 156.607 |

These are nearest-filtered synthetic scenes on a shared machine, not gameplay
FPS or a sustained rate guarantee. The game remains at its previous measured
rate until runtime integration and a real first-level benchmark are completed.

Initial bridge `E0F024AB...` was slower on tiny triangles. After attribute-write
caching, `FC7765DC...` still spent 25-36 ms in readback, including 33 ms for a
single warmup triangle. `framework-cached-readback.patch` fixes that bottleneck:
staging buffers prefer HOST_CACHED memory, fall back to required HOST_VISIBLE
memory when unavailable, and invalidate mapped memory after GPU completion to
support non-coherent memory. Existing allocation callers retain their required
properties. The Vulkan function pointer is loaded, moved and reset consistently.
Readback now takes roughly 3-7 ms in this run, including pending rendering.
Other hardware/fallback memory types have not been tested.

The original five offscreen cases still pass after the patch, executable
`F4E920011A98687C377AC0CAB81577D7E82EA59507EAEA7884AD168D9D29CAF0`.
The patch reverse-checks cleanly and is required by CMake. Nothing was submitted
upstream or linked into a new game build.

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
git -C .tools/Play-VU/deps/Framework apply (Resolve-Path ./xmen-legends/play-gs-probe/framework-cached-readback.patch).Path
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -ConfigureCache OPENXML1_BUILD_GS_PROBE=ON
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_capabilities
& ./xmen-legends/play-gs-probe/test-capabilities.ps1
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_offscreen
& ./xmen-legends/play-gs-probe/test-capabilities.ps1 -Offscreen
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_gs_adapter_test
& ./xmen-legends/play-gs-probe/test-capabilities.ps1 -Adapter
& ./xmen-legends/play-gs-probe/test-capabilities.ps1 -Adapter -Benchmark
```

Apply the patch only once; the current working checkout already has it. Use an
absolute patch path if invoking Git from another directory. The adapter runner
clears inherited PS2X diagnostics and enables the prepared CPU sampler. Optional
timings reuse `adapter-benchmark.log`; ordinary checks reuse `adapter.log`.

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

The isolated adapter now implements the initial plan below. Next wire it into
the real runtime as an opt-in backend, preserve CPU default selection, add
positive execution evidence to benchmark gates, and build a measured candidate.
Use the existing external `runtime-engine.cmake` integration pattern; the GS
frontend constructor can wrap its CPU backend before initialization. Provide a
runtime-local config path, not the probe's current-working-directory config.

Remaining game integration checks:

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

The adapter tests do not prove all depth/blending/fog/filtering combinations or
real level fidelity. CPU VU execution remains a major cost, so GPU rendering alone is
not a promised route to 30 FPS. No gameplay candidate was linked this turn.

Regular cleanup removed 225 stale Debug directories and 29 obsolete files,
approximately 18 MiB. New zlib/zstd source working trees total 12.31 MiB; the
isolated GS build subtree is 39.67 MiB. No new images, emulator checkout, or
duplicate game executable. All work remains local; no pushes or pull requests.
