## Session log — 2026-04-16 — M2a Bucket C1 cross-block ptr_provenance

PRD §10 M2 was originally scoped as "wire MemorySSA into dispatcher".
Deep research on the actual failure modes (L7, L8 in corpus) showed
that M2's problem space is THREE distinct sub-issues, and MemSSA
addresses only one of them. Split accordingly:

  C1 = cross-block ptr_provenance state lifetime (THIS session, M2a)
  C2 = pointer-typed phi/select (M2b, ir_extract.jl extension)
  C3 = conditional-store path-predicate guarding (M2c, Bennett-oio4)

### Research phase

- Read `src/memssa.jl`, `docs/memory/memssa_investigation.md`,
  `src/lower.jl` key functions. Findings:
  - `MemSSAInfo` parses `print<memoryssa>` stderr output into def/use
    graph. Fully built, NOT yet consumed by dispatcher.
  - `ptr_provenance` is a local Dict in `LoweringCtx`. SHOULD be
    per-function but actually per-block due to constructor pattern.

- Classified the failing patterns by running each through the pipeline:

  | Pattern | Error |
  |---|---|
  | Cross-block store through GEP | `no provenance for ptr %g0` at src/lower.jl:1820 |
  | Branched stores to diff indices | same |
  | Pointer-phi | `Unsupported LLVM type for width: LLVM.PointerType(ptr)` at ir_extract |
  | Pointer-select | same |

  The first two are state-lifetime bugs. The second two are
  extractor-type-support gaps.

### 3+1 agent protocol

Spawned two independent proposers in parallel (via Agent tool):

- **Proposer A (minimal-change, general-purpose)**: thread
  `alloca_info` + `ptr_provenance` as kwargs through `lower_block_insts!`,
  matching existing idiom for `ssa_liveness` / `inst_counter` /
  `gate_groups`. ~15 line diff. Kept block-local `mux_counter`
  (synthetic names already embed a globally-unique hint, no
  collision risk).

- **Proposer B (clean-refactor, general-purpose)**: split
  `LoweringCtx` into `FunctionCtx` (per-compilation) + `LoweringCtx`
  (per-block view) with property-forwarding via `Base.getproperty`.
  Collapses 4 constructor overloads. ~80+ line diff. Also fixes
  `mux_counter` lifetime (which B claimed was buggy; A's precise
  analysis showed it was not).

### Orchestrator decision

Chose Proposer A. Rationale:

1. B's claim that `mux_counter` is buggy is WRONG. Synthetic names
   are `"op_hint_counter"` where `hint` is a globally-unique SSA
   name — no collision. A correctly kept it block-local.
2. CLAUDE.md §7 "bugs are deep and interlocked" favours minimal touch
   on a bug that turns out (see below) to expose a DIFFERENT latent
   bug. Smaller blast radius leaves room to debug.
3. B's refactor is sound long-term; defer to a dedicated milestone
   once a second memory field (e.g. T4 shadow checkpoint tape) wants
   the same lifetime.

### Implementation

Applied A's fix in three edits to `src/lower.jl`:

1. Line ~313 (in `lower()`): allocate `alloca_info` + `ptr_provenance`
   Dicts once per compilation, next to `inst_counter`.
2. Line ~387 (call site): pass as kwargs to `lower_block_insts!`.
3. Line ~549 (signature) + ~558 (ctx construction): accept kwargs with
   fresh-Dict defaults (backward-compat), forward to `LoweringCtx` via
   the 17-arg struct constructor directly.

### Unexpected finding: latent correctness bug surfaced (→ M2c)

Post-fix, L7a-original-draft (branched store) compiled but simulated
incorrectly. Trace:

    L7a: if c then store x at slot 0; load slot 0 → returns 0 or x?
    Expected: c=true → x, c=false → 0.
    Actual:   c=true → x, c=false → x (wrong; store fires regardless).

Root cause: `_lower_store_via_shadow!` and `_lower_store_via_mux_*!`
both emit unconditional writes to the alloca's primal wires. No
block-predicate guarding. `verify_reversibility` still passes because
the Bennett reverse un-does the unconditional write, but semantics
are wrong on the inactive-branch path.

This latent bug was MASKED by the cross-block provenance bug (branched
stores couldn't compile at all before M2a). M2a exposes it.

### Test corpus reshuffle

Split L7 into:

- **L7a, L7b (GREEN, M2a)**: cross-block LOAD patterns (alloca+store
  in `top`, load in branch). These exercise the state-lifetime fix
  without touching conditional-store semantics.
- **L7c, L7d (RED, M2b)**: pointer-typed phi/select; still crash at
  ir_extract.
- **L7e (@test_broken, M2c)**: conditional-store semantics. Verifies
  reversibility AND c=true path, but marks c=false path broken until
  path-predicate guarding lands.

### Deliverable

- `src/lower.jl`: ~15 lines changed. Three edits plus a docstring note.
- `test/test_memory_corpus.jl`: L7a, L7b rewritten as GREEN cross-block
  LOAD tests. L7e added as @test_broken for the deferred semantic issue.
  L7c, L7d unchanged (still RED for M2b).
- `WORKLOG.md`: this entry.
- Filed Bennett-oio4 (M2c) for the deferred conditional-store fix.
- `BENCHMARKS.md` regenerated: i8=100, i16=204, i32=412, i64=828;
  soft_fma=447,728; soft_exp_julia=3,485,262; MUX EXCH table unchanged.
- Full suite: `Testing Bennett tests passed`. Memory corpus: 489
  pass + 1 broken (L7e, expected).

### Gotchas learned (for future agents)

- **Fresh `LoweringCtx` per block.** `lower_block_insts!` calls the
  13-arg constructor which default-initialises memory fields. This
  pattern was added incrementally as memory features shipped — the
  intent was "per-function state" but the constructor never got
  updated. Any future per-function field added to `LoweringCtx` will
  hit the same bug unless the constructor-threading pattern is used.

- **`verify_reversibility` is not a semantic check.** The Bennett
  reverse construction can undo unconditional writes cleanly, so a
  semantically-wrong circuit can still pass reversibility. Always
  combine `verify_reversibility` with an input-sweep correctness check.

- **Proposer overconfidence is a real risk in 3+1.** Proposer B's
  claim about `mux_counter` was confidently stated and wrong. The
  orchestrator has to independently verify, not just pick the
  "better-looking" design.

- **The PRD's M2 scope was too coarse.** "Wire MemSSA into
  dispatcher" described one of three problems. Running each failing
  pattern through the compiler first (10 minutes of work) exposed
  the real structure. Future milestones should RED-test first even
  when the PRD seems clear.

### Next agent steps

1. **M2b** (pointer-typed phi/select support): extend `ir_extract.jl`
   to accept pointer-typed phi/select; extend `ptr_provenance` to
   handle multi-origin entries (or similar); extend dispatcher to
   emit controlled-stores/loads to each possible underlying alloca.
   CORE CHANGE → 3+1 agents.

2. **M2c** (path-predicate guarding, Bennett-oio4): add `block_pred`
   threading to store lowering. Shadow path loses its "0 Toffoli"
   property inside branches (CNOT→Toffoli). MUX path needs
   double-compute + MUX-on-predicate. CORE CHANGE → 3+1 agents.

3. **M3** (T4 shadow-checkpoint, original PRD plan). Bigger than M2b
   and M2c; depends on M2c's path-predicate threading.

Order depends on what the user wants. I'd suggest M2b (largest
coverage gain) then M2c (closes the last semantic gap before M3).

---

## Session log — 2026-04-16 — soft_exp_julia / soft_exp2_julia (Bennett-t110, Plan A)

Julia-faithful `exp` and `exp2` bit-exact vs `Base.exp` / `Base.exp2` on
FMA-capable hardware. Line-for-line port of `Base.Math.exp_impl` from
`julia/base/special/exp.jl` (lines 207-231) with every `muladd` replaced
by `soft_fma`.

Closes the ≤1 ulp gap that Plan B (Bennett-wigl, musl-based) left open:
musl uses separate fmul+fadd in range reduction producing different
intermediate `r` values at round-half cases; Julia uses FMA-based
`muladd` for single rounding. Landing `soft_fma` (Bennett-0xx3) made
the Plan A port trivial — 182 LOC for both functions + the shared core.

### Algorithm (verbatim from Julia Base)

```
N_float = fma(x, 256/log(b, 2), 1.5·2^52)              # muladd + MAGIC round trick
N       = reinterpret(UInt64, N_float) % Int32         # rounded integer
N_float = N_float - 1.5·2^52                           # undo MAGIC
r       = fma(N_float, LogBo256U, x)                   # Cody-Waite part 1
r       = fma(N_float, LogBo256L, r)                   # Cody-Waite part 2
k       = N >> 8
jU, jL  = J_TABLE[N & 255]                             # 256-entry table (QROM)
# Horner polynomial: degree-3 on [−log(b,2)/512, log(b,2)/512]
p       = fma(r, C3, C2); p = fma(r, p, C1); p = fma(r, p, C0)
kern    = r * p                                        # = expm1b_kernel(base, r)
small_part = fma(jU, kern, jL) + jU
# Normal: result = reinterpret(Float64, (k<<52) + reinterpret(Int64, small_part))
# Subnormal (k ≤ -53): result = reinterpret(Float64, ((k+53)<<52) + bits(small_part)) · 2^-53
# Overflow: ±Inf; underflow: 0.0; NaN: pass-through (not canonicalized)
```

5 muladds main flow + 3 muladds for Horner + 1 fmul for outer `r·poly`
+ 1 fadd (`+ jU`). Plus a 256-entry `J_TABLE` compile-time QROM lookup.

### Shared core refactor

`_exp_impl_julia` takes the base-specific constants as arguments and
is called by both `soft_exp_julia` (base ℯ) and `soft_exp2_julia`
(base 2). Single-source code path → half the compile-time work vs
duplicating.

### Test coverage

`test/test_softfexp_julia.jl` (~180 LOC): for each of exp and exp2:
- Integer arguments (k ∈ -10..10): bit-exact
- Well-known values (e, 2, 0.5, etc.)
- Specials (NaN, ±Inf)
- Overflow / underflow boundaries
- Subnormal-output range (k ≤ -53 path)
- 10k random sweep [-100, 100]
- 10k random full-range [-700, 700] for exp (matches Bennett-t110 spec)
- 2k subnormal-output sweep (Bennett-fnxg convention)

**All 81 tests pass on first run** (36 soft_exp_julia + 45 soft_exp2_julia).
Bit-exact vs Base.exp / Base.exp2 across every tested region.

### End-to-end circuit

| Function | Gates | Toffoli | T-count | Ancilla | Compile |
|----------|------:|--------:|--------:|--------:|--------:|
| soft_exp_julia  | 3,485,262 | 1,195,196 | 8,366,372 | 995,280 | 36s |
| soft_exp2_julia | 2,697,734 | 890,168 | 6,231,176 | 774,542 | 1s (cache hit) |

`verify_reversibility(c; n_tests=3)` passes for both. All 14 per-function
sample inputs (including NaN, Inf, subnormal region, overflow boundary)
bit-exact vs `Base.exp` / `Base.exp2`.

### Comparison vs Plan B (musl-based soft_exp / soft_exp2)

| Function | Plan A (Julia) | Plan B (musl) | Savings |
|----------|---------------:|--------------:|--------:|
| exp  total gates  | 3,485,262 | 4,958,914 | 30% fewer |
| exp  Toffoli      | 1,195,196 | 1,693,984 | 29% fewer |
| exp2 total gates  | 2,697,734 | 4,348,418 | 38% fewer |
| exp2 Toffoli      |   890,168 | 1,465,382 | 39% fewer |

Plan A is **cheaper AND more accurate** (bit-exact vs Julia, not just
≤1 ulp). This is because Julia uses a degree-3 polynomial on a tighter
domain (|r| ≤ log(b,2)/512) thanks to the 256-entry table, while musl
uses degree-5 on the 128-entry table (domain |r| ≤ log(b,2)/256).
Smaller polynomial → fewer fma's.

### Dispatch change

`Base.exp(::SoftFloat) = SoftFloat(soft_exp_julia(x.bits))`
`Base.exp2(::SoftFloat) = SoftFloat(soft_exp2_julia(x.bits))`

The musl-bit-exact `soft_exp` and `soft_exp2` remain exported as the
cross-language reference. `soft_exp_fast` / `soft_exp2_fast` remain as
the flush-to-zero subnormal variants for speed-critical users.

### Gotchas learned (for future agents)

1. **`muladd` in Julia compiles to `@llvm.fmuladd.f64`**, which MAY
   fuse on FMA hardware. Empirically on x86_64+FMA3 (WSL Linux), every
   muladd in `exp_impl` does fuse — confirmed by the bit-exact match
   across 22k+ random inputs. Port using soft_fma; if Base.exp changes
   its fusion behavior, we'd need to match the new pattern.

2. **Operator precedence**: Julia has `&` at multiplication precedence,
   so `N & 255 + 1` parses as `(N & 255) + 1`, not `N & 256`. Critical
   for the table index. Matches the source.

3. **`reinterpret(UInt64, Int64(k) << 52)`** is the idiomatic way to
   convert a signed shift result to a UInt64 bit pattern without
   InexactError. `UInt64(Int64(k) << 52)` throws for negative k;
   `reinterpret` preserves the bit pattern.

4. **NaN pass-through**: Julia's `exp_impl` returns the INPUT NaN
   (preserving payload), not a canonical QNAN. Match this. My select
   chain: `result = ifelse(is_nan, a, result)` — a is the input.

5. **J_TABLE indexing**: `getfield(tuple, Int(ind))` vs `tuple[Int(ind)]`
   should both lower to QROM. I used `getfield` to match Julia's pattern
   (avoids potential inbounds-check noise in LLVM IR).

6. **First-run success** (rare!): the port was clean enough that no
   iteration was needed. Attribution: soft_fma was bit-exact, the
   algorithm was well-specified in source, and `_sf_handle_subnormal` /
   `_sf_round_and_pack` (existing helpers) composed naturally with the
   muladd chain.

### Files changed

- `src/softfloat/fexp_julia.jl` — new file (~215 LOC)
- `src/softfloat/softfloat.jl` — `include("fexp_julia.jl")`
- `src/Bennett.jl` — export `soft_exp_julia` / `soft_exp2_julia`;
  `register_callee!` both; re-point `Base.exp(::SoftFloat)` and
  `Base.exp2(::SoftFloat)` to the `_julia` variants.
- `test/test_softfexp_julia.jl` — new (~180 LOC)
- `test/runtests.jl` — include new test file
- `test/test_float_circuit.jl` — add soft_exp_julia / soft_exp2_julia
  circuit testsets
- `BENCHMARKS.md` — two new rows
- `WORKLOG.md` — this entry

### Deferred / follow-ups

- Port `log`, `log2` (same shape as exp: range reduction + polynomial
  + table). Likely ~3M gates each. Bennett-582.
- Port `sin`, `cos` (Payne-Hanek range reduction + Estrin polynomials).
  Much more complex. Bennett-3mo.
- Verify bit-exactness on non-FMA hardware (unlikely target but worth
  documenting). If Julia's `muladd` doesn't fuse, we'd need a
  non-FMA-matching variant.
- `soft_exp_julia` registered as callee: `Base.exp(SoftFloat(x))` in a
  compiled circuit routes through. End-to-end `reversible_compile` on
  user code like `f(x::Float64) = exp(x^2)` should Just Work — verified
  in test_float_circuit.jl.

---

