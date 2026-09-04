## Summary

- Retire pending VU pipelines once on entry to an executable slice. Subsequent
  instruction boundaries already retire them in `advanceOneCycle()`, before
  PATH1 reads VU memory, so the next loop iteration need not repeat that scan.
- Copy a contiguous PATH1 qword with one address calculation and `memcpy`.
  Retain byte-wise wrapping for split qwords and unsigned address overflow.
- Visit only the set bits of existing VI read/write masks during dependency
  checks, write-readiness updates, and first-written-register selection. VI0
  remains excluded and registers are still visited in ascending order.
- Add a synthetic regression covering 32-, 33-, 47-, 64-, and 16384-byte memory
  boundaries, complete packet equality, and zero/one-cycle resume timing.
- Add all 256 pairs of VI input registers, covering every destination, repeated
  loads to the same register, VI0, high registers, final values, cycle counts,
  and the end-bit delay slot.

No instruction arithmetic, pipeline latency, event order, packet batching, or
game-specific behavior is changed. This PR is based directly on upstream main
`14b1e5c` and does not depend on the occupancy-mask or operand-preparation PRs.

## Validation

- Windows x64 Release, Visual Studio 2022, one BelowNormal build worker.
- Unmodified upstream main: 425/425 tests pass.
- Initial cycle-work commit: 426/426 tests pass; current branch: 427/427.
- The boundary test also passed against the original byte-wise packet copy.
- The bring-up integration passes 98/98 local VU tests. Its other known suite
  failures are not represented as passing by this result.
- Private, process-local replay of 32 real VU slices checks full canonical
  register/pipeline state, all 16 KiB of VU data, and every emitted GIF byte and
  emission cycle. All 4096 timed executions match, digest `75d4ff1e67bbbc4c`.
  The replay tool is not part of this PR, and no retail microcode or data is
  included or redistributed.

Nine interleaved runs of the captured workload measured median execution times
of 589.740 ms before and 564.147 ms after removing the duplicate retirement scan
(about 4.3%). This measurement is from the bring-up branch, not this clean
upstream branch. Packet-copy-only timings were noisy, so no separate gain is
claimed. These are VU workload timings, not whole-game FPS measurements.

For the VI-mask follow-up, a longer nine-pair comparison alternated execution
order and used 512 repeats per captured case (16,384 timed slices and 20,891,136
VU cycles per run). Median execution time fell from 2299.731 ms to 1981.324 ms,
about 13.85%, with the same state/memory/GIF digest throughout. Every candidate
run in that batch was faster than every baseline run. These numbers are also
from the bring-up branch and do not constitute an end-to-end FPS claim.
