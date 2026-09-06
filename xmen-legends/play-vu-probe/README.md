# Isolated Play! VU Compiler Probe

This builds only the VU compiler, its supporting stream code, and the 21 existing
VU test cases from [Play!](https://github.com/jpd002/Play-). It does not link to
PS2Recomp, read game media, create a game window, or enable a replacement engine.
There is no gameplay FPS claim or interactive handoff yet.

## Sources

The ignored `.tools/Play-VU` checkout is pinned by CMake to these revisions:

| Repository | Revision |
| --- | --- |
| Play! | `83700b2c31e593bc94e845b4b31b797be84dda59` |
| CodeGen | `a5009f7dca062695b8e5aebbd71e67b4ddfa9251` |
| Framework | `587f278917acc0026bf5fc34b39f995fc26bd015` |
| Dependencies | `8a5f6b1dea0b888b5a42b821e79470142bbea4e3` |
| xxHash | `e626a72bc2321cd320e953a0ccf1584cad60f363` |

Only Framework, CodeGen, Dependencies, and Dependencies/xxHash are initialized.
Keep the existing checkout; do not create parallel clones or build variants.
The complete reference plus this Release build occupies approximately 70 MiB.

Play!, CodeGen, and Framework retain their BSD-2-Clause `License.txt` files.
xxHash retains its upstream licensing, and `FpAddTruncate.cpp` retains its embedded
LLVM/compiler-rt attribution. No upstream implementation or license is rewritten
by this probe. Preserve the relevant notices if these components are distributed.

## Build And Run

From the OpenXML1 root, configure once with MSVC x64. Lower the configuring shell's
priority before launching CMake, so compiler-identification children inherit it:

```powershell
$self = [Diagnostics.Process]::GetCurrentProcess()
$self.PriorityClass = 'BelowNormal'
$self.ProcessorAffinity = [IntPtr]0xF
cmake -S xmen-legends/play-vu-probe -B .tools/Play-VU/out/vu-probe -G 'Visual Studio 17 2022' -A x64
& ./xmen-legends/build-below-normal.ps1 -BuildPath .tools/Play-VU/out/vu-probe -Target play_vu_probe
& ./xmen-legends/play-vu-probe/test.ps1
```

The normal build wrapper retains one worker and a 2048 MiB compiler limit. Tests
run without a console window at Normal priority on four logical processors.

## Verified Contracts

Release executable SHA-256:
`308ED2C1DB18B2D283201AEE20E0DE374B21C3C183076A0ED1B34B543CB6FD96`.

- All 21 unmodified upstream test cases pass, including arithmetic, flags,
  branch delays, stalls, and mixed division/EFU behavior. This is not a claim of
  compatibility with every PS2Recomp replay or X-Men microprogram.
- A 66-pair NOP/end program runs all 66 pipeline cycles for each executor quota
  of 1, 2, 8, and 64. Remaining quotas are -131, -130, -124, and -68: this API
  charges instruction words at block boundaries, not exact elapsed VU cycles.
- XGKICK reports a qword address. Its callback runs after the following lower
  instruction: a following SQ has already changed the memory visible to it.
  The callback still sees `pipeTime=0`, while the completed four-pair program
  ends with `pipeTime=4`. The callback therefore does not supply an exact event
  timestamp suitable for PS2Recomp's streaming PATH1 transfer implementation.

These are characterization assertions of the pinned engine, not assertions that
its interface already satisfies PS2Recomp's scheduling requirements. Do not
replace `VU1Interpreter::resume` with `CVuExecutor::Execute` or copy only registers
while discarding pending writes, flags, or active graphics transfers.
The upstream test environment also selects round-toward-zero and flushes
denormals. Any in-process bridge must preserve and restore the caller's floating
point environment instead of changing EE, audio, or other host calculations.

Next: bridge explicit cycle/graphics events and validate architectural results,
memory writes, and packet ordering against the existing private recordings before
measuring throughput. Those recordings contain mid-program state, not fresh VU
entry snapshots, so importing their visible registers alone is invalid.

No game executable should be linked or packaged until the larger performance
change has measured benefit. The title/FPS counter stays queued for that build.
