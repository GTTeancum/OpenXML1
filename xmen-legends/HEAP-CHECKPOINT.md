# Compatibility Heap Investigation

September 6, 2026. Work is local only; no pushes or PRs. Movement was confirmed
by the user on an earlier build; attacking was not tested there. The performance
target remains 30 FPS. No result below is an interactive handoff.

## Observed Pressure

Candidate `7F5AE058415EFEB2812512F708DE7B2E85F8801E9556BB06E360E6F5AA298408`
was examined with read-only process memory access. No input, capture app,
breakpoints, memory writes or desktop automation was used. Its PDB is stale and
the candidate contains no matching CodeView record. Actual allocator machine
code, rather than that PDB, identifies the observed RVAs:

- allocator body `0x25bf0..0x25eed`;
- bump frontier `0x9cf3830`;
- free-vector header `0xb100c20`;
- allocation-map header `0xb0ff220`.

`observe-gameplay-heap.ps1` requires that exact executable path, SHA-256 and
instruction signature. It rejects later candidates. Reads are unsuspended,
so concurrent changes can invalidate samples; range checks and repeated
container-header reads do not constitute an atomic heap snapshot.

After level loading the observed frontier is **25,047,040**, leaving **118,784
bytes** before the arena limit. The largest observed free block is **109,056
bytes**; about 249,000-250,000 bytes in total are free across 23-24 blocks. The repeatedly
failed singleton request needs **298,384 bytes** (`0x48d90`) contiguously.
Neither the tail nor any observed free block can satisfy it. The arena must
not simply be enlarged into the separate custom game heap at `0x01800000`.

An allocation-list read validates 60,428 entries totaling 14,989,587 requested
bytes, or 15,334,640 bytes after the allocator's 16-byte size rounding. This
accounts for most of the arena; it is not proof that every allocation remains
semantically needed. The initial wrapper returned exit 1 after completing this
list because its five-second observation interval had elapsed before a separate
heap sample. The list data was retained, but that run is not described as a
successful complete observer run. The wrapper now distinguishes a validated
allocation list from a timed heap sample and bounds list traversal too.

Fixed private artifacts: `gameplay-heap-observation.json`,
`gameplay-heap-allocations.json`, and `gameplay-vulkan-retry-failure.*`.
The observed game repeat completed without a guest fault and reported 5.849623
FPS, but the observer overlapped it; do not present that as a controlled speed
comparison. The earlier fault remains unresolved by this successful repeat.

## Allocation Policy Experiment

`PS2X_GUEST_BUMP_BEST_FIT` is OFF by default. It chooses the smallest free block
that fits the request after alignment, preserving larger holes for larger
requests. The arena bounds, requested-size tracking, clearing, alignment,
splitting and free/coalescing behavior remain unchanged. It does not move live
objects or bypass failed guest calls. The first allocation emits positive
activation evidence. `PS2X_GUEST_BUMP_DIAGNOSTICS` separately enables at most
16 failure records with requested size and available-space information.

Test image `EB9D792A575CC8EC97D3363AF06BE405E88D47A6E3E2712D8D9BF562404B521F`
passes both fresh-process policy checks. In the synthetic fragmented arena,
first-fit consumes part of the large hole for a small request and cannot later
satisfy 327,680 bytes; best-fit uses the small hole and succeeds. Size tracking,
alignment, clearing and frees pass. This is a synthetic policy result, not proof
that the real first level has enough memory. See `heap-policy-checks.log`.

The benchmark now requires best-fit activation when requested, rejects observed
allocation failures, and excludes heap diagnostics from FPS reporting. Its gate
tests pass. A diagnostic run with no failure records alone cannot prove heap
health outside the exercised workload.

## Bootstrap Address Bug

First candidate with the allocator experiment:
`F086C87397144F059CBE6331CFA4DBF9FE6313180B05CE82ACCB2CCE86F7DBC4`.
It reached the bounded frame limit without an allocation-failure record or
guest fault, but **never started New Game or loaded NYC**. Its workload is
rejected, and its title-screen timing is not gameplay FPS.

The generated first-level test trigger hard-coded the level manager's former
heap address, `0x00b1a220`. Different allocation placement invalidates that
assumption. Retail getter `0x3246e0` instead reads the singleton at `0x764288`
and constructs it through `0x31d7d0`. The trigger now reads that singleton,
bounds-checks both pointer dereferences and retains its existing title-state
and 30-frame conditions. No manual-control behavior or game-level selection is
changed. The tracked `generated-first-level-probe.patch` reverse-checks cleanly
against the current generated source, including the function-table entry.

## Corrected First-Level Checks

Corrected candidate:
`E5C379F437D560B7358BE1A94469E30B15C890BC152BDB480919BDE61E8604C1`.
Both policies now reach the real New Game handler and NYC package. Both are
rejected on explicit allocation failures. The runner deliberately terminates
its owned game on the first observed failure record, drains queued output and
restores startup. Exit -1 here is that diagnostic stop, not a new host crash.

| Policy | First failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Best-fit | 66,720 | 4 | 25,124,864 | 40,960 | 113,712 | 64,352 | 57,649 |
| Original first-fit | 298,384 | 4 | 25,047,040 | 118,784 | 250,320 | 109,056 | 60,419 |

The first-fit failure matches the earlier read-only observation and the null
singleton's allocation size. Best-fit fails on an earlier, different request;
it is **not promoted**, and remains opt-in for comparison only. The title-only
run did not establish its suitability for gameplay. Both corrected runs had
compiled VU auditing enabled, with no mismatch reported before the allocation
stop, but neither completes the audit or yields valid FPS. No new framebuffer
was written: the best-fit run requested present 1280 but stopped before it.
Do not mistake the previously retained frame for evidence from this candidate.

Fixed evidence is in `gameplay-vulkan-audit-retry-best-fit-heap-audit.*` and
`gameplay-vulkan-audit-retry-heap-audit.*`. Original first-fit logs nine queued
failure records before termination; the first is the table entry above.

NEXT: investigate allocation ownership/lifetimes and the division between the
compatibility arena and the original custom heap. The current live allocation
inventory accounts for nearly all the compatibility arena; changing free-list
placement alone did not make the first level healthy. Do not enlarge the arena
across the custom-heap boundary without proving ownership, compact live guest
objects, bypass null dispatches, or count a run with allocation failures as a
complete gameplay validation. After memory health is established, finish the
compiled audit and resume substantial FPS work. The last clean control rate is
still 5.724173 FPS, not an acceptable interactive handoff.

Local PS2Recomp checkpoint: `92e3b7a`. Benchmark gates and observer syntax /
wrong-process rejection checks pass. Cleanup removed four stale generated files.
All owned builds, observers and game tests ended. No push, PR or new image.
