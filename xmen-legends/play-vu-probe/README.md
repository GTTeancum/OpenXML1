# Isolated Play! VU Compiler Probe

This builds only the VU compiler, its supporting stream code, and the 21 existing
VU test cases from [Play!](https://github.com/jpd002/Play-), plus isolated contract
tests and an optional private VU-recording diagnostic. It does not link to
PS2Recomp, read the ISO, create a game window, or enable a replacement engine.
There is no gameplay FPS claim or interactive handoff yet.

## Sources

The ignored `.tools/Play-VU` checkout is pinned by CMake to these revisions,
with the required local CodeGen patch described below:

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
LLVM/compiler-rt attribution. Only the x64 CodeGen prolog/epilog is patched;
its notice is also retained in `CODEGEN-LICENSE.txt`. Preserve all relevant
upstream notices if these components are distributed.

## Build And Run

From the OpenXML1 root, apply the patch once to the pinned CodeGen checkout:

```powershell
$patch = (Resolve-Path xmen-legends/play-vu-probe/codegen-win64-simd.patch).Path
git -C .tools/Play-VU/deps/CodeGen apply --check $patch
git -C .tools/Play-VU/deps/CodeGen apply $patch
```

CMake refuses configuration if the patch is absent. A reverse `--check` confirms
an already-applied patch; do not apply it twice or reset unrelated source edits.
Configure once with MSVC x64 and MASM. Lower the configuring shell's
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

Final verification executable SHA-256:
`E8BA8C585E58A6764D491A8DC1031AC63A09A9C5052676B7A9E6D6C0F334025A`.
The test runner prints the executable SHA-256 for each invocation.

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

## Windows ABI Regression

The pinned CodeGen uses XMM6-XMM15 without preserving their Windows nonvolatile
values. A public, synthetic twelve-vector addition program reproduces corruption
of all ten registers while its arithmetic output remains correct. This explains
why the 21 upstream VU tests alone did not detect the integration hazard.

`win64_register_test.asm` seeds and records these registers while preserving its
own caller, including unwind metadata. The regression fails without the patch
(`xmm-corrupt-mask=0x3ff`, exit 6) and passes with it (`0x0`). The patch reserves
160 stack bytes on Windows, moves local/spill offsets accordingly, and saves and
restores all ten registers. System V code generation is unchanged. All 21 VU
tests, budget checks and the XGKICK contract still pass. The unpatched diagnostic
produced invalid floating-point timing output; discard that timing completely.

## Private Replay Diagnostic

```powershell
& ./xmen-legends/play-vu-probe/test.ps1 -ReplayPath xmen-legends/disc/vu-replay.bin
```

The recordings are ignored, private artifacts and must not be distributed.
The bounded VUR1 reader accepts only the known inactive-PATH1 state layout with
no pending stores, register writes, scalar operations, branches, or future
readiness deadlines. It checks both queue masks and entry validity. Only case 19
of the original 32-record capture currently qualifies; this is not full coverage.

That case reaches the same E-bit termination PC. ACC, Q/P/I/R, all integer
registers and all but one vector word match. There are 28 differing memory bytes
in 27 words and one differing byte in the 16 same-sized, ordered GIF packets.
The vector mismatch is one ULP. The arithmetic cause is not yet proven; both
engines already use round-toward-zero. Play! also omits initial STATUS bits
`0xb00`; flag mirrors need explicit pipeline retirement. It reports 2420 pipeline
cycles versus the recording's 2425. Neither exact graphics-event timing nor
pipeline-state equivalence is established. The diagnostic always prints
`accepted=0`; exit zero means it ran, not that compatibility passed.

After the ABI fix, 256 warm runs reproduce the cold run's entire MIPS state,
memory and packet output. Three sequential comparisons at Normal priority on
four logical processors measured the following case-19 executor totals:

| Round | Current PS2Recomp (ms) | Patched Play! diagnostic (ms) |
| --- | ---: | ---: |
| 1 | 23.621 | 3.417799 |
| 2 | 32.560 | 3.829699 |
| 3 | 23.489 | 3.458299 |

The baseline test image was `572A59384879D900A6ECB8864457E52475464875350F668D0EFA198181A1FF93`;
the diagnostic image was `C9F27D92EE46D8F69A68B5E3CF82E4224FFC86A6296DA7BD1AC83AE521850590`.
Baseline replay passed all 32 records with digest `75d4ff1e67bbbc4c` in each run.
Median isolated time is about 6.8x lower, but the workloads are not yet semantically
equivalent: the diagnostic lacks correct scheduling/streaming and omits flag
behavior. Import, compilation and final comparisons are outside the timer;
packet-copy callbacks are inside. This is feasibility evidence, not an accepted
optimization or a gameplay FPS claim. A real bridge and broader workloads still
need measurement, and drawing remains a separate major cost.

Next: bridge explicit cycle/graphics events and validate architectural results,
memory writes, and packet ordering against the existing private recordings before
measuring throughput. Those recordings contain mid-program state, not fresh VU
entry snapshots, so importing their visible registers alone is invalid.

No game executable should be linked or packaged until the larger performance
change has measured benefit. The title/FPS counter stays queued for that build.
