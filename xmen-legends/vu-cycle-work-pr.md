## Summary

- Retire pending VU pipelines once on entry to an executable slice. Subsequent
  instruction boundaries already retire them in `advanceOneCycle()`, before
  PATH1 reads VU memory, so the next loop iteration need not repeat that scan.
- Copy a contiguous PATH1 qword with one address calculation and `memcpy`.
  Retain byte-wise wrapping for split qwords and unsigned address overflow.
- Add a synthetic regression covering 32-, 33-, 47-, 64-, and 16384-byte memory
  boundaries, complete packet equality, and zero/one-cycle resume timing.

No instruction arithmetic, pipeline latency, event order, packet batching, or
game-specific behavior is changed. This PR is based directly on upstream main
`14b1e5c` and does not depend on the occupancy-mask or operand-preparation PRs.

## Validation

- Windows x64 Release, Visual Studio 2022, one BelowNormal build worker.
- Unmodified upstream main: 425/425 tests pass.
- This branch: 426/426 tests pass.
- The boundary test also passed against the original byte-wise packet copy.
- The bring-up integration passes 97/97 local VU tests. Its other known suite
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
