# Bennett-stwr — orchestrator review of proposals A and B (3+1, the "+1")

2026-09-24. Implementation NOT started (maintainer asked for a single wave this session).
This note is the brief for the implementer.

## Where A and B agree (take as settled)
- Both reproduce the bug and both refute c2 A1's "fails loud, good news": most instances are
  **silent** (A: return-merge / diamond / loop / VarGEP cases; B: `soft_fadd` under
  `add=:cuccaro` is 29/30 wrong with zero simulator errors).
- Fixing the index space is not enough: after a loop `inst_counter` is inflated K-fold
  (cfg.jl:281,319,395) ⇒ the naive "honour `op2_dead`" fix is itself unsound (B's `lp` row).
- Per-path last-use liveness is the wrong notion for a predicated (every-block-executes) lowering.
  Delete `compute_ssa_liveness` / `ssa_liveness` / `inst_counter`; don't repair.
- Policy when in-place is unsafe: **copy-in** (CNOT-copy op2, Cuccaro on the copy). Not ripple
  fallback (mixes adder families under an explicit strategy — rule 6), not error (makes
  soft-float uncompilable under `:cuccaro`).
- `isdisjoint(a, b)` ArgumentError in `lower_add_cuccaro!`; loop contexts get the empty set;
  every existing pinned explicit-`:cuccaro` count unchanged (both measured).

## The one substantive disagreement — the eligibility criterion
- **A**: op2 eligible iff every use is in the add's block at position ≤ the add, one at the add,
  no terminator use, not a VarGEP index/alloca count. Admits values read EARLIER in the same block.
- **B**: op2 eligible iff exactly ONE operand occurrence in the whole function AND defined by a
  fresh-wire def (whitelist, `IRPhi` excluded) or a function argument.

B's `h` row is a counterexample to A's criterion: `u = y & x; t = x + y; u ⊻ t` — y is read earlier
in the same block (A: eligible) and B measured **65,280/65,536 wrong under `ValueEagerStrategy`**
because ValueEager's Phase 3 replays the `u` group AFTER y was overwritten (non-LIFO uncompute).
A's strategy matrix (its test 17) only covered `x+y+x` and `(x+y)+y`, which do not exercise this.
A also claims input-clobbering falls back to plain Bennett via the 07r in-place-group detection under
all strategies — the implementer must check whether that fallback triggers on `bennett(lr; strategy=
ValueEagerStrategy())` called directly (B's harness) vs via `reversible_compile` (possibly A's). Either
way the criterion must be sound for every strategy reachable through the public `bennett` API.

**Recommendation: B's criterion (S2 exclusive reader, global single occurrence + fresh-def whitelist)**,
plus from A: the lowering-time `_cuccaro_op2_exclusive(vw, …)` scan and `delete!(vw, op2)` as
defence in depth against whitelist drift (A's phi-alias and VarGEP cases are then doubly covered);
plus B's op1 commutative swap (keeps `x*y+x+y` and `(x+y)+y` copy-free).

## Tests: union of both plans
B's all-six-strategies sweep helper + non-vacuity check (`n_wires < ripple`), A's IR-shape
assertions per test (rule 5); cases: `(x+y)+y`, `x+x`, `x+x+x`, `(x+x)+y`, `c ? y : x+y`,
`(c ? x+y : x-y)+y`, `c ? x+y : y+x`, `d2`, `d3` (pin topo order), `h` (ValueEager), `lp`/`loopf`,
pre-loop value used once in loop, hand-built phi-alias ParsedIR, hand-written `.ll` VarGEP case,
`soft_fadd` bit-exact under `:cuccaro`, aliasing `@test_throws`, unit tests of the eligibility set,
in-place-still-fires GREEN guards (`x+y` 96/200/408/824, `x+1` 98), `use_inplace=false` pin,
`:auto` byte-identical to `:ripple`. Make `test_cuccaro_safety.jl` actually pass `add=:cuccaro`.
Rewrite `test_liveness.jl`'s `compute_ssa_liveness` testsets.

## Follow-ups to file when implementing
- Loop contexts silently force `:ripple` for explicit `:cuccaro`/`:qcla` (cfg.jl:259,389) — rule-1 tension.
- `lower_call!` lowers callees with the default `add`, ignoring the caller's explicit strategy.
- gates.jl hardening: reject `CNOTGate(c,c)` / Toffoli target ∈ controls at construction (perf check).
