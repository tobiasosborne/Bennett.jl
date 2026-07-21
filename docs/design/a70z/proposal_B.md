# Proposal B — Bennett-a70z: exact constant-operand overflow bit via admissible-range compare

Proposer B. Design document only. Based on: scout_report.md + ir_excerpts.txt (ground
truth), src/extract/instructions.jl:2494-2532 / 2829-2851 / 3117-3136,
src/extract/module_walk.jl:418-446 (utzc keep-branch pruner) and 594-609
(Vector-splice convention), test/test_lbot_overflow_intrinsic.jl, `bd show Bennett-lbot`.

---

## 1. Chosen mechanism + precise soundness argument

### Mechanism in one sentence

For `extractvalue {iN,i1} %c, 1` where `%c = llvm.{s,u}{mul,add}.with.overflow.iN(x, c)`
and **exactly one operand `c` is an `LLVM.ConstantInt`**, compute — at extraction time,
in `Int128` — the *admissible input interval* `[L, U]` of the dynamic operand `x`
(the exact set of `x` for which the operation does NOT overflow), and emit the exact
runtime bit as at most `(x < L) OR (x > U)`: up to 2 `IRICmp` + 1 `IRBinOp(:or, w=1)`,
with constant-false arms folded away at extraction time. Both-operands-constant folds to
a literal exact bit; both-operands-dynamic stays fail-loud.

This is scout candidate 1 (bounds-compare), generalized to a single uniform
interval formulation covering all four intrinsic arms and every constant
(positive, negative, `-1`, `typemin`, powers of two, non-powers of two) with one code path.
I deliberately do NOT use the `ashr(product,k) != x` power-of-two shortcut: it needs the
sibling extractvalue-0 SSA value (breaks the stateless per-extractvalue fuse — scout
risk #4, six sites per rehash!) or a redundant re-emitted `mul`, and it only covers
`c = 2^k`. The interval form is stateless, constant-shape, and total over constants.

### The interval, per arm (all arithmetic in `Int128`, `N = _iwidth(a)`)

Let `smin = -Int128(2)^(N-1)`, `smax = Int128(2)^(N-1) - 1`, `umax = Int128(2)^N - 1`.
Decode the constant with the existing `_const_int_as_int` (which sign-extends —
correct signed value for any width ≤ 64, per src/extract/helpers.jl:123-132), then:

* signed ops use `sc = Int128(ca)` directly;
* unsigned ops reinterpret at width N: `uc = Int128(ca) & ((Int128(1) << N) - 1)` (≥ 0).

| intrinsic | admissible interval for dynamic `x` (domain = signed resp. unsigned iN) |
|---|---|
| `smul(x, sc)`, `sc > 0`  | `L = cld(smin, sc)`, `U = fld(smax, sc)` |
| `smul(x, sc)`, `sc < 0`  | `L = cld(smax, sc)`, `U = fld(smin, sc)` |
| `smul(x, 0 or 1)`        | full domain → bit ≡ 0 (existing early path, kept byte-identical) |
| `umul(x, uc)`, `uc ≥ 2`  | `L = 0`, `U = fld(umax, uc)` |
| `umul(x, 0 or 1)`        | full domain → bit ≡ 0 (existing) |
| `sadd(x, sc)`            | `L = smin - sc`, `U = smax - sc` (one end always out of domain → single arm) |
| `sadd(x, 0)`             | full domain → bit ≡ 0 (existing) |
| `uadd(x, uc)`            | `L = 0`, `U = umax - uc` |
| `uadd(x, 0)`             | full domain → bit ≡ 0 (existing) |

Then clamp against the domain: an arm whose bound lies at/outside the domain edge is a
**constant-false comparison and is not emitted** (`L ≤ domain_min` drops the low arm;
`U ≥ domain_max` drops the high arm). All surviving bounds provably fit in `Int64`
(they lie strictly inside the iN domain, N ≤ 64; for unsigned-i64 bounds, `uc ≥ 2`
forces `U ≤ 2^63 - 1`, so `ConstOperand::Int` never truncates — see §5 risk 3).

### Soundness argument (pointwise-exact, no input assumption)

Claim: for every runtime value of `x`, the emitted bit equals the intrinsic's overflow
bit, i.e. `bit(x) = (Base.Checked.op_with_overflow(x, c))[2]` at width N.

Proof sketch, `smul` arm (the wall case; others are strictly easier):

* Overflow of `smul.with.overflow` is defined (LangRef) as: the infinite-precision
  signed product `x·c` is not representable in iN, i.e. `x·c ∉ [smin, smax]`.
* For fixed `c > 0`, `x ↦ x·c` is strictly increasing over ℤ. Hence
  `x·c ≤ smax ⟺ x ≤ fld(smax, c)` (definition of floor division: `fld(smax,c)` is the
  greatest integer `q` with `q·c ≤ smax`) and
  `x·c ≥ smin ⟺ x ≥ cld(smin, c)` (`cld` = least integer `q` with `q·c ≥ smin`).
  So no-overflow ⟺ `cld(smin,c) ≤ x ≤ fld(smax,c)` — exactly the emitted interval.
* For fixed `c < 0`, `x ↦ x·c` is strictly decreasing; dividing the two range
  inequalities by negative `c` flips them:
  `x·c ≤ smax ⟺ x ≥ cld(smax, c)` and `x·c ≥ smin ⟺ x ≤ fld(smin, c)` —
  again exactly the table row. All divisions are computed in `Int128`, where
  `cld/fld` are total for every `|c| ≤ 2^63` and every bound `|b| ≤ 2^63`
  (no `fld(typemin,-1)`-style trap: the operands are Int128, whose domain is far larger).
* The `iN` domain is finite, so representability of the interval endpoints is a clamp,
  not an approximation: dropping an arm whose bound is outside the domain removes only
  comparisons that are false for every representable `x`.
* Named edge cases, checked against the formula:
  - `c = 8, N = 64` (**the wall**): `L = cld(-2^63, 8) = -2^60`, `U = fld(2^63-1, 8) = 2^60-1`.
    Overflow ⟺ `x < -2^60 || x > 2^60-1`. Exact; both arms live.
  - `c = -1`: `L = cld(smax, -1) = smin+1`, `U = fld(smin, -1) = 2^(N-1) > smax` →
    high arm folds; bit = `x < smin+1` ⟺ `x == typemin`. This is precisely the lbot
    `smul(INT_MIN, -1)` overflow — the mechanism *computes* it instead of walling.
  - `c = smin` (= `-2^(N-1)`): `L = cld(smax, smin) = 0`, `U = fld(smin, smin) = 1` →
    bit = `x < 0 || x > 1`; indeed only `x ∈ {0,1}` avoid overflow.
  - `x = typemin` dynamic: no special case — the compare covers every domain point.
* Both-operands-constant: compute `x·c` (resp. sum) in `Int128`, test membership in
  the domain, emit the literal bit. Exact by construction.
* **Runtime-overflow routing**: when the emitted bit evaluates to 1, the already-
  extracted or-chain (`or → or → xor → br`) takes the fail arm, which the utzc
  keep-branch pruner (module_walk.jl:429-446) has replaced with the
  `:__unreachable__` halt-sink branch — BennettVM traps loud, the faithful
  reversible analogue of the `jl_argument_error` throw the native code takes
  (scout §4). No placeholder, no mis-routing, no input-range assumption. This is
  scout candidate 1 + the honest variant of candidate 5.

`sadd`/`uadd` inclusion is justified (constraint: "consider both arms"): the identical
interval machinery gives them for free as *narrower* cases (an add by constant shifts
the domain, so exactly one arm can ever be live → a single `IRICmp`, no `:or`), the
code path is shared (zero extra branches beyond the table), and it honestly flips the
`LBOT_ADD5` GATE (b2) pin — which the scout explicitly flags as the expected tripwire
for an exact-bit design. Excluding them would mean carrying a dead special case.

`ssub/usub.with.overflow` are **not** extended: they are not in the fuse's prefix list
today, they do not occur in the fdict corpus, and their extractvalue would fall to the
6bu3 i1-field reject (fail loud) — filed as future work, not silently admitted.

---

## 2. Exact emission plan

### Where

All changes in `/home/tobias/Projects/Bennett.jl/src/extract/instructions.jl`; both
spots stay ptr_cells-gated exactly as today. **Spot 1 (CALL skip, lines 3131-3136) is
untouched** — the call still emits nothing, its ref still consumed only by the two
extractvalues.

1. **Call-site line 2849**: pass the already-in-scope `counter`:
   `return _fuse_overflow_extractvalue(agg_val, cn, idx, dest, inst, names, counter)`.
2. **`_fuse_overflow_extractvalue` (lines 2508-2532)**: signature gains
   `counter::Ref{Int}`. `idx == 0` arm byte-identical. `idx == 1` arm becomes:

```julia
    # idx == 1: overflow bit.
    ca = a isa LLVM.ConstantInt ? _const_int_as_int(a) : nothing
    cb = b isa LLVM.ConstantInt ? _const_int_as_int(b) : nothing
    signed = startswith(cn, "llvm.s")               # smul / sadd
    if ca !== nothing && cb !== nothing
        # both constant: literal exact bit (Int128 evaluation).
        bit = _ovf_const_bit(op, ca, cb, N, signed)             # 0 or 1
        return IRBinOp(dest, :add, iconst(bit), iconst(0), _iwidth(inst))
    end
    if ca === nothing && cb === nothing
        _ir_error(inst,
            "overflow bit of $cn with BOTH operands dynamic (operands " *
            "$(string(a)), $(string(b))) is unsupported; the exact bit is " *
            "computed only when one operand is a compile-time constant " *
            "(Bennett-a70z) — general two-variable mul-high/add-carry is " *
            "future work. (Bennett-lbot)")
    end
    # one constant, one dynamic (all four intrinsics are commutative):
    c  = something(ca, cb)
    x  = ca === nothing ? a : b
    L, U, always0 = _ovf_admissible_range(op, c, N, signed)     # Int128 math, clamped
    always0 && return IRBinOp(dest, :add, iconst(0), iconst(0), _iwidth(inst))
    xop  = _operand(x, names)
    lt   = signed ? :slt : :ult
    gt   = signed ? :sgt : :ugt
    lo_live = L !== nothing            # nothing ⇔ arm folded constant-false
    hi_live = U !== nothing
    if lo_live && hi_live
        t1 = _auto_name(counter); t2 = _auto_name(counter)
        return IRInst[
            IRICmp(t1, lt, xop, iconst(Int(L)), N),
            IRICmp(t2, gt, xop, iconst(Int(U)), N),
            IRBinOp(dest, :or, SSAOperand(t1), SSAOperand(t2), _iwidth(inst)),
        ]
    elseif lo_live
        return IRICmp(dest, lt, xop, iconst(Int(L)), N)
    else
        return IRICmp(dest, gt, xop, iconst(Int(U)), N)
    end
```

3. **New helper `_ovf_admissible_range(op, c, N, signed)`** placed immediately above
   `_fuse_overflow_extractvalue` (~line 2508), returning
   `(L::Union{Int128,Nothing}, U::Union{Int128,Nothing}, always0::Bool)` per the §1
   table: constant reinterpretation (mask for unsigned), `cld`/`fld` in `Int128`,
   then clamp-fold (`L ≤ domain_min ⇒ L = nothing`, `U ≥ domain_max ⇒ U = nothing`,
   both folded ⇒ `always0 = true`). The `op === :mul && c in (0, 1)` (unsigned: `uc in
   (0,1)`) and `op === :add && c == 0` cases come out as `always0` **through the same
   formulas** — but to keep GATE (a)/(a-variants) pins and klgz determinism
   byte-identical (same `IRBinOp(dest,:add,iconst(0),iconst(0),1)`, zero counter
   consumption), the `always0` early-return reproduces today's exact instruction.
4. **New helper `_ovf_const_bit(op, ca, cb, N, signed)`** — both-constant literal
   evaluation in `Int128` (reinterpret unsigned operands at width N first).

Multi-instruction return: the 3-inst `Vector{IRInst}` is spliced in program order by
the existing convention at module_walk.jl:601-604 (`ir_inst isa Vector` → per-element
push). Fresh dests come from the threaded `counter` Ref (klgz determinism guard —
scout risk #6). The fuse stays **stateless per-extractvalue** (scout risk #4: six
sites per rehash!, four of them elsize-8, each independently re-derived).

Emitted opcode inventory (for §5 BVM check): `IRICmp` preds `:slt/:sgt/:ult/:ugt`
at operand width N; `IRBinOp(:or)` width 1; `IRBinOp(:add)` const/const width 1.
Nothing else.

### Doc updates in the same diff

The lbot block comment above `_fuse_overflow_extractvalue` (lines 2494-2507) gains an
a70z paragraph stating the interval mechanism and the c=-1/typemin edge treatment
(replacing "future work" for the constant case; two-variable stays filed as such).

---

## 3. What remains fail-loud (explicit list)

1. **Both operands dynamic** (`smul(%x,%y)` etc.) — updated message (§2), still an
   `_ir_error`; `LBOT_TWO_VAR` pin retained with honest message update.
2. **`llvm.{s,u}sub.with.overflow.*`** — not in either spot's prefix list; walls at
   the D5 `{iN,i1}` return-type reject / 6bu3 i1-field reject as today.
3. **extractvalue idx ∉ {0,1}** on an overflow intrinsic — existing lbot reject.
4. **Any non-extractvalue consumer of the intrinsic call** — no dest binding →
   `_operand` unknown-ref loud failure (unchanged Spot-1 contract).
5. **Constants wider than 64 bits** — `_const_int_as_int` l9cl fail-loud (unchanged).
6. **`ptr_cells=false`** — both spots gated; the circuit path walls byte-identically
   (GATE (c) untouched).
7. **Whatever the next wall inside `rehash!` at i64 is** (scout §6 Q1: hidden behind
   this one; plausibly the grow/copy path or a further CW-D2 frontier) — the e2e test
   logs it via `@info`, and the implementer must document it in the worklog and file
   the follow-on bead (that IS the bead's "document the next wall" exit criterion).

---

## 4. Test plan (red-green)

New file: `test/test_a70z_overflow_const_bit.jl`, registered in `test/runtests.jl`
next to `test_lbot_overflow_intrinsic.jl`. Written FIRST; all target testsets red on
current main (c=8 fixture and fdict64 e2e both die on "not provably zero").

Fixture builder: reuse the `_lbot_fixture`-style `.ll` template parameterized on
intrinsic + constant + width (add an iN width parameter; i8 for exhaustive sweeps,
i64 for boundary sweeps). A ~25-line pure-Julia evaluator in the test file executes
the 1-3 emitted bit instructions for a concrete `x` (interpret IRICmp/IRBinOp over
Int128 with signed/unsigned reinterpretation at width N).

Testsets:

1. **"exact bit ≡ Base.Checked oracle — i8 exhaustive"**: for
   `c ∈ (2, 3, 7, 8, -1, -2, -8, 127, -128)` × intrinsic ∈ (smul, sadd) and
   `c ∈ (2, 3, 8, 127, 128-pattern, 255-pattern)` × (umul, uadd): extract the i8
   fixture at `ptr_cells=true`, then for **all 256** `x` compare the evaluated bit
   against `Base.Checked.{mul,add}_with_overflow(Int8/UInt8)` (Rule 4: exhaustive at
   narrow width; oracle per brief). Also assert: no `IRCall`/`IRExtractValue`
   survives; product IRBinOp shape unchanged.
2. **"i64 boundary sweep — the wall constant c=8"**: fixture `smul(%x, 8)` i64;
   evaluate at `x ∈ {typemin, typemin+1, -2^60-1, -2^60, -1, 0, 1, 2^60-1, 2^60,
   typemax-1, typemax}` vs oracle; assert both arms present with bounds exactly
   `-2^60` and `2^60-1` (pins the fld/cld arithmetic itself).
3. **"single-arm folds"**: `smul(%x,-1)` i64 → exactly one `IRICmp(:slt, x,
   typemin+1)`, no `:or`; `sadd(%x,5)` → one `IRICmp(:sgt, x, typemax-5)`;
   `uadd(%x,c)` → one `:ugt`; `umul` → one `:ugt` with unsigned-decoded bound
   (include a umul constant with the top bit set — scout risk #5 signedness decode).
4. **"both-constant literal bit"**: `smul(7, 8)` i8 (bit 0) and `smul(64, 8)` i8
   (bit 1): extraction succeeds, bit is the literal constant; the bit-1 case's
   branch shape still routes to the fail arm label.
5. **"two-var stays walled"**: `LBOT_TWO_VAR`-shaped fixture → `:err`, message
   contains "BOTH operands dynamic" + "Bennett-a70z" + "Bennett-lbot".
6. **"GATE — fdict64 e2e advances past the elsize-8 wall"**:
   `extract_parsed_ir_set_from_julia(fdict64, Tuple{Int64,Int64}; ptr_cells=true,
   on_extract_error=:skip)` inside the `_known_callees` snapshot/restore pattern
   (copied from lbot GATE (d), incl. the `after == before` assert). NEGATIVE pins:
   msg (if any) contains neither "with.overflow" nor "not provably zero" nor
   "BOTH operands dynamic". POSITIVE: inclusive disjunction (`msg == ""` for full
   closure, or plausible CW-D2 successors — "closed-world violation" /
   "genericmemory" / "memoryref" case-insensitive), plus `@info` of the first line
   of the new wall (this discharges "document the next wall").
7. **"non-regression — fdict_d1b Int8 set"**: rerun the lbot GATE (d) body verbatim
   (elsize-1 sites must still fuse via the unchanged `always0` path).
8. **"ptr_cells=false byte-identity"**: the c=8 fixture at `cells=false` still errs
   with the pre-lbot wall disjunction (mirror of lbot GATE (c)).
9. **"determinism"**: extract the c=8 i64 fixture twice; assert the emitted inst
   sequences (incl. `__vN` dests) are `==` (klgz-style, cheap local guard).

Honest updates to `test/test_lbot_overflow_intrinsic.jl` (the tripwire the scout
predicts): **GATE (b2) `LBOT_ADD5` flips green** — rewrite as a green assert (product
`IRBinOp(:add, x, 5)` + bit `IRICmp(:sgt, x, typemax(Int64)-5)`), with a comment
citing Bennett-a70z (lbot/u2kk honest-update pattern). **GATE (b1) `LBOT_TWO_VAR`
stays red** — update the message pins to "BOTH operands dynamic" + "Bennett-lbot"
(tag retained in the new message precisely so historical pins stay meaningful).
GATE (a)/(a-variants)/(c)/(d) untouched — the `always0` early path reproduces today's
exact instruction. Also grep-audit `test_utzc_dead_block_pruner.jl` /
`test_yd4f_undef_phi_cells.jl` / `test_qmv7_gc_loaded_memcpy.jl`: their smul mentions
are comments only (verified in scout landscape + grep), no pin changes expected;
implementer re-runs them in suite mode (`--check-bounds=yes`) regardless.

---

## 5. Risk analysis

1. **LLVM drift (Rule 5)**: keyed on the intrinsic name prefix (a LangRef-stable
   contract, same keying lbot shipped) and on operand `ConstantInt`-ness — pure
   structure. No reliance on operand order (both sides checked; ops are commutative),
   block names, the 9-inst Julia size-check shape, or `%value_phi` naming. If Julia
   ever emits the elsize as operand 1 instead of 2, nothing changes.
2. **Signed edge cases**: `c = -1` (typemin overflow), `c = typemin`, `x = typemin`,
   non-power-of-two `c` — all handled by the Int128 interval and *pinned by tests*
   (testsets 2-3 + i8 exhaustive). The extraction-time arithmetic itself cannot trap:
   `cld/fld` run in Int128 where every operand magnitude ≤ 2^64.
3. **Bound truncation into `ConstOperand::Int`**: surviving (non-folded) bounds lie
   strictly inside the iN domain (N ≤ 64). The only >typemax(Int64) candidates —
   unsigned-i64 `U` with `uc ≤ 1`, signed `fld(smin,-1)` — are exactly the folded
   arms (`always0` / clamp). An `@assert typemin(Int64) ≤ b ≤ typemax(Int64)` before
   `Int(b)` fails loud if this invariant is ever wrong (Rule 1). Unsigned-i64 bounds
   with `uc ≥ 2` satisfy `U ≤ (2^64-1)÷2 < 2^63`.
4. **Downstream BVM**: emitted opcodes are only `IRICmp` (slt/sgt/ult/ugt) and
   `IRBinOp` (:or w1, :add w1) — the surrounding or-chain (`or i1`, `xor i1`,
   `icmp slt i64`) already extracts and ingests today on the elsize-1 path (scout
   §4), so no new opcode reaches BVM; the `{iN,i1}` aggregate still never exists;
   `IntrinsicGenericMemoryAlloc` still receives the same product operand (byte-
   granular VM is elsize-agnostic — scout §5). **No BVM change needed.** Residual
   (pre-existing, out of scope): BVM's own GenericMemory grow/copy fail-louds —
   the known run-time Dict-growth issue (worklog/094) is separate bead territory.
5. **Gate counts / regressions**: ptr_cells=false is byte-identical (both spots
   gated), so `test_gate_count_regression.jl` explicit-strategy baselines cannot
   move. The ptr_cells=true VM path has no pinned gate counts.
6. **Hidden next wall** (scout Q1): success criterion is honest wall-advance, not
   full closure — testset 6's inclusive disjunction + `@info` mirrors the lbot
   GATE (d) pattern so the suite stays green whatever the successor is, while the
   worklog records it.
7. **Counter consumption**: only two-arm sites consume names (2 each; 4 elsize-8
   sites in rehash_i64 → 8 names). Deterministic via the threaded Ref; testset 9 +
   the existing klgz guard cover drift.

## 6. Estimated diff size

* `src/extract/instructions.jl`: ~+95 / −10 (two helpers ~45 LOC, rewritten idx==1
  arm ~40 LOC, comment updates, call-site `counter` thread). Core diff only here.
* `test/test_a70z_overflow_const_bit.jl`: ~260 LOC new (incl. ~25-LOC bit evaluator).
* `test/test_lbot_overflow_intrinsic.jl`: ~±35 LOC (b1 message pins, b2 green flip).
* `test/runtests.jl`: +1 line. Worklog session block: ~20 lines.
* Total ≈ 400 LOC, of which ~95 core; zero BVM-side changes.
