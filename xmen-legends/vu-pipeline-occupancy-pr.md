## Summary

- Track occupied VU flag, store, VF, VI, and ACC pipeline slots with compact bitmasks.
- Allocate the first free slot with `std::countr_zero`.
- Visit only occupied slots when committing results or checking pending work.

## Motivation

The fixed pipeline arrays are usually sparse. Earlier X-Men Legends bring-up
profiling identified VU execution and pipeline retirement as major costs, so
checking empty slots on every cycle is avoidable work. Allocation and retirement
must retain their original ascending slot order, timing, and reset behavior.

This is not a claim of current playable gameplay speed. Earlier title-screen
timings are not a sustained gameplay benchmark. The September 4 follow-up adds
regression coverage only; it makes no further runtime or performance change.

## Testing

- Windows 11, Visual Studio 2022 Release, one BelowNormal build worker.
- Original branch: 425 passed, 0 failed.
- With the new regression tests: 427 passed, 0 failed.
- Forty independent upper/lower instruction pairs, checked at every cycle
  across 48 one-cycle slices with intervening zero-cycle resumes. Reused VF
  destinations receive alternating values so missing or late later writes are
  observable. The test also checks same-pair FSSET priority and MAC/STATUS.
- Twelve restart/reset cases ensure cancelled pending flag/VF writes cannot
  reappear after a fresh execution, including restarts at nonzero cycle counts.

All new test programs and inputs are synthetic; no game data is included.
