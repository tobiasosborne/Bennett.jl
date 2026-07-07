# Worklog chunk 093

## Session log — 2026-07-07 — Bennett-8bys / CW-D: route VARIABLE-size `llvm.memset.p0.i64` to BVM `IntrinsicMemset` under ptr_cells

**What.** `src/extract/instructions.jl` `_handle_memset_arm`: at predicate 5 (the
`!(n_v isa ConstantInt)` variable-count case), under `ptr_cells` AND non-volatile,
route to a bare `IRCall(dest, :memset, [dst_cell, byte, nbytes], [64,8,64], 64)`
instead of the const-N unroll's fail-loud reject. Reuses BVM's reversible
`IntrinsicMemset` (`:memset → IntrinsicMemset`, `:memset ∈ _HEAP_DISPATCH`).
Threaded `dest::Symbol` + `ptr_cells::Bool` into the arm (both already in scope at
the sole `_handle_intrinsic` caller; the memcpy arm nearby already forwards
`ptr_cells`). ~15 LOC, one source file. Bennett.jl-ONLY (BVM ingest already
handles variable-size `:memset`). Const-N keeps the unroll; `ptr_cells=false`
keeps the reject; a VOLATILE variable-N memset still fails loud (Rule 1).

**Byte is passed RAW.** `_operand(c_v, names)` — no mask, no broadcast (BVM's
`IntrinsicMemset.forward` does its own cell-broadcast; pre-broadcasting would
double-broadcast). GOTCHA: `_const_int_as_int` uses `convert(Int, ::ConstantInt)`
which SIGN-EXTENDS the i8, so `i8 255`/`i8 -1` (0xFF) → `-1`, not 255 — and 0xFF
is degenerate for raw-vs-broadcast (broadcast of 0xFF is also -1). The test uses
`i8 1` (raw 1 ≠ 64-bit broadcast 0x0101…) as the discriminating probe. Dst guard:
`_operand(dst_v; ptr_cells=true) isa SSAOperand` (a `ptr null` cell would be a
`ConstOperand` → fail loud).

**Real-target payoff (fdict `rehash!`), BOTH check-bounds modes, live-probed:**
- `:fail_loud` single-fn `extract_parsed_ir(Base.rehash!, {Dict{Int8,Int8},Int64};
  optimize=false, ptr_cells=true)` now **FULLY EXTRACTS** (no throw) — the
  variable-size slots-zeroing memset was rehash!'s last single-function wall
  (after lbot fused the `smul.with.overflow` GenericMemory size-check).
- `:skip`/`:fail_loud` SET producer (`extract_parsed_ir_set_from_julia`) walls at
  the POST-extraction closed-world check: Symbol callee `gc_alloc_obj` unclassified
  (CW-D2 whitelist not built — **bennettvm-416r.12, the NEXT bead**). In-set keys
  now: `rehash!`, `setindex!`, `ht_keyindex2_shorthash!`, fdict root — all bodies
  extract. Mode-INDEPENDENT.

**Frontier-test updates (honest, lbot/u2kk pattern).** 8bys advancing rehash! to
full extraction shifted asserted frontiers: `test_lf14` GATE C pinned the
per-callee `"extraction FAILED"` wrapper as the `:fail_loud` set frontier — now the
closed-world `gc_alloc_obj` violation fires instead (no callee extraction fails);
added `occursin("closed-world violation")` disjunct (kept the wrapper as
future-robust). `test_lf14` GATE B rehash! probe now takes the `:ok`
full-extraction branch (`rmsg_on isa ParsedIR`). Stale "walls at the memset" prose
corrected in `test_utzc` (c) and `test_yd4f` GATE 5 (both still pass — their
disjunctions already carried `gc_alloc_obj`/`closed-world`/`nothing`-branch).

**Tests.** New `test/test_8bys_variable_memset.jl` (28 assertions) + fixture
`test/fixtures/ll/8bys_memset_var_n.ll` (void ptr-param memset, c=0/1/0xFF +
volatile). Registered after `test_lbot` in the CW-D cluster. Gate-off proof (c)
uses `9nwt_memset_var_n_reject.ll` (i8-return alloca dst) NOT fixture (a): the
void/ptr-param shape (a) pre-empts at the U81 VoidType `_type_width` wall under
`ptr_cells=false` before reaching the memset. Suite-mode (`--check-bounds=yes`)
green: 8bys 28, 9nwt 87, 37mt 86, lqif 12, 8su4 24 (volatile guard intact),
qmv7 35, u2kk 14, lf14 25, 583s 28, d1b 33+1broken, utzc 31, yd4f 25.

## Session log — 2026-07-07 — Bennett-lbot / CW-D: fuse `llvm.{s,u}{mul,add}.with.overflow.iN` to scalars under ptr_cells

**What.** `src/extract/instructions.jl`: under `ptr_cells`, recognize the four
overflow-arith intrinsics (`{iN,i1}` result) and FUSE the call + its two
`extractvalue`s into SCALAR IRInsts — the `{iN,i1}` aggregate is never modelled
(its i1 field would trip the 6bu3 `_struct_field_widths` reject). STATELESS
mechanism (proposer A over B's side-table): Spot 1 skips the CALL (`return
nothing`, inside the `ptr_cells` Function arm, before the D5 return-type reject);
Spot 2, at the top of the `LLVMExtractValue` arm, re-derives the scalar directly
from the call's operands (`_fuse_overflow_extractvalue`): idx 0 →
`IRBinOp(dest, :mul/:add, a, b, N)` (wrapped product/sum, BVM `IRBinOp` wraps =
LLVM low-N semantics); idx 1 → the overflow bit. Bennett.jl-only (scalar shape →
no BVM gap; a `{i64,i1}` aggregate would wall on both sides).

**Fold predicate (soundness — both proposers corrected the brief).** The overflow
bit folds to `iconst(0)` ONLY when provably no-overflow: MUL const ∈ `{0,1}`, ADD
const `== 0`; else FAIL LOUD (no placeholder). `-1` is NOT admitted for MUL —
signed `smul(x,-1) = -x` overflows at `x = INT_MIN` (`2^(N-1)` unrepresentable).
The dead-branch argument does NOT make the bit immaterial: a placeholder-0 routes
AWAY from the throw the native code takes on real overflow (a silent miscompile);
utzc's halt-sink only protects mispredict-TOWARD-dead. So the bit must be exact.
For fdict `smul(newsz, 1)` the const is `1` → bit provably 0 (exact, free).

**Key finding — the fdict frontier moved, and setindex! now CLEAN-extracts.**
Post-lbot, `extract_parsed_ir_set_from_julia(fdict, Tuple{Int8,Int8}; ptr_cells=true)`
(both check-bounds modes):
  - `:fail_loud` → `rehash!` now walls at a **variable-size `llvm.memset.p0.i64`**
    (zeroing `h::Dict.slots2`) — "memset with non-constant byte count not supported",
    tracked by **Bennett-8bys** (open; the extractor error names it). NEXT WALL.
  - `:skip` → `gc_alloc_obj` closed-world violation (from the fdict root body) —
    the CW-D2 whitelist gap, **bennettvm-416r.12**. The set now has 3 of 4 callees
    extracting (setindex! + fdict root + ht_keyindex2); only rehash! still walls.
  - `setindex!` under `--check-bounds=yes` advanced from WALLING to a clean 36-block
    extract (its `smul(newsz,1)` size-check now fuses to bit 0 — sound). `test_qmv7`
    GATE (d) made mode-aware: `length(blocks) == (check_bounds==1 ? 36 : 12)`.

**Gotcha — narrow-disjunction tripwires.** Three tests pinned `smul` as their
`rehash!`/`setindex!` frontier and needed HONEST updates when lbot advanced it:
`test_utzc` (c), `test_yd4f` GATE 5 (added memset/8bys/9nwt/gc_alloc_obj disjuncts),
`test_qmv7` GATE (d) (the 36/12 mode-aware count). `test_d1b` GATE E needed NO change
(its `@test_broken` uses cells=FALSE, where lbot is inert → stays honestly broken).
Broad-disjunction tests (u2kk/8g7m/beaw/…) were unaffected — their "memcpy" disjunct
catches the memset message (which says "same gap as variable-size memcpy").

**Process.** 3+1 (2 concise blind proposers → implementer → orchestrator review +
independent suite-mode re-run). New `test/test_lbot_overflow_intrinsic.jl` (30, both
modes): GREEN smul/umul/sadd/uadd(x,{0,1}); guard two-var + nonzero-add fail loud;
gate-off byte-identical; fdict-set advance. Regression cluster green under
`--check-bounds=yes`. FOLLOW-UP (not filed — capture at the general-arith step):
exact overflow-bit computation (mul high-half / add carry) + `{s,u}sub.with.overflow`
for the non-fold-safe-constant case.

---

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
