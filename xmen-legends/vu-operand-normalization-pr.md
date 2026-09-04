## Summary

- Inline the existing bitwise VU operand-normalization and broadcast helpers so upper/lower instruction translation units can optimize their calls.
- Return from upper NOP before preparing arithmetic operands. Instruction control bits, lower-slot execution, and cycle advancement remain handled by the existing execution loop.
- Add a NOP regression covering unusual floating-point bit patterns, preserved flags, end-bit delay handling, and cycle count.
- Add a deterministic synthetic arithmetic/memory workload that records a digest for before/after comparisons.

This does not change PS2 floating-point normalization rules, FMAC calculations, flags, hazards, pipeline timing, or microcode-cache behavior. It includes no game-specific hooks, profiling instrumentation, or game assets.

## Verification

- Based directly on upstream main `14b1e5cb39b4af7e6fc12f9a29fdc751efde49d7`; independent of the pipeline-occupancy PR.
- Windows/MSVC Release: 427/427 tests pass both before and after the runtime change, with the new tests present in both runs.
- The 1,024-round arithmetic workload preserves digest `3308d7380e3bfe64` in that upstream-based configuration.
- In the separate X-Men bring-up configuration, all 93 VU tests pass and the workload preserves its configuration-specific digest `45e6d3166964d75e`.
- Nine bring-up workload runs per version: median execution time 21.103 ms before, 19.971 ms after (about 5%). These short synthetic timings are machine/configuration-specific, not a gameplay frame-rate claim.
- A bounded first-level X-Men run reaches rendered New York/Wolverine at present 1200 with the existing visual defects. Overall gameplay remains slow; this is a small hot-path optimization, not a playability claim.

## Reproduce

Build and run `ps2x_tests` from the repository root. The workload reports its digest and measured execution time as `[vu-arithmetic-workload]`. Compare within the same compiler/configuration; the digest is not a portable hardware-correctness oracle.
