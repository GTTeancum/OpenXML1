# X-Men Legends PS2Recomp Handoff

## Objective

Reach sustained, controllable first-level gameplay at 30 FPS with fresh full-world
frames. SFD playback is out of scope. Do not hand a build to the user until movement,
nonblack coverage, fresh presentation, fault, and allocation gates all pass.

## Current Blocker

Synthetic movement now reproduces the user's "move a few feet, then freeze" report
without host input. The failure is compatibility-heap exhaustion during renderer slot
growth, followed by null writes and sometimes a corrupt virtual call. Audio and VSync
continue, explaining why the title-bar FPS can rise after gameplay freezes.

The first causal sequence in the no-best-fit run is:

```text
[xmen-render-slot-grow-enter] ... oldBase=0x1754000 bytes=0xf60 alignment=0x10
[xmen-render-slot-grow-return] ... newBase=0x0 allocationResult=0x0
[memset] rejecting null-page write dst=0xf00 size=0x60
[guest-branch:missing-target] ... source=0x1391dc target=0x1001f
```

Guest `0x1391DC` is `jr t9`; `t9` comes from vtable slot `+0x94` after loading the
object from `a0+4`. It is downstream damage, not the first failure.

## Decisive Runs

Known reference runtime:

```text
Executable: PS2Recomp/out/xmen-final3-build/ps2xRuntime/Release/ps2EntryRunner.c73d184-ref.exe
SHA-256: 057DADD210355458AC3763E3A8EAA62036CF8422BFAF7C810E77FF26664526AA
PS2Recomp source commit: c73d184
```

No best-fit, movement ticks 500-1300, limit 1400:

```text
Log:  PS2Recomp/out/xmen-final3-build/gameplay-vulkan-rate-efu-stream-batch-stream-block-32-cache-realloc-move-frame-hashes.err.log
JSON: PS2Recomp/out/xmen-final3-build/gameplay-vulkan-rate-efu-stream-batch-stream-block-32-cache-realloc-move-frame-hashes.json
Result: 15 broad world samples, then allocationResult=0 and bad jump at 0x1391DC.
```

Best-fit plus in-place realloc, same movement and limit:

```text
Log:  PS2Recomp/out/xmen-final3-build/gameplay-vulkan-rate-efu-stream-batch-stream-block-32-cache-best-fit-realloc-move-frame-hashes.err.log
JSON: PS2Recomp/out/xmen-final3-build/gameplay-vulkan-rate-efu-stream-batch-stream-block-32-cache-best-fit-realloc-move-frame-hashes.json
Result: 25 broad world samples and no guest fault, but the same render-slot allocation
        fails near tick 935. Frame hash 8CA3FA69... then repeats through tick 1383.
```

Reproduction command:

```powershell
& .\xmen-legends\run-gameplay-benchmark.ps1 `
  -RuntimePath .\PS2Recomp\out\xmen-final3-build\ps2xRuntime\Release\ps2EntryRunner.c73d184-ref.exe `
  -StartupMovieMode TitleGameplayFirst -VulkanGs -CompiledVu -CompiledEfu `
  -CompiledStream -CompiledStreamBatch -CompiledStreamBlockBytes 32 -RetainVuCache `
  -BestFitHeap -InPlaceRealloc -HeapDiagnostics `
  -AutoMoveAtTick 500 -AutoMoveTicks 500 -RunVsyncLimit 1000 -TimeoutSeconds 300
```

The final heap-diagnostic run was interrupted before the first failure. Rerun the
command above first. It should stop on `[heap:allocation-failed]` and print total free
bytes, largest hole, live allocation count, size histogram, and call chain.

## Ruled Out

- No-input control, fixed-tick synthetic movement, and manual input all reach the same
  presentation failure class.
- Disabling the public compatibility-free interception did not restore the handoff.
- Restoring legacy free semantics for allocator slot `0x233ED0` did not restore it.
- Dense 4-byte allocation granularity perturbed loading and lost gameplay before input;
  it is removed and must not be promoted.
- Passive scene-handoff logging and unconditional player/camera tracking were removed;
  neither explained the allocator failure.
- Best-fit placement alone changes the terminal corruption but does not prevent the
  allocation failure or stale framebuffer.
- Do not expand the arena above `0x01800000` without ownership proof. The game has a
  custom heap beginning there, and the EE stack is near `0x01F1xxxx`.

## Precise Astra Question

Determine which compatibility-heap ownership or lifetime invariant is missing such
that renderer slot reallocations exhaust `0x00900000..0x01800000` during sustained
gameplay. Use the diagnostic allocation call chain and live/free histogram to choose
between a missed free route, incorrect owner dispatch, realloc lifetime error, or
fragmentation defect. Recommend the smallest correctness-preserving experiment.

Astra is requested for consultation and root-cause selection. Sol High can implement
and run the repetitive validation afterward.

## Guardrails

- Fixed-tick process-local input already exists through
  `PS2X_AUTOMOVE_LEFT_STICK_AT_TICK`; do not add host OS input or Computer Use.
- `run-gameplay-benchmark.ps1` now rejects failed render-slot growth explicitly.
- Run all owned compilers at BelowNormal, affinity `0xF`, one worker, 2048 MiB maximum.
- Close every owned runtime after a bounded test.
- Keep PS2Recomp commits local. Do not open more upstream PRs yet.
- Preserve the primary executable. Link experimental names only.
- Continue regular cleanup; generated images older than 12 hours are disposable.
