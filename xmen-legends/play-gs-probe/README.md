# Headless GS Investigation

These isolated tools query GPU capabilities and test actual GPU drawing through
the pinned Play Vulkan offscreen renderer. They do not render the game, open a
window, or send interactive input. The rendering test creates a logical device
and shaders but no presentation surface. An opt-in runtime adapter now connects
this renderer to PS2Recomp. Reuse the existing Play VU build tree.

The runtime adapter uses the actual `GSRasterBackend` interface. CPU rendering
remains the default; enabling the CMake option alone does not select Vulkan.

## Runtime Integration

Enable `OPENXML1_PLAY_GS_BACKEND=ON` in the existing runtime build, build
`ps2_runtime`, then link the candidate through the resource-limited wrapper.
The existing external VU runtime hook includes `runtime-engine.cmake`. Its
adapter refresh depends on the VU refresh to serialize the shared build tree.
Only the GS frontend source receives `PS2X_ENABLE_PLAY_GS_BACKEND`; at runtime,
`PS2X_GS_PLAY_VULKAN=1` selects the adapter. Without that environment variable,
the same executable uses the unchanged CPU backend.

The factory wraps the CPU delegate after the frontend's constructor reset.
The PS2Recomp factory hook is local commit `fc8105d` on
`codex/xmen-legends-bringup`; it has not been pushed.
Pre-initialization reset/flush are safe and covered by the isolated adapter
test. Configuration lives under `.ps2recomp-vulkan` in the runtime working
directory, not global Play settings. GPU execution and nonblack presentation
markers are required by the benchmark's Vulkan workload gate.

The game integration reuses its existing `ffmpeg_zlib` import target. Linking
Play's separate vanilla `zlibstatic` originally caused duplicate inflate
symbols; that library was removed from the game's link dependencies before
execution. The standalone tests retain their own zlib dependency. Do not enable
`Z_PREFIX` blindly: Play's zstd wrapper already supplies the `z_` entry points.

```powershell
& ./xmen-legends/build-below-normal.ps1 -ConfigureCache OPENXML1_PLAY_GS_BACKEND=ON
& ./xmen-legends/build-below-normal.ps1 -Target ps2_runtime
& ./xmen-legends/build-below-normal.ps1 -LinkOnly -OutputName ps2EntryRunner.candidate
& ./xmen-legends/run-gameplay-benchmark.ps1 -CompiledVu -VulkanGs -CaptureFrame
```

This bounded benchmark disables host input and restores the startup scripts
when it exits. It is not an interactive handoff. Vulkan cannot be combined with
CPU sampler/raster diagnostics; compiled-VU audits remain available and are
excluded from FPS results. The normal interactive launcher is not switched to
Vulkan by this integration.

### Game Evidence

September 6 rate-comparison executable:
`AED1D5E3D2CD0397249FCB7001EC4D389D7965B36F5EEA844E94CB872AB1DC90`.
One serial, same-binary pair measured **5.216032 FPS Vulkan / 4.939020 CPU**
(prepared sampler), using external observations of presents 1152..1280.
This is a shared-host observation, not a robust speedup or sustained rate;
30 FPS remains unmet. Both runs exited zero at vsync 1400, logged zero guest
faults, verified New Game/NYC/native blocks, and restored startup. Vulkan
reported 18,499,465 submissions and 253,367 nonblack pixels at present 1280.

Native present 1280 was inspected after lossless PPM-to-PNG conversion. It shows
NYC, Wolverine, ground/building/fence textures and the question marker, but
black props, missing foliage and broken HUD remain. No visual-fidelity pass,
new manual input result, or combat verification is claimed. PPM SHA-256:
`1C4A0716522273056A90EC5B8BE2C7DF009BEEC0437341B2C9FCE165DB86A993`.
Only that native frame was captured; no desktop/window capture was used.

The final diagnostic candidate is
`5CDB5EB63A9A03A238F3B09A3D5222BCBFB9D2DA0E680939851AADB494F68990`.
Its added adapter scopes use the existing opt-in runtime phase profiler,
including submission, transfers, lock waits inside the adapter and readback.
Presentation is a separate thread with tick zero: do not combine its wall-time
percentages with the guest thread or mistake these scopes for GPU timestamps.
The first Vulkan profile failed at guest PC `0x4c004000`, RA `0x396e70`,
`s0=s1=v0=0`, before the gameplay markers. The benchmark rejected the run despite
host exit zero. Fixed `gameplay-vulkan-failure.*` slots preserve both fault lines
and the report; no FPS is accepted from that run. Retail code at `0x396e68`
calls an object method; `0x398630` returns its second argument unchanged. The
record is consistent with a null-object call, but its originating cause is
unproven. A related earlier CPU-side failure had RA `0x396e84`; this similarity
is not proof that the new failure has the same cause or is harmless.

An unchanged-candidate Vulkan profile repeat passed every workload gate, exit
zero / vsync 1400, zero guest faults, 18,816,871 GPU submissions, startup restored.
The first failure remains unresolved and preserved; a passing repeat is not a
fix. The CPU control also reached both gameplay markers and exited zero with no
guest faults, but its gate rejected an interleaved diagnostic:
`[gs:black-present] index=19[gs:prepared-texture] active=1`.
Do not silently mark that report verified. Next serialize multi-part diagnostic
messages before relying on line-start marker recognition in further comparisons.

Complete guest-thread profile windows with their preceding tick >=1100 and end
tick <=1399 give the following descriptive timings. CPU data is diagnostic-only
because of the marker failure above; neither profile is an FPS measurement.

| Mode | Windows / tick endpoints | Wall ms | VU exclusive ms | GS exclusive ms |
| --- | --- | --- | --- | --- |
| CPU prepared | 54 / 1111..1397 | 56,771.506 | 30,064.306 (52.96%) | 17,113.173 (30.14%) |
| Vulkan | 45 / 1110..1395 | 46,319.808 | 31,063.555 (67.06%) | 5,386.387 (11.63%) |

The scenes cover similar, not identical tick spans on a shared host. GPU
presentation runs on another thread and is excluded here; the table is not a
total GPU-cost comparison. Next target substantial VU execution/bridge overhead
with matched real-workload profiling, not another sampler-only optimization.
Retain the guarded, exact replay tests; do not remove fidelity checks merely to
report a faster number. All commits remain local, no interactive promotion.

## Adapter Checkpoint

September 6 adapter test SHA-256:
`109008AC47E59CFD493F77809E62C4E1FADDF9512BFFF7F6A780058DF33360D4`.
Twelve checks pass: sprite, independent strip triangle, split indexed upload,
palette load/skip/reload, local copy, local-to-host bytes, CPU presentation,
CPU clear/write imported to GPU, and reset preserving VRAM. Ten cases compare
all 4 MiB of VRAM; the other two compare transfer bytes and presentation pixels.
Reset and flush before initialization are also exercised. The synthetic timing
table below belongs to preceding test image `221DADAD...`, not a new benchmark
of the profiled adapter.

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
FPS or a sustained rate guarantee. The runtime measurements above supersede
the earlier isolated-only status; they do not meet the performance target.

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
upstream. This was the isolated checkpoint before runtime integration.

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

The opt-in integration and initial runtime comparison are implemented. Resolve
the diagnostic failure, measure remaining execution/submission/readback costs,
and retain CPU fallback. No interactive promotion is justified by the current
performance. Remaining fidelity/integration requirements are listed below.

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
not a promised route to 30 FPS. Game integration remains experimental.

Earlier isolated cleanup removed 225 stale Debug directories and 29 obsolete files,
approximately 18 MiB. New zlib/zstd source working trees total 12.31 MiB; the
isolated GS build subtree was 39.67 MiB at that checkpoint. Integration cleanup
removed another 208 stale Debug directories and two obsolete files, about 7 MiB.
Only one native gameplay frame and its lossless PNG conversion were added during
integration. The existing candidate executable slot was reused; no new emulator
checkout or backup executable. All owned builds/tests/games ended, startup was
restored, and work remains local with no pushes or pull requests.
