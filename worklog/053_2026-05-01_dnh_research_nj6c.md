# Bennett.jl Work Log

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

