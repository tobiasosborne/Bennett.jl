# Worklog chunk 093

## Session log — 2026-07-07 — Bennett-utzc / CW-D: keep-branch dead-block pruner (ADR 0017 §4) + cross-repo halt sink

**What.** The Bennett.jl frontend half of a CROSS-REPO pair (ADR 0017 §4:
throw/unreachable → halt-dead-branch). `src/extract/module_walk.jl`
`_module_to_parsed_ir_on_func`: under the closed-world `ptr_cells` gate, a block
whose LLVM terminator is `unreachable` (a provably-dead Julia `@boundscheck`/`@assert`
throw arm) has its BODY dropped, KEEPS its own label, and gets the reserved
`IRBranch(nothing, :__unreachable__, nothing)` terminator. The predecessor's
conditional branch into it is left untouched (keep-branch): if the guard ever fires,
BennettVM's `:__unreachable__` halt sink traps loud (a faithful reversible throw).
`dead_blocks = ptr_cells ? _vec_vm_dead_blocks(func) : Set{_LLVMRef}()` (reuses the
Case-A Vector-recognizer helper). Two guard helpers: `_assert_dead_block_no_live_escape`
(every use of a dead-block value must be in another dead block — an unreachable block
dominates nothing live) and `_assert_dead_block_is_throw_skeleton` (a dead block is
expected iff it has 0 predecessors — an orphan `after_throw`/`after_noret` `llvm.trap`
stub — OR contains a throw-family / `llvm.trap` / error|throw|assert call; else fail
loud on a SURPRISING unreachable block).

**Cross-repo pair.** The BennettVM half (bead `bennettvm-g501`, committed `f022c5e`)
landed FIRST: a new `UnreachableHalt` instruction + per-function `:__unreachable__` sink
materialised in `ingest.jl` + a `run!` loop change (`while !is_halted` →
`while status===:running`). This side emits the branches to it.

**Key finding — utzc did its job, but the fdict set still does NOT fully close.** The
pruner cleared BOTH dead-block walls (the `setindex!` U114 `store {ptr,ptr}` box-store,
suite mode; the `rehash!` `[1 x ptr] @j_AssertionError` return, default mode) — the walls
ADVANCED past them. But two FRESH, non-dead-block walls remain (identical in both
check-bounds modes), correctly untouched by the pruner because they are in LIVE blocks:
  1. `:fail_loud` → `rehash!` walls at `llvm.smul.with.overflow.i64` (returns `{i64,i1}`,
     unmodelled under `ptr_cells`; BVM ADR 0020 D5). This is the GenericMemory size-overflow
     check in the LIVE `%nonemptymem` block. The generic path has no `llvm.*.with.overflow`
     handler (only the `mem=:vm` Vector recogniser models it; 6bu3 keeps `{i64,i1}` structs
     out of the generic path). NEXT WALL #4 — filed.
  2. `:skip` → closed-world violation on the inlined `gc_alloc_obj` Symbol callee in
     `julia_set.jl:_closed_world_check!` ("neither in-set body, throw-leaf, nor benign
     intrinsic"). This is the CW-D2 whitelist gap already tracked as `bennettvm-416r.12`.
     NEXT WALL #5.
So: after wall #4 (smul-overflow) clears, `rehash!` extracts; then the completeness check
trips on `gc_alloc_obj` (wall #5 / 416r.12). Order: smul-overflow → gc_alloc_obj.

**Gotchas (next agent).**
1. `:__unreachable__` must NEVER be a block LABEL — `_expand_switches` FORBIDS it
   (module_walk.jl:973). Keep the dead block's OWN label; `:__unreachable__` stays a
   dangling branch target. The BVM side materialises the real sink block.
2. The pruner is a wall-ADVANCE, not a "set now extracts" — do NOT assert full extraction
   in the tests (the fdict set still walls at smul-overflow / gc_alloc_obj). GATE E in
   `test_d1b_julia_set.jl` was updated HONESTLY: it asserts the dead-block wall is GONE
   (`!occursin("j_AssertionError")`, `!occursin("[1 x ptr")`) and advanced to the
   `gc_alloc_obj`/closed-world frontier, but KEEPS the `@test_broken` (the set does not
   reach 4 fully-extracted bodies). Do not fake-flip it green.
3. `_vec_vm_dead_blocks` / `_vec_vm_is_dead_throw_callee` are reused read-only from the
   Case-A Vector recogniser — a shared-machinery touch, so re-run `test_jfw6` / `test_d1b`
   under suite mode on any change here.

**Process.** 3+1 (2 blind cross-repo proposers → 2 serial implementers: BVM sink first,
then this frontend pruner → orchestrator review + independent suite-mode re-run).

**Tests.** New `test/test_utzc_dead_block_pruner.jl` (31, both modes): prune+keep-branch
(U114 dead arm), no-live-escape guard (ESCAPES), surprise guard (SURPRISING) + orphan
`llvm.trap` accept, real-target fdict-set wall-advance tripwire, byte-identity/gate-off.
`test_d1b` GATE E updated (33 pass / 1 broken, both modes). ptr_cells cluster +
Vector-recogniser tests green under `--check-bounds=yes`.
