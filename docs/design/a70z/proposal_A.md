# Bennett-a70z — Proposal A: exact interval-compare overflow bit for one-constant operands

Design proposer A. Design document only; no source edits made. Ground truth:
scout_report.md + ir_excerpts.txt (same dir), `src/extract/instructions.jl`
2494-2532 / 2829-2851 / 3117-3136, `src/extract/module_walk.jl` 418-446 &
601-609, `test/test_lbot_overflow_intrinsic.jl`, `bd show Bennett-lbot`.

---

## 1. Chosen mechanism + precise soundness argument

### Mechanism (one sentence)

Extend `_fuse_overflow_extractvalue` so that when exactly one operand of
`llvm.{smul,umul,sadd,uadd}.with.overflow.iN` is an `LLVM.ConstantInt` `c`,
the overflow bit (extractvalue idx 1) is **computed exactly** as the
membership test `x ∉ [lo, hi]`, where `[lo, hi]` is the *exact* no-overflow
interval for that `(op, signedness, c, N)` — folded to constants at
extraction time and emitted as 1–2 `IRICmp` (+ 1 width-1 `IRBinOp(:or)` when
two-sided). No placeholder, no range assumption, no CFG pattern-matching.

This is scout candidate #1 (interval form, not the `ashr(product,k) != x`
variant — see §5 "why not the ashr form").

### Why this is exact and sound — the proof, per arm

LangRef defines the overflow bit as: 1 iff the infinite-precision
(signed for `s*`, unsigned for `u*`) result of `x ∘ c` is not representable
in `iN`. Fix `c` (constant) and let `tmin = -2^(N-1)`, `tmax = 2^(N-1)-1`,
`tmax_u = 2^N - 1`. For every arm below, the bit is a monotone-interval
condition in the *single* dynamic operand `x`, so it is exactly
`x < lo ∨ x > hi` for constants `lo, hi` computable at extraction time:

**smul (signed), c constant** — multiplication by a fixed nonzero c is
strictly monotone (increasing for c>0, decreasing for c<0), so
`{x : tmin ≤ x·c ≤ tmax}` is a contiguous interval:

| case      | no-overflow interval `[lo, hi]`         | emitted            |
|-----------|------------------------------------------|--------------------|
| c = 0, 1  | all of iN (bit ≡ 0)                      | lbot fast path, **unchanged** (`0+0` IRBinOp) |
| c = -1    | `[tmin+1, tmax]` — only `x = tmin` overflows (`-tmin = 2^(N-1)` unrepresentable) | 1 icmp: `eq x, tmin` |
| c ≥ 2     | `lo = cld(tmin, c)`, `hi = fld(tmax, c)`. Proof: c>0 ⇒ x·c ≤ tmax ⟺ x ≤ ⌊tmax/c⌋; x·c ≥ tmin ⟺ x ≥ ⌈tmin/c⌉ (monotone-increasing ×c). | 2 icmp (`sgt x,hi`; `slt x,lo`) + `or` |
| c ≤ -2    | `lo = cld(tmax, c)`, `hi = fld(tmin, c)`. Proof: c<0 ⇒ ×c is antitone: x·c ≤ tmax ⟺ x ≥ ⌈tmax/c⌉; x·c ≥ tmin ⟺ x ≤ ⌊tmin/c⌋. | 2 icmp + `or` |

Host-arithmetic exactness: `fld`/`cld` are invoked only for `|c| ≥ 2`
(c ∈ {-1,0,1} are special-cased), so no host `Int64` overflow is possible
(`fld(typemin(Int64), -1)` — the only overflowing division — is unreachable).
`c = tmin` itself is fine: e.g. N=64, `cld(tmax, tmin) = 0`,
`fld(tmin, tmin) = 1` ⇒ interval `[0,1]`, which is exactly the set of x with
`x·tmin` representable. The elsize-8 wall lands in the `c ≥ 2` row:
`lo = cld(tmin,8) = -2^(N-3)`, `hi = fld(tmax,8) = fld(2^(N-1)-1, 8)`
(N=64: `hi = 1152921504606846975`, `lo = -1152921504606846976`).

**umul (unsigned), c constant** — decode `cu = (c mod 2^N)` (see §2 decode
note). `cu ∈ {0,1}` ⇒ bit ≡ 0 (fast path unchanged). `cu ≥ 2`:
`x·cu ≤ tmax_u ⟺ x ≤ ⌊tmax_u/cu⌋` (monotone, x ≥ 0) ⇒ one-sided,
`bit = (x >u hi_u)`, `hi_u = div(tmax_u, cu)` in `UInt64`. Since `cu ≥ 2`,
`hi_u < 2^63` always fits a nonnegative `Int` `ConstOperand`. 1 icmp `ugt`.

**sadd (signed), c constant** — `c = 0` ⇒ bit ≡ 0 (unchanged). `c > 0`:
overflow ⟺ `x > tmax - c` (only the high side can overflow; `tmax - c` exact
in host Int64 since c > 0). `c < 0`: overflow ⟺ `x < tmin - c` (exact since
c < 0). Always exactly 1 icmp (`sgt` / `slt`) — one side is vacuous and is
**omitted** (sound: the omitted compare is identically false over iN).

**uadd (unsigned), c constant** — `cu = 0` ⇒ bit ≡ 0. `cu ≥ 1`: overflow ⟺
`x >u tmax_u - cu`. Bound stored bit-pattern-faithfully as
`reinterpret(Int64, ...)` masked to N bits (may be "negative" as Int for
N=64 — consistent with the project-wide sext `ConstOperand` convention;
the `ugt` compare at width N reads it back as the intended unsigned value).
1 icmp `ugt`.

**Both operands constant** — take `x := a`, `c := b` (or vice versa); the
same machinery emits icmps whose operands are both constants. Exact; no
special arm needed (downstream constant handling is untouched).

**Runtime-overflow routing (the halt-sink half of soundness).** When the
exact bit evaluates to 1 at runtime, nothing new is needed: the bit feeds
the existing or-chain → `xor` → `br` in the *kept* block (scout §4 — utzc is
a keep-branch pruner, `module_walk.jl:429-446`), whose fail arm is the
pruned throw block re-terminated as `IRBranch(nothing, :__unreachable__,
nothing)` — BennettVM's loud halt sink. So an overflowing input takes
exactly the trap the native code takes. That is the *entire* reason
placeholder-0 was unsound and this is not: the emitted bit agrees with the
intrinsic for **all** 2^N inputs, both arms of the branch included.

**smul commutativity note.** mul and add are commutative, so it is sound to
treat whichever operand is `ConstantInt` as `c` and the other as `x`. In the
rehash! shape the constant is always operand 2, but the code must not rely
on that (Rule 5) — check `b` first, then `a`.

---

## 2. Exact emission plan

### Where

All changes in `src/extract/instructions.jl`, inside
`_fuse_overflow_extractvalue` (currently lines 2508-2532), plus a one-line
call-site change at line 2849 to thread `counter`. **Spot 1 (the CALL skip,
lines 3131-3136) is untouched** — the call still emits nothing; both fields
are still re-derived statelessly per-extractvalue from the call's own
operands (scout risk #4: stateless per-site, works for all 6 rehash! sites).
The `ptr_cells` gate is already upstream of the fuse (dispatch at 2842),
so the circuit path stays byte-identical with **zero** new gating code.

### Signature change

```julia
_fuse_overflow_extractvalue(call, cn, idx, dest, inst, names)
→ _fuse_overflow_extractvalue(call, cn, idx, dest, inst, names, counter::Ref{Int})
```

Call site 2849 passes the `counter` already in `_convert_instruction` scope.
Fresh SSA dests come from `_auto_name(counter)` (callees.jl:96) — the
threaded-counter convention the klgz determinism guard requires (no
objectid, deterministic walk order).

### New idx==1 body (sketch, ~55 lines replacing lines 2521-2531)

```julia
# idx == 1: overflow bit — computed EXACTLY (Bennett-a70z extends Bennett-lbot).
signed = startswith(cn, "llvm.s")
# mul/add are commutative: whichever operand is ConstantInt is `c`.
if b isa LLVM.ConstantInt
    xv, cval = a, _const_int_as_int(b)          # sext decode (verified: LLVM.jl
elseif a isa LLVM.ConstantInt                    # convert(Int,·) = GetSExtValue)
    xv, cval = b, _const_int_as_int(a)
else
    _ir_error(inst,
        "overflow bit of $cn with two dynamic operands ($(string(a)), $(string(b))) — " *
        "exact bit for the general case (mul high-half / add carry) is future work; " *
        "a placeholder-0 would route away from the throw the native code takes and " *
        "is UNSOUND. (Bennett-lbot / Bennett-a70z)")
end
N = _iwidth(a)                                   # 1 ≤ N ≤ 64 (>64 already errors in decode)
tmin = N == 64 ? typemin(Int64) : -(Int64(1) << (N-1))
tmax = N == 64 ? typemax(Int64) : (Int64(1) << (N-1)) - 1
mask = N == 64 ? typemax(UInt64) : (UInt64(1) << N) - 1
cu   = reinterpret(UInt64, cval) & mask          # unsigned view for u* arms

# ---- lbot fast path, byte-identical (pins GATE (a)/(a-variants)): ----
provably_zero = op === :mul ? (signed ? cval in (0, 1) : cu in (0, 1)) :
                              (signed ? cval == 0     : cu == 0)
provably_zero && return IRBinOp(dest, :add, iconst(0), iconst(0), _iwidth(inst))

xop = _operand(xv, names)
if op === :mul && signed
    cval == -1 && return IRICmp(dest, :eq, xop, iconst(tmin), N)   # only x=tmin overflows
    lo = cval > 0 ? cld(tmin, cval) : cld(tmax, cval)
    hi = cval > 0 ? fld(tmax, cval) : fld(tmin, cval)
    t1, t2 = _auto_name(counter), _auto_name(counter)
    return IRInst[IRICmp(t1, :sgt, xop, iconst(hi), N),
                  IRICmp(t2, :slt, xop, iconst(lo), N),
                  IRBinOp(dest, :or, SSAOperand(t1), SSAOperand(t2), 1)]
elseif op === :mul                                                  # umul, cu ≥ 2
    return IRICmp(dest, :ugt, xop, iconst(Int(div(mask, cu))), N)   # ⌊tmax_u/cu⌋ < 2^63
elseif signed                                                       # sadd, cval ≠ 0
    return cval > 0 ? IRICmp(dest, :sgt, xop, iconst(tmax - cval), N) :
                      IRICmp(dest, :slt, xop, iconst(tmin - cval), N)
else                                                                # uadd, cu ≥ 1
    return IRICmp(dest, :ugt, xop, iconst(reinterpret(Int64, (mask - cu))), N)
end
```

Notes:
- The `provably_zero` fast path keeps the **exact** current
  `IRBinOp(dest,:add,0,0,1)` shape, so GATE (a)/(a-variants) pins in
  `test_lbot_overflow_intrinsic.jl` stay byte-stable. (One subtle honesty
  fix folded in: today's predicate `ca in (0,1)` for **umul** compares a
  sext'd value; for umul the check should be on `cu` — behaviorally
  identical for 0/1 but now correct by construction for the general decode.)
- `idx == 0` arm (product) and the `idx ∉ {0,1}` reject: **unchanged**.
- Multi-inst return uses the existing Vector splice convention
  (`module_walk.jl:601-604` pushes each element into the block's inst list,
  in order, before the terminator — dominance is preserved because the
  extractvalue site itself dominates all its uses).
- Result-vs-operand widths: `IRICmp` results are i1 by construction
  (`ir_types.jl:79` — width field is the *operand* width N); the `:or`
  combiner is `IRBinOp` width 1 — the same shape as the `or i1` chain
  instructions (`%138`, `%140`) that already extract and run today on the
  i8 dict path, so no new width-1 handling is introduced downstream.
- The rehash! or-chain (`icmp slt %value_phi 0`, `or`, `icmp slt tmax-1
  %product`, `or`, `xor`, `br`) extracts through the ordinary handlers —
  we do NOT touch or double-handle it (scout risk #3).

### Comment-block update

Rewrite the lbot header comment (2494-2507) to state the new contract: bit
is *computed exactly* for one-constant operands via the no-overflow
interval; `{0,1}`/`{0}` remain the fold-to-zero fast set; two dynamic
operands remain the wall. Keep the `-1`-is-not-in-the-zero-set warning
(it is now *handled*, via the `eq tmin` arm — say so explicitly).

---

## 3. What remains fail-loud (explicit list)

1. **Two dynamic operands** (`smul(%x,%y)` etc.) — new, more precise
   message; still `_ir_error`. `LBOT_TWO_VAR` stays red (updated pin text).
2. **`llvm.{s,u}sub.with.overflow.*`** — never enters the fuse (not in the
   Spot-1/Spot-2 name gates); falls to the pre-existing D5
   `{iN,i1}`-return-type reject. Deliberately out: sub is non-commutative
   (constant side matters: `c - x` vs `x - c` need different intervals),
   Julia's memorynew shape never emits it, and admitting it untested would
   violate Rule 9/10. Filed as future work in the bead close.
3. **extractvalue idx ∉ {0,1}** — unchanged reject.
4. **`ptr_cells=false`** — entire fuse unreachable; circuit path
   byte-identical (GATE (c) untouched).
5. **N > 64** — `_const_int_as_int` l9cl error, unchanged.
6. **Any non-extractvalue consumer of the intrinsic call** — the call binds
   no dest, so `_operand` fails loud, unchanged (Spot-1 contract).
7. **Vector overflow intrinsics** (`<k x iN>` variants) — routed to the
   cc0.7 vector path before this dispatch, where they fail loud as today.

---

## 4. Test plan (red-green)

### New file: `test/test_a70z_overflow_bit_exact.jl` (+1 line runtests.jl)

Written FIRST; all extraction gates red against current main ("not provably
zero" error), then green after the fuse change. Oracle throughout:
`Base.Checked.mul_with_overflow` / `add_with_overflow` on native iN
(CLAUDE.md rule 3 exhaustiveness at i8). The test includes a ~15-line
evaluator `_a70z_eval_bit(insts, dest, x)` that interprets the emitted
IRICmp/IRBinOp(:or) sequence on a concrete `x` — semantic check, not just
structural.

Testsets:

1. **"smul const — i8 exhaustive vs oracle"**: `.ll` fixtures
   `smul.with.overflow.i8(%x, c)` for
   `c ∈ (2, 3, 8, -2, -8, 127, -127, -128)`; extract with `ptr_cells=true`;
   for ALL 256 `x::Int8`: `_a70z_eval_bit == mul_with_overflow(x, Int8(c))[2]`.
   (Covers antitone c<0 rows, c=tmin, both boundary roundings.)
2. **"smul(x,-1) typemin edge"**: c=-1 at i8 (exhaustive; bit=1 exactly at
   x=-128) and i64 (structural: single `IRICmp :eq` vs `typemin(Int64)`).
3. **"smul(x,8) i64 — bound constants pinned"**: exactly 2 IRICmp
   (`:sgt` vs `1152921504606846975`, `:slt` vs `-1152921504606846976`) +
   1 `IRBinOp(:or, width=1)` dest `:o`; no IRCall/IRExtractValue survive;
   boundary semantics at `x ∈ {hi, hi+1, lo, lo-1, 0, ±1, typemin, typemax}`
   vs oracle.
4. **"sadd/uadd/umul const arms"**: `sadd(x,5)`, `sadd(x,-5)`, `uadd(x,3)`,
   `uadd(x, 2^63+9)` (bit-pattern bound pin), `umul(x,8)`; i8 exhaustive +
   i64 boundaries vs oracle (`unsigned` oracles via `UInt` checked ops).
   Asserts the one-sided cases emit exactly ONE IRICmp with dest `:o`
   (no vacuous compare, no or).
5. **"zero-set fast path byte-stable"**: `smul(x,1)`, `umul(x,0)`,
   `sadd(x,0)`, `uadd(x,0)` still produce the exact
   `IRBinOp(:o,:add,0,0,1)` shape (protects GATE (a) pins).
6. **"two-variable stays loud"**: `LBOT_TWO_VAR`-shaped fixture → `:err`,
   message pins `"two dynamic operands"` + `"Bennett-a70z"`.
7. **"ptr_cells=false byte-identity"**: `smul(x,8)` fixture with
   `cells=false` → `:err` with the pre-existing wall disjunction (GATE (c)
   mirror — proves the new arms are unreachable off-gate).
8. **"fdict64 end-to-end — THE TARGET"**:
   `fdict64(a::Int64,b::Int64) = (d = Dict{Int64,Int64}(); d[a]=b; d[a])`;
   `extract_parsed_ir_set_from_julia(fdict64, Tuple{Int64,Int64};
   ptr_cells=true, on_extract_error=:skip)` inside the GATE-(d)
   `_known_callees` snapshot/restore pattern. NEGATIVE pins: message (if
   any) contains none of `"with.overflow"`, `"not provably zero"`,
   `"smul"`. POSITIVE: inclusive disjunction of plausible successors
   (`gc_alloc_obj` / `genericmemory` / `memset` / `closed-world` / `""`),
   `@info` the first line of the next wall — this **is** the "document the
   next wall" deliverable, machine-checked.
9. **"non-regression: fdict_d1b i8 set"**: rerun the i8 probe; assert its
   status is unchanged vs GATE (d) (elsize-1 sites take the untouched fast
   path — output byte-identical).

### Honest updates to `test/test_lbot_overflow_intrinsic.jl`

- **GATE (a), (a-variants), (c), (d): NO changes** (fast path byte-stable,
  off-gate byte-identical, i8 wall text unchanged).
- **GATE (b1) `LBOT_TWO_VAR`**: stays `:err`; update pinned substrings
  `"not provably zero"` → `"two dynamic operands"` (keep `"Bennett-"` pin,
  add `"Bennett-a70z"`), with a dated comment citing this bead.
- **GATE (b2) `LBOT_ADD5`**: flips GREEN — rewrite to assert the exact-bit
  shape (product `IRBinOp(:p,:add,x,5)` + bit `IRICmp(:o,:sgt,x,
  typemax(Int64)-5)`), comment pointing at test_a70z for the full matrix.
- Verify (run, don't assume — Rule 10) that utzc/yd4f/qmv7 tripwires need
  nothing: they were re-pinned post-lbot to non-smul walls and only i8
  shapes are involved.

Run order: new file red → implement → new file green → lbot updates → both
files under `--check-bounds=yes` → full `Pkg.test()` (suite-mode claim only,
per CLAUDE.md Build & Test note / Bennett-2mj3).

---

## 5. Risk analysis

- **LLVM drift (Rule 5)**: keyed ONLY on LangRef-stable intrinsic name
  prefixes + `isa LLVM.ConstantInt` on the call's own operands. No block
  names, no or-chain shape matching, no operand-position assumption
  (commutative pick). The 9-inst memorynew shape can reorder freely.
- **Signed decode**: `convert(Int, ::ConstantInt)` verified sext (LLVM.jl,
  checked live: i8 `-2` → `-2`). Unsigned arms re-derive `cu` by masking —
  immune to the sext. Test 4's `uadd(x, 2^63+9)` pins the bit-pattern
  `ConstOperand` convention for N=64 bounds.
- **Signed edge cases**: c=-1/typemin-of-x (dedicated arm + testset 2);
  c=tmin (interval [0,1], covered by i8 c=-128 exhaustive); rounding of
  fld/cld on negative c (i8 exhaustive across ±2, ±8, ±127, -128 catches
  any off-by-one on BOTH bounds); host overflow impossible (|c|≥2 in the
  divisions; tmax-c / tmin-c sign-safe by arm).
- **Why not `ashr(product,k) != x` for power-of-two c**: it needs the
  product SSA value, but the bit's extractvalue must fuse statelessly from
  the call operands — LLVM does not guarantee extractvalue-0 exists or
  precedes extractvalue-1. Re-deriving the product inside the bit sequence
  costs an extra mul. The interval form uses only `x` + constants: fewer
  assumptions, one uniform proof. (Also generalizes to non-power-of-two c
  for free.)
- **Downstream BVM**: emitted opcodes are `IRICmp(:sgt|:slt|:ugt|:eq)` at
  width N and `IRBinOp(:or)` at width 1 — all already ingested (the i8
  dict's own or-chain exercises width-1 `or` and iN icmps today), plus the
  unchanged product `IRBinOp(:mul|:add)`. No `{iN,i1}` ever reaches BVM;
  the product still feeds `IntrinsicGenericMemoryAlloc` whose byte-granular
  elsize-agnostic model needs nothing (scout §5). **No BVM change.**
- **Determinism (klgz)**: fresh names via the threaded `counter` — walk-
  order deterministic; rehash! gains ≤ 2 fresh `__vN` per smul site (12 for
  i64), shifting subsequent auto-names. klgz pins classifier behavior, not
  absolute `__vN` indices — verify by running it; any test found pinning
  absolute names in ptr_cells extractions gets an honest documented update.
- **Gate counts / circuit regressions (Rule 6)**: unreachable at
  `ptr_cells=false`; no explicit-strategy baseline can move. Testset 7
  proves it.
- **Hidden next wall**: extraction may now surface a later rehash! wall
  (variable-size `llvm.memset.p0.i64` / Bennett-8bys territory, or the i64
  gc_alloc_obj path) and the known RUNTIME Dict-growth VM gap
  (worklog/094) is untouched — testset 8 records the wall; implementer
  files/updates the follow-on bead + worklog entry per §0.

## 6. Estimated diff size

- `src/extract/instructions.jl`: ~55 new lines in the idx==1 arm, ~10 lines
  comment rewrite, 1-line call-site (counter) — **~70 lines core**.
- `test/test_a70z_overflow_bit_exact.jl`: ~260 lines (incl. mini-evaluator).
- `test/test_lbot_overflow_intrinsic.jl`: ~30 lines churn (b1 text, b2
  rewrite).
- `test/runtests.jl`: 1 line. Worklog + bead close: docs.
