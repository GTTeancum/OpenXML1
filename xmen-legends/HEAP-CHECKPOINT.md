# Compatibility Heap Investigation

September 6, 2026. Work is local only; no pushes or PRs. Movement was confirmed
by the user on an earlier build; attacking was not tested there. The performance
target remains 30 FPS. No result below is an interactive handoff.

## Failure Attribution (18:30 UTC)

Runtime and test changes are checkpointed locally in PS2Recomp commit `b4c0043`.

`PS2X_GUEST_BUMP_DIAGNOSTICS` now records the active dispatch source/target and
registers on the first allocation failure, plus up to 16 live requested-size
groups ranked by total bytes. The existing 16-failure cap remains. Context is
thread-local and restored on nested dispatch return/unwind; normal mode emits
neither these records nor builds the size histogram. This is diagnostic work,
not a claimed optimization. Its disabled-mode timing cost has not been measured.

`tests/test-compatibility-heap.ps1` passes 27 fresh-process checks both normally
and with `-Diagnostics` (54 total), including an exhausted-heap dispatch that
must retain the old allocation and identify source `0x800000`, target `0x200e10`.
Output bounds and disabled-mode silence are checked. Test image:
`A5EEE997A40B2BE0F20F79B41C1129303EFEC3AFDCA9796D9FDBFD32C9C18C9C`.
The fixed `heap-ownership-checks.log` currently contains the diagnostics-on run;
the preceding off run passed in terminal output.

Candidate `66BB7F1592362DFF83095180001AB14E2B3CF12E1C0E15D56C228C3FA310E429`
was used for one automated first-fit/in-place/compiled-retry/Vulkan run, with
heap diagnostics and compiled arithmetic auditing. It reproduces the previous
32,768-byte failure exactly: frontier 25,151,296; tail 14,528; free 1,590,224;
largest hole 32,560; live allocations 53,331. Caller record:

```text
source=0x248068 target=0x231ed0 ra=0x248070 sp=0x1f12550
a0=0x898ef0 a1=0x8000 a2=0x10 a3=0 s0=0x8000 s1=0
```

Retail `0x248040` takes a size in a0 and allocator category in a1, resolves the
allocator through `0x247fc0`, then calls aligned-allocation slot `0xd8` with
alignment 16 at `0x248068`. The two explicit fixed-32-KiB callers found in static
disassembly are `0x2dd20c` and `0x2dd510`, both passing category 12. Their routines
set up/grow command buffers using globals `0x750700..0x750710`, 32,752-byte end
offsets and linked packet storage. This identifies a command-buffer path to
investigate, but the immediate caller report alone does NOT distinguish those
two sites from other callers computing a 32-KiB size dynamically.

Category 12 at `0x247fc0` first checks allocator singleton `0x7472a0`, then falls
back to `0x747298`, `0x20c960`, and `0x203b60`. Investigate whether the original
allocator separation/lifetimes are lost when all wrappers allocate from one
compatibility arena; do not assume all those native arenas are free or expand
into them without ownership proof.

Largest observed live-size groups by requested bytes:

| Requested size | Live count | Total bytes |
| ---: | ---: | ---: |
| 16,384 | 48 | 786,432 |
| 32,895 | 20 | 657,900 |
| 479,220 | 1 | 479,220 |
| 32,768 | 13 | 425,984 |
| 6,112 | 65 | 397,280 |
| 8,192 | 47 | 385,024 |
| 44 | 7,773 | 342,012 |
| 1,024 | 326 | 333,824 |

These are requested-size totals, not padded occupancy or ownership/lifetime
attribution. Full 16-group output is in the reused
`gameplay-vulkan-audit-retry-realloc-heap-audit.err.log`. New Game/NYC and public
free execution are confirmed; 16 queued failure records were drained after the
intentional stop, exit -1, elapsed 19.15 seconds. No guest fault or compiled
mismatch before stopping, but neither the audit nor gameplay span completes.
No valid FPS, native image or interactive handoff. Startup restored; all owned
build/test/game processes ended. Allocator experiments remain opt-in.

NEXT: confirm the command-buffer caller and inspect the category-12 allocator's
ownership/lifetime boundary. Do not change placement policy again on this data
alone. The 298,384-byte singleton failure in default moving mode remains open,
as does the primary 30 FPS objective and substantial VU execution work.

## Ownership Dispatch Checkpoint (18:20 UTC)

Retail ELF program-header mapping was used to read the table at `0x6fcbe0`:
slots `0xd4/0xe4/0xe8/0x104/0x14c/0x150/0x1b4` contain
`0x231eb0/0x232020/0x232040/0x2336f0/0x233800/0x233710/0x233ed0`.
Disassembly confirms:

- Public free `0x200f40` and aliases `0x200f90/0x201080` query owner lookup
  `0x203f90` before calling slot `0x104`; `0x201090` follows the same owner path
  through `0x200fe0`. Host-tracked buffers must be released before that lookup.
- `0x2151b0` forwards a1 to the allocator's free slot, while `0x2336f0` forwards
  it to shared slot `0x1b4` with a2 set to **-1** (`0x2336f4`).
- Shared implementation `0x233ed0` branches on that sentinel at `0x234034..38`.
  Its prior compatibility hook incorrectly freed any owned a1, regardless of
  a2. Positive sizes now resize; only -1 selects its release path. The existing
  helper's zero-size policy is retained, not claimed as exact retail semantics.
- The unaligned public realloc entry `0x200e10` also queries native ownership;
  it now handles known compatibility blocks like the existing aligned entries.

All seven public/inner free entry points use host ownership only for exact tracked
addresses. Unknown pointers continue to the guest implementation. Direct/indirect
calls and tail jumps preserve their respective continuations. Two formerly
diagnostic-only addresses (`0x2151b0`, `0x2336f0`) were removed from the optimized
dispatcher's exclusion list because they now perform cleanup.

The new dispatch regression also caught a macro-precedence bug: passing
`virtualCall ? 5 : 4` to `GPR_U32` makes its unparenthesized register-zero test
return zero on virtual calls. The allocator now uses `getRegU32` for that choice,
as does the new public-free argument selection. No global macro/header rewrite.

Final test image `AE058BCADED7913DC9EE78EDC9D0C9186714CCFB3530BF1E626DECEEA7198284`
passes all **27 fresh-process checks** through `tests/test-compatibility-heap.ps1`:
three allocator tests across normal/fast dispatch, first/best fit, and moving/
in-place realloc, plus three existing normal-heap checks. Dispatch coverage
includes 28 owned free branch/entry combinations, seven foreign-pointer cases,
both allocation calling conventions, positive shared-slot resize and -1 release.
Initial tests caught the new macro call-site error and fast-path exclusions;
they were corrected before the final passing matrix. An initial test compilation
also needed the existing register accessor instead of a macro with `&ctx`.
Fixed evidence: `heap-ownership-checks.log`. Benchmark gates pass.

Candidate `4B16C52B0D89740B92912F5F9527B2051537B4DA24F7EAB6A0559AB3404F7B5A`
contains the ownership fixes, with both allocator experiments OFF by default.
Two first-fit real-level runs (compiled VU + retry, Vulkan, heap diagnostics,
compiled audit) reach New Game/NYC but still stop on allocation failure:

| Realloc mode | Failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Moving (default) | 298,384 | 4 | 24,997,888 | 167,936 | 253,264 | 108,912 | 60,113 |
| In-place (opt-in) | 32,768 | 16 | 25,151,296 | 14,528 | 1,590,224 | 32,560 | 53,331 |

The moving run records at least 40,961 public releases / 2,892,100 cumulative
requested bytes; the in-place run records 36,865 / 2,591,600. These counters prove
the new path executes. They are NOT simultaneous extra headroom or proof that
every one of those releases previously leaked; some native paths can reach the
already existing compatibility free hook. Neither run completes its audit or
produces valid FPS. Nine/sixteen queued allocation failures were drained after
intentional termination, exit -1; no guest fault or arithmetic mismatch was
reported before the stops. Elapsed 30.91/16.09 seconds is not an FPS result.

Current logs reuse `gameplay-vulkan-audit-retry-heap-audit.*` and
`gameplay-vulkan-audit-retry-realloc-heap-audit.*`; their prior-candidate contents
are replaced. Historical numbers below are recorded observations, not claims
that those fixed paths still hold the historical run. No new image or input.
Both game processes ended and startup was restored.

NEXT: obtain the exact caller of the failed 32 KiB request and allocation-lifetime
attribution at failure. Static inspection identified additional real dispatch
bugs, but has not identified that caller. Add bounded call attribution with the
next meaningful runtime change, rather than rotating placement policies. The
native heap boundary remains protected, the full FPS objective is unmet, and
there is no interactive handoff. All source changes remain local.

Local PS2Recomp checkpoint: `cfaf3af`. Cleanup found no additional stale files;
active candidate/test images and fixed evidence were retained. No owned build,
game or test process remains running.

## Reallocation Checkpoint (18:04 UTC)

Three compatibility realloc routes now use a shared owned-allocation helper.
The inner wrappers and null realloc slot previously freed the original block
even if allocating its replacement failed. Failure now retains that block and
its contents. Zero-size owned realloc frees it and returns zero; foreign guest
allocations retain their existing copy-only path and are not freed by this heap.

`PS2X_GUEST_BUMP_REALLOC` enables in-place shrinking, growth within existing
padding, and growth into an adjacent free extent. It is OFF by default. Fallback
still allocates/copies/frees on success. No live objects are compacted, no arena
boundary changes, and no guest call is bypassed. In-place growth clears newly
exposed bytes; shrinking returns the unused padded tail to the coalesced free
list. The benchmark's `-InPlaceRealloc` switch requires actual in-place execution
evidence, not just an enabled flag.

Test image `D094FC539746064CD17ABA51A8B01A139426020014C97FF388A8308BC73E3CE7`
passes eight fresh-process runs: realloc and fragmentation tests under all four
combinations of first/best fit and moving/in-place realloc. These cover retained
data, cleared extension, requested size, null/zero size, adjacent extent splitting,
out-of-memory/overflow ownership preservation and foreign-address rejection.
Three existing normal guest-heap, memalign and allocator-stub checks also pass.
Evidence: fixed `heap-realloc-checks.log`. Benchmark gate tests pass.

Candidate `FAAD524CF88FB7917A3BA58B0C99EA41C4C658CC68A19705DE5C94709B1E6427`
was linked in the existing slot, with the corrected New Game trigger unchanged.
Both bounded runs enable compiled VU + retry, Vulkan, realloc, heap diagnostics
and the compiled arithmetic audit. Both reach New Game and NYC, then stop on
allocation failure. Neither completes the audit or provides valid FPS:

| Policy with in-place realloc | First failed request | Alignment | Frontier | Tail | Free total | Largest hole | Live allocations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| First-fit | 32,768 | 16 | 25,154,768 | 11,056 | 1,525,552 | 32,560 | 53,641 |
| Best-fit | 32,768 | 16 | 25,153,824 | 12,000 | 1,485,872 | 32,560 | 53,543 |

Each run drained 16 queued failure records after the runner requested termination.
Exit -1 is that deliberate diagnostic stop. No guest fault or VU mismatch was
reported before stopping; this is not a full audit pass. Elapsed times 20.04 and
20.24 seconds are time to failure, not performance improvements. Relative to
the previous candidates there is more fragmented free space, but different
failure points prevent a like-for-like memory-saving claim. Neither experimental
policy is promoted. No new image or interactive handoff was made, and startup
was restored after both runs.

Local PS2Recomp commit: `4cf8284`. All owned builds and tests ended. Cleanup
removed one stale generated file and retained the active binaries/evidence.
No push or PR was made.

Fixed evidence: `gameplay-vulkan-audit-retry-realloc-heap-audit.*` and
`gameplay-vulkan-audit-retry-best-fit-realloc-heap-audit.*`. Next: identify the
ownership/call path of these 32 KiB requests and the lifetime of the live blocks;
do not keep rotating placement policies or expand into the native custom heap.
The remaining sections record the preceding investigations, not newer results.

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
