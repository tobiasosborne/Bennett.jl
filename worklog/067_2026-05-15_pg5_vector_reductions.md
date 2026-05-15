## Session log — 2026-05-15 — Bennett-pg5 / U_ `llvm.vector.reduce.{add,mul,and,or,xor,smax,smin,umax,umin}.*` integer reductions

**Shipped:** native dispatch for the 9 LLVM integer vector-reduction intrinsics
in `src/extract/vectors.jl`. Adds a `_handle_vector_reduction` helper inside
`_convert_vector_instruction`'s `LLVMCall` arm — placed BEFORE the existing
`shape === nothing` "scalar return" reject (which used to fail loud on every
reduction). The helper:
  1. Detects a `llvm.vector.reduce.<op>.<vec-type>` call name with trailing-`.`
     discipline on each op token (`add.`, `mul.`, `and.`, `or.`, `xor.`, `smax.`,
     `smin.`, `umax.`, `umin.`).
  2. Resolves the single vector operand's lanes via `_resolve_vec_lanes`.
  3. Rejects float-lane vectors (`reduce.fadd` / `fmul` / `fmin` / `fmax` /
     `fminimum` / `fmaximum`) with a clear pointer at follow-up bead Bennett-lx5h.
  4. Rejects N=0 (LLVM langref says poison) with a clear error.
  5. For N=1: emits a single `add dest, lane[0], iconst(0)` rename — trivial.
  6. For N≥2: emits a left-to-right linear chain of N-1 binary ops folding
     the lanes into the scalar result. Last op writes `dest`.
     - `add` / `mul` / `and` / `or` / `xor` → `IRBinOp` with the matching `:sym`.
     - `smax` / `smin` / `umax` / `umin` → `IRICmp(<pred>) + IRSelect` per fold step
       (mirrors the scalar `llvm.smax`/`smin`/`umax`/`umin` lowering in
       `_handle_intrinsic`).

Test coverage: new `test/test_pg5_vector_reductions.jl` (~170 LOC) ships with
11 `.ll` fixtures (one per integer reduction op at the canonical width — 9
total — plus a v2i64 add for smallest-width corner and a v8i32 smax for
second-width / longer-fold-chain coverage), and 1 reject fixture
(`pg5_reduce_fadd_v4f64_reject.ll` covers the float-lane reject path).
Each green test simulates the compiled circuit against a Julia oracle
(`+ * & | xor max min`) — input typing chosen so the simulator's signedness
inference (Bennett-zc50 / U100) returns matching `Int*` / `UInt*` for direct
`==` comparison. `runtests.jl` registers the file right after
`test_ao66_vector_intrinsic_rescalarise.jl` (peer family).

Filed follow-up bead **Bennett-lx5h** (P3) for float vector reductions
(`llvm.vector.reduce.fadd` / `fmul` / `fmin` / `fmax` / `fminimum` / `fmaximum` /
`fminimumnum` / `fmaximumnum`) — would fold over the `soft_fadd` /
`soft_fmul` / `soft_fmin` / `soft_fmax` / `soft_fminimum` / `soft_fmaximum` /
`soft_minimumnum` / `soft_maximumnum` primitives shipped today (k2w6 + p19b),
but `fadd` / `fmul` carry a "start value" first-arg parameter whose
non-`-0.0` / non-`1.0` cases need careful handling for ordered vs reassoc'd
folds. Out of scope for pg5 per the bead's stated scope.

**Why:** Closes a fail-loud surface that was reachable from any auto-vectorised
Julia loop containing `sum(v)` / `prod(v)` / `reduce(&, v)` etc. on a small
vector. The existing `_convert_vector_instruction` LLVMCall arm rejected every
vector intrinsic with a scalar return ("vector intrinsic ... has scalar return
type; vector reductions are not supported") — pg5 replaces that catch-all with
native lowering for the 9 integer cases and tightens the catch-all message to
point at Bennett-lx5h for floats.

**Gotchas / Lessons:**

- **Dispatch site is `_convert_vector_instruction`, not `_handle_intrinsic`.**
  Vector reductions have a SCALAR result type (e.g. `i32`) but a VECTOR operand
  (e.g. `<4 x i32>`). The top-level `_convert_instruction` dispatcher routes on
  `is_vec_result || _any_vector_operand(inst)` (line ~1402 of `instructions.jl`),
  so reductions hit the vector path despite being scalar-returning. Adding a
  reduction arm to `_handle_intrinsic` instead would never fire — the call
  would be intercepted by the vector dispatch first. Cleaner to extend
  `_convert_vector_instruction`'s LLVMCall branch (where lane-resolution
  already happens).

- **Trailing-`.` discipline matters even within the vector-reduce family.**
  `llvm.vector.reduce.add.v4i32` and `llvm.vector.reduce.fadd.v4f64` share
  the `llvm.vector.reduce.` prefix; without trailing-`.` per op token,
  `startswith(cname, "llvm.vector.reduce.add")` would match
  `llvm.vector.reduce.add.v4i32` (good) but a hypothetical
  `llvm.vector.reduce.added.*` (no such intrinsic today, but disciplined
  matching is cheap insurance per Bennett-kh6n / chunk 066). All 9 arms use
  trailing-`.` (e.g. `"llvm.vector.reduce.add."`).

- **Float reductions have an extra "start value" first arg.** `fadd` and `fmul`
  reductions take a scalar start value (`fadd <start>, <vec>` →
  `start + sum(vec)`). Integer reductions don't — they take only the vector.
  The pg5 dispatch checks `length(call_args) == 2` (vec + callee) before
  proceeding; anything else is a fail-loud "unsupported reduction shape".

- **N=1 is the trivial corner case.** A 1-lane reduction's result is just
  `lane[0]`. Emit `IRBinOp(dest, :add, lane[0], iconst(0), w)` to copy the lane
  to the destination SSA name (mirrors the rename pattern in `extractelement`
  at vectors.jl line 241).

- **min/max reductions need fold-step temporaries.** Each fold step
  `acc = min(acc, lane[i])` expands into `IRICmp + IRSelect`. To avoid name
  collisions and let the lowering pass map each temp to a wire correctly, use
  `_auto_name(counter)` for both the cmp dest and the select dest at every
  step except the last (which writes `dest` directly).

- **Empty vectors should be unreachable in practice but rejected for safety.**
  LLVM langref says `<0 x iN>` is illegal at the type-system level (length must
  be > 0), but the IR-extract path defends in depth: a `n_expected == 0` from
  `_vector_shape` triggers `_ir_error("empty vector reduction")`.

**Rejected alternatives:**

- **3+1 protocol per CLAUDE.md §2:** skipped per the same exception used by
  Bennett-kh6n + Bennett-k2w6 + Bennett-mq6f + Bennett-p19b (chunk 066). The
  pg5 dispatch is mechanical (mirrors the existing per-lane intrinsic
  dispatch from ao66; reductions fold over already-extracted lanes via the
  same `_resolve_vec_lanes` helper). Documenting the exception here for the
  next 3+1 audit.

- **Tree-reduce (balanced binary tree) instead of linear left-to-right chain.**
  A tree fold has lower depth (log₂ N vs N) but gate-count parity for
  associative integer ops, and the Bennett construction makes the depth
  difference in *reversible* gate count negligible at the small N (≤16)
  realistically emitted by auto-vectorisers. Linear chain is cleaner to read
  and easier to verify. Filed as future work in Bennett-pg5's close note —
  if a hot path emerges with N≥32, switch to tree.

- **Routing min/max reductions through the existing `llvm.smax` / etc. handler
  via repeated 2-arg calls.** Considered but rejected: would require
  synthesising fake LLVM `Instruction` objects to pass to `_handle_intrinsic`,
  which doesn't have a clean factory API. Inlining the `IRICmp + IRSelect`
  pattern (3 LOC per fold step) is simpler than constructing a synthetic call.

**Validation:** Per-bead test file `test_pg5_vector_reductions.jl` green
(56/56 assertions across 12 testsets; one per integer reduction op + N=2
width corner + N=8 width corner + float-reject). Peer regressions also green:
ao66 (41/41), kh6n (4/4), k2w6 (434,472/434,472), mq6f (7367/7367), p19b
(227,276/227,276), intrinsics (1280/1280), float_intrinsics (27/27),
vector_ir (257/257), cc07_repro (65,537+257+6/65,537+257+6). Full
Pkg.test() not run per user MEMORY note (~27 min; focused regression
sample sufficient).

**Next agent starts here:** pg5 closes the integer half of LLVM vector
reductions. The float half (Bennett-lx5h, P3) is the obvious follow-up —
mostly mechanical now that `soft_f{add,mul,min,max,minimum,maximum}` /
`soft_{minimum,maximum}num` are all in the callee registry. The "start
value" first-arg semantics for `fadd` / `fmul` need a thin wrapper at the
fold-init step. Or pick a different P3 from the catalogue.
