# Bennett.jl Work Log

## Session log — 2026-05-01 (late late evening) — Tier A grind: Bennett-h6f + Bennett-4eu + Bennett-imz7 closed

**Shipped:** three-bead Tier A grind in one session. See git log for the
commit; the diffs are mechanical.

- **Bennett-h6f** — `llvm.fma.f64` / `llvm.fmuladd.f64` direct dispatch
  in `_handle_intrinsic` → `IRCall(soft_fma, ...)`. `soft_fma` already
  existed (Bennett-0xx3, 2026-04-16). Both intrinsics route to soft_fma
  (single-rounding, bit-exact vs `Base.fma`) — the alternative
  (fmuladd → fmul+fadd split per LangRef permission) would produce a
  different last-ulp answer than fma on the same inputs, which CLAUDE.md
  §1+§13 explicitly forbid. New test file (14 asserts) + 2 `.ll`
  fixtures (`h6f_fma_f64.ll`, `h6f_fmuladd_f64.ll`).

- **Bennett-4eu** — `indirectbr` declared a Bennett hard stop. The
  bead text already noted "no Julia function produces this"; C `goto
  *ptr` is a GCC extension uncommon in numerical code; Rust doesn't
  emit it. The static-CFG model that phi resolution + loop unrolling
  depend on requires compile-time-known branch targets. Implemented
  as a precise fail-loud error in `_convert_instruction` with an
  actionable message (was a generic "unsupported opcode" error
  before). Same philosophical category as atomicrmw / invoke /
  landingpad / fence. New test (2 asserts) + 1 `.ll` fixture
  exercising blockaddress + indirectbr.

- **Bennett-imz7** — vpch follow-up sweep. ~24 source sites tightened
  from generic `error()` to typed exceptions
  (`ArgumentError` / `DimensionMismatch` / `AssertionError`) across 8
  files. Matching `@test_throws ErrorException` in 9 test files
  updated to the specific exception class. The classification:
  caller-supplied bad input → `ArgumentError`; internal compiler
  invariant → `AssertionError`; wire-length / shape mismatch →
  `DimensionMismatch`.

**Why:** post-dnh-close the user named "deal with tier A stuff. grind
it out" — quick wins in the same opcode-coverage axis. Tier A was
{h6f, 4eu, imz7}: each shippable in one session.

**Gotchas / Lessons:**

- **The "deferred under stale conditions" pattern.** Bennett-h6f was
  marked deferred 2026-04-11 with rationale "Option B requires new
  soft_fma (~100 lines)." Two days later soft_fma shipped under
  Bennett-0xx3, but h6f's deferred status didn't get re-evaluated for
  ~3 weeks. Filed similar lesson in chunk 053's dnh entry — beads
  with conditional-defer text need a follow-up note when the
  condition lifts. Pre-empt this for the future: I'm now adding a
  `bd remember` note about the pattern.
- **`indirectbr` is genuinely a static-CFG break.** I considered
  implementing a partial version that handles `phi(blockaddress(@f,
  %A), blockaddress(@f, %B))` patterns by lowering as cascaded
  conditional branches. Rejected because: (a) Bennett's IR types
  don't currently include a "block address" notion — adding one
  ripples through extract/lowering/IR types; (b) for raw .ll sources
  that use indirectbr in computed-jump tables (the realistic case),
  the address comes from a load-from-memory pattern that requires
  block-address tracking through pointer ops — substantial
  workstream. (c) "no Julia function produces this" means there's no
  workload demand. Hard-stop with a precise message is the right
  pragmatic answer.
- **`AssertionError` and `ArgumentError` both have `.msg`.** Tests
  that assert on `err.msg` work after switching from `ErrorException`
  to either. Same for `sprint(showerror, e)`. So the migration was
  mostly mechanical — just change the type assertion.
- **The benign-skip filter in module_walk.jl is robust to the
  migration.** The filter at line 198 checks for "ir_extract.jl:" /
  "Bennett-" prefix in the message to identify Bennett-authored
  errors and let them propagate. My new throws still produce those
  prefixes, so the filter correctly distinguishes them from LLVM.jl's
  own "Unknown value kind" / "LLVMGlobalAlias" pass-throughs.

**Rejected alternatives:**

- For h6f, splitting `llvm.fmuladd` into fmul+fadd per LangRef
  permission. The split is allowed but produces a different rounding
  result than fma. CLAUDE.md §13's bit-exact contract argues for
  single-rounding (soft_fma) on both. The user can opt out via
  `@fastmath` (which uses `j_*` callees instead of LLVM intrinsics)
  if they want the faster, less-accurate variant.
- For 4eu, attempting partial `indirectbr` lowering. See gotcha
  above — substantial workstream gated on a workload that doesn't
  exist.
- For imz7, leaving the `@test_throws ErrorException` assertions as-is.
  Resisted: the whole point of Bennett-vpch (U45) was tightening error
  classes for predictable error handling; leaving the test side
  generic defeats the purpose.

**Catalogue at session end:** Three more closes brings the open-
opcode/intrinsic-coverage tail to:

- `Bennett-3mo` (P3) — `llvm.sin/cos`, biggest remaining body
- `Bennett-582` (P3) — `llvm.log/log2/log10`
- `Bennett-emv` (P3) — `llvm.pow/powi` (composes from log+exp)
- `Bennett-hao` (P3) — `llvm.memcpy/memmove/memset` real lowering
- `Bennett-vb2` (P3) — vector ops
- `Bennett-pg5` (P3) — `llvm.vector.reduce.*`
- `Bennett-tfx` (deferred) — `frem`
- `Bennett-36m` (deferred) — `with.overflow` arithmetic
- `Bennett-g4g` (deferred) — saturating arithmetic

The Tier A "quick wins" frontier is now empty. Remaining intrinsic
work is medium (hao/vb2/pg5) or large (3mo/582/emv).

**Next agent starts here:** **Bennett-hao** is probably the right next
grind — `llvm.memcpy/memmove/memset` real lowering. Currently
benign-drop, which is a correctness gap not a fail-loud one (silent
drop of a memcpy means the destination is whatever zero-init left it
as). ~150 LOC of per-byte reversible copy loop.

Alternatively **Bennett-3mo (sin/cos)** is the largest soft-float body
remaining and the most-requested Julia primitive missing — multi-
session work but unlocks `Base.sin/cos/tan` for all users. Cody-Waite
range reduction + Payne-Hanek for large arguments + polynomial.

## Session log — 2026-05-01 (late evening, post-nj6c) — Bennett-cb9y + Bennett-dnh close — multi-origin × runtime-idx walls closed → OPCODE PARITY for runtime-indexed memory

**Shipped:** see git log for the next commit. Closed both `:NYI` walls
identified in the dnh research:

- `src/lowering/memory.jl:141` (multi-origin store with dynamic idx) →
  multi-origin loop now dispatches on strategy. `:shadow` (existing
  M2b path), `:shadow_checkpoint` (new, via `extern_pred_wire` kwarg
  threaded through `_lower_store_via_shadow_checkpoint!`), or
  `:mux_exch_NxW` (new, via `extern_pred_wire` threaded through the
  @eval-generated `_lower_store_via_mux_NxW!`). Per-origin
  `predicate_wire` from `ptr_provenance` is the guard.

- `src/lowering/aggregate.jl:362` (multi-origin load with dynamic idx)
  → for runtime-idx origins, synthesise a fresh-dest `IRLoad`, route
  through `_lower_load_via_mux!` (which dispatches MUX-EXCH or
  shadow_checkpoint per shape), then `Toffoli(predicate_wire,
  value[i], result[i])` merges the loaded value into the multi-origin
  result. Bennett's reverse pass uncomputes the synthetic load's
  ancillae symmetrically.

New helper `_mux_store_pred_sym_from_wire!` in memory.jl factors out
the predicate→u64 promotion (CNOT into bit 0 of fresh 64-wire block)
from `_mux_store_pred_sym!` so callers with raw wires (multi-origin)
and callers with block labels (single-origin non-entry) share the
same code path.

**With cb9y closed, Bennett-dnh closes too.** OPCODE PARITY for
runtime-indexed memory: every `load` / `store` / `getelementptr` at a
runtime SSA index compiles, single-origin OR multi-origin, on shapes
ranging from (2,8) packed to (8,16) shadow-checkpoint. Bennett's LLVM
memory-opcode coverage matches Enzyme's (modulo correctly-hard-stop
atomics and EH per CLAUDE.md/auto-memory rules).

**Why:** The user named "LLVM IR parity with Enzyme" as the post-
catalogue goal and dnh as the most-difficult remaining bead. The
research sweep determined dnh was actually engineering (not research)
and split it into two phases. Both phases shipped same day.

**Gotchas / Lessons:**

- **Synthetic IRLoad as a primitive recompose tool.** For multi-origin
  dynamic-idx LOAD I needed to "compute the per-origin selected value
  into fresh wires." Direct-call into the @eval-generated body would
  bypass the strategy dispatch (loses :shadow_checkpoint coverage).
  Cleanest pattern: synthesise an `IRLoad(synth_dest, dummy_ptr, W)`
  and call `_lower_load_via_mux!(ctx, synth_inst, origin)`. The
  function reads only `dest` and `width` from the instruction (not
  `ptr`), so the dummy is fine. After the call, `ctx.vw[synth_dest]`
  holds W wires with the loaded value. This pattern composes
  arbitrary single-origin lowering paths into multi-origin
  fan-outs without duplicating their bodies.
- **`extern_pred_wire` kwarg pattern.** Three places now accept this
  kwarg (the @eval store body, `_lower_store_via_shadow_checkpoint!`,
  and the per-call helpers). Priority: `extern_pred_wire` >
  `block_label` > entry-block-unguarded. The priority order matters:
  multi-origin context overrides block context (because the per-
  origin predicate is structurally tighter than the block predicate).
- **`_mux_store_pred_sym_from_wire!` is a tiny refactor with leverage.**
  The 1→64 CNOT promotion was duplicated implicitly between
  `_mux_store_pred_sym!` (block-derived) and what I'd have inlined in
  the multi-origin loop. Factoring into a shared helper made the
  multi-origin loop a one-liner per origin and kept the block-
  derived call site byte-identical.

**Rejected alternatives:**

- For multi-origin LOAD, computing the per-origin value via "Toffoli3"
  (3-control X gate). Bennett doesn't have C3-X as a primitive; would
  require an explicit AND-of-predicates ancilla. The synthetic-IRLoad
  approach reuses existing infrastructure with zero new gate types.
- Per-origin per-slot (k) explicit MUX in the multi-origin loop —
  i.e. iterate origins × slots and emit `Toffoli(predicate AND
  idx_eq_k, primal[k][i], result[i])`. Would duplicate
  `_lower_load_via_shadow_checkpoint!`'s body inline. Worse: harder
  to keep in sync with the single-origin path. Synthetic-IRLoad wins.
- Closing dnh without the (8,16) shadow_checkpoint test case. Would
  leave `:shadow_checkpoint multi-origin is a future bead` as a
  documented gap. Decided that "OPCODE PARITY" should mean *every*
  shape works, including N·W > 64 multi-origin, so I extended
  `_lower_store_via_shadow_checkpoint!` with `extern_pred_wire` too.

**Catalogue at session end:**

- Bennett-dnh: **closed** (re-scoped + both opcode phases shipped)
- Bennett-nj6c: closed (phase 1a)
- Bennett-cb9y: closed (phase 1b)
- Bennett-8guh (P2): open, IRSwap primitive (3+1 architectural)
- Bennett-6c6f (P3): open, QROAM cost win

Bennett-25dm (the remaining open `[bug]`, blocked on `z2dj` T5-P6)
unchanged. The catalogue's last opcode-coverage gap from Enzyme's
perspective is now closed.

**Next agent starts here:** **Bennett-8guh** (IRSwap primitive) is the
right next pickup if you want a 3+1 architectural unification — it'd
collapse the synthetic-IRLoad pattern from cb9y into a first-class IR
node and is the substrate for Bennett-6c6f QROAM. Otherwise pick up
**Bennett-h6f** (`llvm.fma.f64` direct dispatch — `soft_fma` already
exists, just wiring) for a quick mechanical follow-up to Bennett-1pb
on the intrinsic dispatch axis.

## Session log — 2026-05-01 (late evening) — Bennett-nj6c close — runtime-idx MUX-EXCH on extended shapes

**Shipped:** see git log for the next commit. `_MUX_SHAPES_NW` extended
from the original 6 hand-picked shapes to all (N,W) with N·W ≤ 64,
N ∈ {2..8, 16, 32}, W ∈ {8, 16, 32}. Added soft_mux_load_NxW /
soft_mux_store_NxW / soft_mux_store_guarded_NxW for (3,8), (5,8), (6,8),
(7,8), (3,16) via parametric @eval in `src/softmem.jl`. Closes the
`:unsupported` arm at `src/lowering/memory.jl:84-95` for these shapes.
Phase 1a of the Bennett-dnh re-scope (see chunk-053 dnh entry below).

**Why:** the lowering side (`memory.jl:448-524` @eval loop) was already
fully parametric over `_MUX_SHAPES_NW` since Bennett-lm3x / U56
(2026-05-01 morning, chunk 050). Adding shapes there auto-generated
`_lower_load_via_mux_NxW!` / `_lower_store_via_mux_NxW!` helpers — the
gap was purely the missing soft_mux_*_NxW callees and the
registration list. So nj6c is mostly a registration cleanup, not new
lowering machinery.

**Gotchas / Lessons:**

- **NTuple inputs route around the wall.** I first tried to drive the
  MUX-EXCH `:unsupported` arm by compiling
  `f(arr::NTuple{3,Int8}, idx) = arr[idx]`. That actually compiled — at
  1752 gates — because NTuple-typed *arguments* go through
  `_lower_load_legacy!` (`aggregate.jl:426-`) which uses a binary MUX
  tree over input wires regardless of shape. The MUX-EXCH walls only
  fire for ALLOCA-ed memory accessed at runtime indices. Test harness
  switched to hand-crafted `define i8 @julia_f_1(...)` LLVM IR with
  `alloca i8, i32 N` — same pattern as `test/test_mutable_array.jl`.
- **Entry-function naming is load-bearing.** `_module_to_parsed_ir`
  expects the entry to be named `julia_*` or `j_*` (per
  `extract/module_walk.jl:15`). My initial fixtures used `@f` and
  failed loud with "no julia_* function found in LLVM module". Renamed
  to `@julia_f_1` matching the existing test harness.
- **Pre-existing regression test counts must be updated in lockstep.**
  `test/test_tfo8_alloca_strategy_tables.jl` pinned `_MUX_EXCH_STRATEGY`
  to exactly 6 shapes; `test/test_kmuj_callee_groups.jl` pinned the
  total registered-callee count at 52 and per-group sizes including
  `_CALLEES_MUX_EXCH == 12` and `_CALLEES_MUX_EXCH_GUARDED == 6`.
  Nj6c bumps these to 11 shapes / 67 total / 22 / 11. CLAUDE.md §6
  applies but the asserts are per-group counts, not gate counts —
  intentional regression anchors that need explicit updating.
- **Direct `julia test/runtests.jl` differs from `Pkg.test()`.** Aqua.jl
  isn't on the default project's deps; only Pkg.test activates the
  test environment with extras. Running runtests.jl directly produces
  a spurious "Aqua not found" error that's not a real regression.
  Confirmed nj6c green via Pkg.test (487,074 pass / 0 fail / 3 broken).

**Rejected alternatives:**

- Replacing the hand-written variants with the parametric @eval at the
  same time. Would consolidate the two existing M1-era code blocks
  (lines 26-100 unguarded for (4,8)/(8,8); lines 102-215 unguarded for
  (2,8)/(2,16)/(4,16)/(2,32)) but the @eval body uses `ntuple+reduce`
  which inlines to (presumably) the same compiled IR but isn't
  *byte*-identical. Gate counts on the existing 6 shapes are pinned in
  worklog/048 and elsewhere — don't risk a regression for a clean-up
  win. Filed as a possible follow-up: "consolidate hand-written +
  @eval MUX-EXCH bodies under a single generator" — only if a future
  agent confirms the gate counts match.
- Generating @eval for ALL shapes (including the existing 6) and
  deleting the hand-written variants. Same gate-count regression risk.

**Catalogue at session end:** Bennett-dnh now has a concrete plan
recorded in its notes; 4 sub-beads filed (nj6c [closed], cb9y [open],
8guh [open, P2], 6c6f [open]). nj6c shipped; cb9y is the next
opcode-coverage hop on the dnh critical path. Bennett-25dm (the
remaining open bug, blocked on z2dj) unchanged.

**Next agent starts here:** pick up **Bennett-cb9y (dnh-multi-origin)**
— close the `:NYI` walls at `src/lowering/aggregate.jl:362`
(_lower_load_multi_origin!) and `src/lowering/memory.jl:191`
(_emit_store_via_shadow_guarded!). Same pattern as nj6c (test with
hand-crafted IR using a phi/select that merges two alloca pointers, RED,
then implement 2D dispatch over (origin × slot). After cb9y closes, the
opcode-parity claim for runtime-indexed memory is ship-able.

## Session log — 2026-05-01 (evening, post-1pb) — Bennett-dnh research & re-scope

**Shipped:** no code change — research + planning + bead filing.
4 new beads filed: Bennett-nj6c (dnh-shapes, P3, closed same session),
Bennett-cb9y (dnh-multi-origin, P3), Bennett-8guh (bennett-irswap, P2,
3+1 required), Bennett-6c6f (bennett-qroam, P3). Bennett-dnh notes
field updated with the post-research plan.

**Why:** the user named "LLVM IR parity with Enzyme" as the post-
catalogue goal and asked for the "MOST difficult" remaining bead.
Bennett-dnh (QRAM for variable-index access — RESEARCH) was the
only RESEARCH-tagged bead in the open queue and the genuine wall in
Bennett's memory model. Filed in 2026-04-10 with text "Defer until
persistent tree approach evaluated" — that evaluation was completed
in worklog/026 (linear_scan won at all measured scales), so dnh was
ready to be re-scoped from research to engineering.

**Six-agent research sweep:** three Explore agents on the codebase
(memory model wall, persistent-DS workstream context, failure surface)
and three general-purpose agents on external literature (QRAM
constructions, reversible-programming-language tradition, persistent
functional DS in reversible regime). Convergent conclusions:

1. **The wall is narrower than dnh's text implies.** N·W > 64 is
   already handled via T4 `:shadow_checkpoint` (slow but functional);
   the `:unsupported` arm fires only for shapes with N·W ≤ 64 outside
   the 6 hand-picked ones. PLUS two multi-origin walls at
   `aggregate.jl:362` and `memory.jl:191` that were not in dnh's
   original framing.
2. **Persistent trees are dead.** worklog/026's empirical finding
   (linear_scan ~414 gates/set CONSTANT in N vs CF semi-persistent
   blowing up to O(N²)) is *consistent* with the literature's
   preference for unary-iteration QROM (Babbush-Gidney 2018,
   arXiv:1805.03662) at small N. The "right reversible DS is one
   whose per-op pattern matches what Bennett can compress: a single
   target slot with N-1 no-op preserves" (chunk 026's durable
   lesson).
3. **Hermes/Janus settled on swap-mutate-swap** for `arr[i] := f(arr[i], v)`
   (Mogensen RC 2020 / SCP 2022). Self-inverse swap pair round-trips
   through bennett(lr) without leaking. This is the architectural
   substrate for any QROAM-style cost win.
4. **QROAM SELECT-SWAP** (Babbush et al. 1805.03662 §III-B/D + Gidney
   1905.07682 windowed-arithmetic) is the published cost win:
   O(√(N·W)) Toffoli RMW vs current T4's O(N·W) — ~32× at N=64 W=64.

**Rejected alternatives:**

- Filing dnh as a single P2 bead with a 4-phase plan baked into its
  description. Too coarse — the four phases are independently
  shippable and the IRSwap one is 3+1 territory. Better to file four
  beads with explicit dependencies recorded in dnh's notes (since
  `bd dep add` fails on this Dolt store per the
  advanced-arithmetic-workstream memory).
- Lumping the "research follow-ups" (single-shot scatter-add primitive,
  bucket-brigade for N≫10⁴, hash-consing) into a Phase 4. Pure
  can-kicking — none of those are opcode gaps. Dropped from the
  plan; flagged as filable beads only if motivated by a workload.
- Bumping bennett-irswap's priority because it's a 3+1 architectural
  change. Resisted: nj6c + cb9y close the opcode-coverage gap without
  it. IRSwap remains the right architectural unification but doesn't
  block opcode parity. P2 stays.

**Gotchas / Lessons:**

- **The bead text for dnh predated its own evaluation.** "Defer until
  persistent tree approach evaluated" was written 2026-04-10; the
  persistent-DS evaluation completed 2026-04-20 (worklog/026). The
  bead lay open with stale framing for ~3 weeks. Lesson: when a bead
  says "defer until X is evaluated," put a follow-up note in the bead
  the moment X is evaluated, not three weeks later when someone
  notices.
- **"Most difficult" is multi-axis.** sin/cos (Bennett-3mo) is the
  largest body of work (~1000 LOC, well-understood literature).
  Multi-language xkv is the broadest. EscapeAnalysis (Bennett-glh) is
  the most architecturally invasive. dnh is the only one where the
  classical-reversible cost regime hits an active research wall —
  which made it the right "most difficult" answer for the *Enzyme-
  parity* lens, but a different question (e.g. "highest user-visible
  impact") would have produced a different answer.
- **The "QRAM" framing of dnh was misleading.** Bucket-brigade QRAM is
  for N ≫ 10⁴ with noise-resilience constraints. At Bennett's scale
  (N ≤ 256) the right primitives are unary-iteration QROM (read-only)
  and SELECT-SWAP/QROAM (mutable). Renaming the workstream to
  "runtime-indexed mutable memory" would be honest but the bead ID
  Bennett-dnh stays.

**Next agent starts here:** the four sub-beads above. Pick up
Bennett-nj6c first (mechanical, ~150 LOC), then Bennett-cb9y
(multi-origin × runtime idx, ~200 LOC). After both ship, Bennett-dnh
closes — opcode parity for runtime-indexed memory is achieved.
Bennett-8guh and Bennett-6c6f are independent quality wins, not on
the dnh critical path.

