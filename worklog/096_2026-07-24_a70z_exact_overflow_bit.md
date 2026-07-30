# worklog chunk 096 — 2026-07-24 — Bennett-a70z exact constant-operand overflow bit

## Session log — 2026-07-30 — Bennett-tl1l: the residual a70z coverage — N∈{16,32} sweeps upstream, ONE-SIDED + BOTH-CONSTANT shapes proven downstream in BennettVM

Cross-repo, TEST-ONLY. Closes the three argued-not-proven residuals a70z left
behind. No `src/` change in either repo; no defect found. Both trees left dirty
for review.

### THE LOAD-BEARING FINDING (research step, Bennett.jl Rule 9)

`_fuse_overflow_extractvalue` has **three** emission shapes, and the real
`Dict{Int64,Int64}` corpus only ever produces **one** of them:

| shape | when | emission |
|---|---|---|
| TWO-SIDED | both bounds strictly interior to the iN domain | 2 `IRICmp` into `__vN` + `IRBinOp(dest,:or,·,·,1)` |
| ONE-SIDED | one bound at/outside the domain edge (arm constant-false, dropped) | a SINGLE `IRICmp` carrying the extractvalue's OWN dest; zero `counter` consumption |
| BOTH-CONST | both intrinsic operands are `ConstantInt` | `IRBinOp(dest,:add,iconst(bit),iconst(0),1)` — byte-identical to the lbot fold shape |

One-sidedness is **not** a corner case — it is the MAJORITY shape.
`_ovf_admissible_range` drops the low arm for **every unsigned op** (`L = 0` is
the unsigned domain floor) and drops exactly one arm for **every `sadd`/`uadd`**
(`smin - c` leaves the domain below when `c > 0`; `smax - c` leaves it above
when `c < 0`). Only signed MUL is generically two-sided — and `rehash!`'s
`smul(%value_phi, 8)` is signed mul, which is precisely why the only shape the
Dict corpus exercises is the two-sided one.

**Both plain-Julia source routes to the other two shapes are CLOSED today**
(probed 2026-07-30; this is the knowledge a future agent will otherwise redo):

1. `Base.Checked.add_with_overflow(x, c)` / `checked_add(x, c)` — the natural
   one-sided source — does NOT extract. It dies on

   > `ir_extract.jl: UndefValue operand: { i64, i8 } undef`

   i.e. the **Bennett-bjdg / U80** undef wall: Julia builds the
   `Tuple{Int64,Bool}` RETURN by `insertvalue` into an `{iN,i8} undef`
   aggregate. Reproduced at i16/i32/i64, `add` and `mul`, signed and unsigned.
   The wall is entirely UPSTREAM of the a70z fuse and has nothing to do with
   the overflow bit — which is exactly why the Dict corpus (where the intrinsic
   result is consumed in-body, never returned as a tuple) sails past it.
2. Both-constant from source (`add_with_overflow(Int64(3), Int64(4))[2] ? … : x`)
   is constant-folded by **Julia's own inference** before LLVM: the extracted
   body has ZERO instructions. Also reproduced with the second operand behind a
   `const` global. So the both-constant arm is unreachable from Julia source at
   all.

Both observations are pinned as RED-on-change tripwires in
`BennettVM.jl/test/test_tl1l_a70z_shapes.jl` testset (0). If either route ever
opens (a `bjdg` fix; a Julia inference change), that testset goes red and the
fixtures should be replaced with from-source programs.

### What was added

**Bennett.jl — `test/test_a70z_overflow_const_bit.jl` only** (206 → 348
assertions; file runtime 44.4 s → 47.1 s, so the additions cost ~2.7 s):

* `(a5)` **N=16**: curated constants (domain edges, ±1/±2, the fold set,
  √-domain values, the `c = -1` one-sided trigger) × **all 65536** i16 inputs,
  in BOTH the mathematical-`Int128` and the `_ovf_bound_const`-ENCODED readings,
  vs `Base.Checked` at Int16/UInt16. Plus an ARM-ARITY pin (0 / 1 / 2 surviving
  comparison arms) that states the emission shape at the helper level.
* `(a6)` **N=32**: same constants; x = every value within ±2 of each surviving
  endpoint + domain edges + 0/1/2, PLUS a `MersenneTwister(20260730)` pool of
  2^17 raw patterns shared across all constants.
* `(a7)` **full extraction path at i16/i32** — `_a70z_fixture` at those widths,
  shape-pinned (one-sided ⇒ exactly one `IRICmp` with dest `:o` and no `:or`)
  and evaluated against `Base.Checked` (exhaustive at i16).
* `_ovf_bound_const` / `_ovf_const_bit` spot-checks at 16 and 32.

**Gotcha that cost real time:** the pre-existing `_a70z_range_bit` /
`_a70z_encoded_bit` helpers recompute `_ovf_admissible_range` per x. That is
fine at 256 inputs but not at 65536×48. The new sweeps hoist the (pure) call
out of the x loop into a closure, and the sweep kernels take those closures as
**type parameters** (`p::P, q::Q`) so the calls are statically dispatched — a
global-scope loop through a `::Function`-typed binding would be dynamic and
tens of seconds. A dropped arm is encoded as `typemin`/`typemax(Int128)`, which
is exactly "constant-false over the whole iN domain". `(a5)` opens by asserting
the hoisted closures agree with the per-x helpers over the full 256×256×4 i8
space, so the speed-up is proven drift-free rather than assumed.

**BennettVM.jl — new `test/test_tl1l_a70z_shapes.jl`** (1149 assertions, ~20 s),
registered in `test/runtests.jl` right after `test_a70z_dict64_roundtrip.jl`.
Fixtures are hand-written `.ll` driven through the REAL front-end
(`Bennett.extract_parsed_ir_from_ll` → `_fuse_overflow_extractvalue`) and then
`lower_vm` → `run!` → `unrun!` — strictly stronger than the hand-built
`ParsedIR` the bead offered as the cheap fallback, because the shape under test
is whatever `instructions.jl` emits today rather than a transcription of it.
Four one-sided fixtures spanning W = 64/32/16 and all three one-sided causes
(`sadd` c>0 → `sgt`; `smul` c=-1 → `slt`, the `x == typemin` bit; `sadd` c<0 at
i32 → `slt`; `uadd` i16 → `ugt` with a SEXT-ENCODED bound of `-2` for
`0xFFFE`), nine both-constant fixtures at W = 64/32/16. Each pins the shape at
BOTH the `ParsedIR` and the VM (`Define`) level, then proves it downstream
against the native `Base.Checked` oracle under L2 and L3 plus a per-step
inverse sweep.

**Hostile review caught one MAJOR, now fixed.** The first cut of the
both-constant table had `uadd` at bit 0 ONLY. Since the `bit == 0` emission is
byte-identical to the pre-existing lbot fold-to-zero shape, an arm present at
bit 0 alone proves nothing — that fixture would pass unchanged if the whole
`_ovf_const_bit` path were deleted. **Only an arm's `bit == 1` fixture
discriminates.** Added `uadd i16 65534+3 → 1` and `uadd i64 (2^64-1)+1 → 1`
(plus `umul i16 200*300 → 0` for symmetry), so all four arms now appear in both
polarities, and the coverage rule itself is asserted in the testset so a future
edit that drops an arm fails loudly rather than quietly shrinking the
discriminating half. Also strengthened: the expected bit is no longer a
hand-computed literal — `_tl1l_cbit` recomputes it from the fixture's own `.ll`
constants through `Base.Checked` at the fixture's native width and signedness
(unsigned arms re-decode by masking, exactly as `_ovf_const_bit` does), and the
table's `want` column is cross-checked against it, so a typo in either one
cannot agree with itself.

### BVM gotchas discovered while writing the downstream half

* `BennettVM.result(rs)` returns the WHOLE halted frame's locals, not just the
  declared returns — so the a70z bit `:o` itself can be asserted directly. That
  is the strongest available downstream statement of the contract and is what
  the new file leans on. (It also sidesteps the two-`EndInstruction` ambiguity
  of a fixture that returns from both arms of the `br i1 %o`.)
* At W < 64, `_apply_binop` MASKS results to the low W bits (ADR 0012 R1 /
  `bennettvm-bgc`), so an i32 `x + 5` reads back as a **non-negative** `Int64`
  in `[0, 2^32)` — NOT a sign-extended Int32. The `%p` oracles in the new file
  encode that explicitly (`reinterpret(UInt32, ·)`). This is a BVM storage
  convention, not an a70z claim, and it is called out in the file's honest
  boundary.
* `VMProgram`'s fields are `entry_function` / `entry_label` / `arg_widths` /
  `return_widths` — not `entry` / `input_widths`. `lower_vm(::ParsedIR)`
  (single body) names the entry function `:main` and leaves
  `prog.functions` EMPTY.

### Honest residuals after this session

* The `bit == 0` both-constant shape is byte-identical to the lbot
  fold-to-zero shape by design (a70z D3), so only the `bit == 1` fixtures
  discriminate `_ovf_const_bit` from the pre-existing fold. After the review
  fix all four arms carry a bit-1 fixture, so this is no longer a coverage
  hole — but it remains a property to preserve, and the testset asserts it.
* No Julia program that emits the one-sided or both-constant shape exists
  today (see the research step). The new BVM gate therefore proves the
  front-end→VM contract on hand-written `.ll`, not on a real-corpus program.
  Whether it is worth clearing `Bennett-bjdg`/U80 just to get a from-source
  `checked_add` fixture is a separate question, not filed here.
* N=64 remains spot-checked, not swept (2^64 is not enumerable); N ∈ {1..7, 9..15,
  17..31, 33..63} still have no direct coverage — the formulas are width-generic
  and now anchored at 8/16/32/64, which is the practical stopping point.

---

## Session log — 2026-07-24 — Bennett-a70z: exact overflow bit for a constant operand; the Dict{Int64,Int64} extraction wall is GONE and there is NO next extraction wall

Implementer leg of the Rule-2 3+1 (design phase — scout + 2 blind proposers —
was completed 2026-07-21 and converged; `docs/design/a70z/`). Implementation
followed **Proposal B** (exact admissible-interval compare). The previous
implementer was killed mid-first-test-run and left branch `a70z-overflow-bit`
at an UNVERIFIED WIP (`6953ceb`); nothing in it had ever been observed green.
This session established red honestly, audited the arithmetic adversarially,
fixed three defects, and reached green.

### What the mechanism is

For `extractvalue {iN,i1} %c, 1` where
`%c = llvm.{s,u}{mul,add}.with.overflow.iN(x, c)` and **exactly one** operand is
an `LLVM.ConstantInt`, compute the EXACT no-overflow input interval `[L,U]` of
the dynamic operand at extraction time in `Int128`, and emit
`bit = (x < L) | (x > U)` — at most 2 `IRICmp` + 1 width-1 `IRBinOp(:or)`.
Arms whose bound sits at/outside the iN domain edge are constant-false and are
dropped, so one-sided cases (every `add`, every unsigned op) are a SINGLE
`IRICmp` carrying the extractvalue's own dest and consuming zero `counter`
names. Formulas (`_ovf_admissible_range`, `src/extract/instructions.jl`):

```
smul c>0: [cld(smin,c), fld(smax,c)]     smul c<0: [cld(smax,c), fld(smin,c)]
umul c≥2: [0, fld(umax,c)]               sadd:     [smin-c, smax-c]
uadd c≥1: [0, umax-c]
```

The lbot fold-to-zero set (mul `c ∈ {0,1}`, add `c = 0`) short-circuits to the
byte-identical `IRBinOp(dest,:add,0,0,1)` shape, so every lbot GATE (a) pin and
the klgz determinism guard are untouched. Two dynamic operands still FAIL LOUD.

### RED evidence (before any change, WIP code as committed)

* `test/test_a70z_overflow_const_bit.jl`: 121 pass / **1 error** —
  `@test_broken msg == ""` in testset (e) reported **`Unexpected Pass`**. i.e.
  the WIP's own author had guessed there would be a next wall and pinned it
  broken; there is none.
* `test/test_lbot_overflow_intrinsic.jl`: 26 pass / **2 fail** —
  (b1) `occursin("not provably zero", msg1)` false, the message is now
  `"...with two dynamic operands ... (Bennett-a70z) ... (Bennett-lbot)"`;
  (b2) `st2 === :err` evaluated `ok === err`, i.e. `sadd(%x,5)` now EXTRACTS.
  Both were the predicted honest-GATE-(b) tripwire, and the file IS
  suite-registered (`runtests.jl:556`), so this was a live suite break.

### The three defects found by recon, all confirmed and fixed

1. **D1 — lbot GATE (b) broken.** Split into (b1) two-dynamic still-loud with
   the new message pins (`"two dynamic operands"` + `Bennett-a70z` +
   `Bennett-lbot` + `UNSOUND`), and (b2) an **honest STRENGTHENING** of the
   `sadd(%x,5)` pin: not "extraction succeeded" but a semantic check — the
   single emitted bit instruction is read out of the ParsedIR and EVALUATED for
   12 boundary inputs against `Base.Checked.add_with_overflow` at Int64. The
   `Bennett-lbot` tag is deliberately retained inside the new a70z message so
   the historical pin stays meaningful.
2. **D2 — the new test file was never registered** in `test/runtests.jl`; it
   would not have run under `Pkg.test()` or any gate. Registered next to
   `test_lbot_overflow_intrinsic.jl`.
3. **D3 — the both-operands-constant path deviated from the ratified design.**
   The WIP tested `b isa LLVM.ConstantInt` first, so a both-constant call bound
   `xv` to the OTHER constant and emitted `IRICmp(ConstOperand, ConstOperand)`.
   **Decision: implement Proposal B's `_ovf_const_bit` literal fold.** Reason
   (empirically established, not assumed): under `ptr_cells=true` the ParsedIR
   never reaches `src/lowering/` — the only consumer is BennettVM's ingest,
   which this repo CANNOT verify. (In-repo, `resolve!(::ConstOperand)` would
   handle it fine, but that path is unreachable here because the fuse is
   ptr_cells-gated.) The literal fold reuses the exact
   `IRBinOp(dest,:add,const,const,1)` shape BVM already ingests on the
   fold-to-zero path, is exact by construction, and consumes no counter names.

### The bead's exit criterion — OVERSHOT

`extract_parsed_ir_set_from_julia(fdict64, Tuple{Int64,Int64}; ptr_cells=true,
on_extract_error=:fail_loud)` **succeeds with no error at all.** There is no
next EXTRACTION wall to document. Evidence (probe, Julia 1.12.3):

```
=== BODIES: 4
  fdict64#34a7b689                blocks=23 insts=165
  setindex!#4dafff97              blocks=12 insts=160
  rehash!#e236b303                blocks=70 insts=637
  ht_keyindex2_shorthash!#e236b303 blocks=34 insts=248
=== a70z bound icmps (4 sites × 2 arms, all in rehash!):
  IRICmp(:__v557, :slt, SSAOperand(:value_phi), ConstOperand(-1152921504606846976), 64)
  IRICmp(:__v558, :sgt, SSAOperand(:value_phi), ConstOperand( 1152921504606846975), 64)
  ... ×4 sites
```

`-1152921504606846976 = cld(typemin(Int64),8) = -2^60` and
`1152921504606846975 = fld(typemax(Int64),8) = 2^60-1` — exactly the scout's
predicted bounds, on real Julia IR, at the 4 elsize-8 `smul(%value_phi, 8)`
sites (the other 2 sites in `rehash!` are elsize-1 and still take the
fold-to-zero path). No `llvm.*.with.overflow` IRCall survives anywhere.
The remaining `Dict{Int64,Int64}` work is therefore DOWNSTREAM of extraction
(BVM run-time GenericMemory grow/copy — worklog/094:49-57), not a front-end
wall.

### Gotchas worth keeping

* **`_const_int_as_int` sign-extends** (`LLVMConstIntGetSExtValue`), so an
  unsigned intrinsic's constant arrives NEGATIVE (i8 `192` → `-64`, i64
  `2^63+9` → `-9223372036854775799`). Both `_ovf_admissible_range` and
  `_ovf_const_bit` re-decode by masking to the low N bits. Note the masking
  makes the code robust *even if* LLVM.jl ever switched to zero-extension —
  but the SIGNED arms would break, and the i8-exhaustive test with `c = -1`
  and `c = -128` is what proves the sext behaviour empirically.
* **Bounds do not always fit a nonnegative Int64.** `uadd(x,1)` at i64 has
  `U = 2^64-2`. `_ovf_bound_const` encodes every bound as its low-N-bit
  pattern sign-extended to Int64 (so `U` becomes `-2`) — the SAME convention
  `_operand`/`_const_int_as_int` produce for any literal LLVM constant, so
  this introduces no new contract for BVM. **This encoder was NOT covered by
  the WIP's `(a2)` sweep**, which compares mathematical Int128 bounds and
  never touches the encoder; a new `(a3)` sweep runs the identical
  256 c × 256 x × 4-arm space THROUGH `_ovf_bound_const` with bit-pattern
  comparison semantics. An off-by-one in the encoder for unsigned bounds
  above `2^(N-1)` would silently invert an arm and `(a2)` would still pass.
* **The blanket `!any(x -> x isa IRExtractValue, insts)` assertion does NOT
  generalise from fixtures to the real corpus.** The fdict64 set legitimately
  retains 5 `IRExtractValue`s — `sret_box.unbox*` and `__v74` off `__v1`,
  from the dv1z/416r.16 sret path, entirely unrelated to overflow intrinsics.
  The invariant that actually holds set-wide is "no `*.with.overflow` IRCall
  survives". Cost me one red on a self-inflicted over-strong assertion.
* **`c = -1` is now COMPUTED, not walled.** `smul(x,-1)`: `L = cld(smax,-1) =
  smin+1`, `U = fld(smin,-1) = 2^(N-1)` which folds → the bit is exactly
  `x < smin+1` ⟺ `x == typemin`. The lbot comment's "`-1` is NOT admitted"
  reasoning is still correct — it just no longer requires walling.
* **`c = typemin`** gives `[0,1]` (only `x ∈ {0,1}` avoid overflow), and
  `sadd` can never have both arms live (`L > smin` needs `c<0`, `U < smax`
  needs `c>0`) — so `add` is always a single `IRICmp`.

### Test coverage added on top of the WIP

`(a)` extended with the unsigned arms full-path exhaustive (umul/uadd i8,
constants 2/3/128/255, all 256 inputs); `(a3)` encoded-bound total i8 sweep +
i64 encoder spot-checks; `(a4)` both-constant fold — total i8 sweep of
`_ovf_const_bit` (256×256×4 arms) + i64 edges + 10 full-path fixtures across
all four arms and both bit polarities, asserting NO `IRICmp` is emitted;
`(e)` `@test_broken` replaced by `@test msg == ""` plus structural evidence
(body count, `rehash!`/`setindex!` present, ≥1 elsize-8 fuse site with the
exact `±2^60` bounds, symmetric lo/hi arm counts).

### Green (all `--check-bounds=yes`, run strictly serially)

`test_a70z_overflow_const_bit.jl` 206/206 · `test_lbot_overflow_intrinsic.jl`
50/50 · `test_gate_count_regression.jl` 39/39 (unchanged — the fuse is
ptr_cells-gated, the circuit path cannot move) · `test_lf14_ptr_return_cells.jl`
22/22 (the standing `cwd-ptr-cells-rerun-lf14` rule) · `test_klgz_determinism_guard.jl`
29/29 · `test_416r13_jlglobal_singleton.jl` 16/16 · `test_xrd6_sret_consumed_call.jl`
20/20 · `test_qmv7_gc_loaded_memcpy.jl` 35/35 · `test_59zi_sret_call_memcpy.jl`
547/547 · `test_d1b_julia_set.jl` 33/33 +1 broken (pre-existing) ·
`test_utzc_dead_block_pruner.jl` 31/31 · `test_yd4f_undef_phi_cells.jl` 25/25.
Full `Pkg.test()` NOT run in this leg — gated by the orchestrator.

### Orchestrator gate + cross-repo verification (same session, after the implementer leg)

**Bennett.jl full `Pkg.test()`: 690398 Pass / 3 Broken / 690401 total, 28m37s,
`JULIA_NUM_THREADS=32`, heavy tests ON** (a strictly stronger gate than the
`BENNETT_JL_PIN.md` entry's previous `BENNETT_HEAVY_TESTS=0` run). Zero
failures, zero errors. The 3 Broken are entirely pre-existing: `@test_broken`
counts are byte-identical between this branch and pre-merge `main`
(`runtests.jl` 1, `test_d1b_julia_set.jl` 3, `test_hygiene_aqua_jet.jl` 2,
`test_memory_corpus.jl` 2, `test_mixed_width.jl` 1, `test_value_eager.jl` 1).
a70z in fact *removed* one broken — the WIP's `@test_broken msg == ""` became a
real `@test`. The pin's older "2 pre-existing Broken" was measured with heavy
tests OFF; the third lives in the heavy block.

**Cross-repo (the half the implementer explicitly left unverified): DISCHARGED,
with ZERO BennettVM source changes.** `Dict{Int64,Int64}` goes all four stages —
extract (4 bodies) → `lower_vm` (552-block `VMProgram`, all 8 a70z `IRICmp`s
become width-64 `Define`s and the 4 `:or`s width-1 `Define`s) → run (664 steps,
`fdict64(3,7) == 7`, `fdict64(5,9) == 9`) → `unrun!` (exact initial state, empty
history, `step_count == 0`) under **both** L2 and L3. New
`BennettVM.jl/test/test_a70z_dict64_roundtrip.jl`, 347 assertions,
mutation-proved (`_A70Z_HI + 1` → 11 failures), hostile-reviewed. BennettVM full
suite 7820/7820.

**Two findings from the cross-repo leg worth keeping:**

* **`__vN` SSA names COLLIDE across bodies in a multi-body closed-world run.**
  A first probe read the fuse bit `__v152` by name and got `1099511628136`
  = `ARENA_BASE (2^40) + 360` — a heap pointer belonging to a *different
  frame's* identically-named value. Any name-keyed inspection of a closed-world
  multi-body trajectory is frame-ambiguous; resolve `_instruction_at(prog, pc)`
  and read frame-exactly instead.
* **The overflowing arm is DYNAMICALLY UNREACHABLE and always will be.** The
  only operand value the real trajectory ever presents is `16` (the initial
  `Dict` slot count) — 57 binades from either boundary — and a `Dict` with more
  than `2^60` slots cannot be allocated. So `bit == 1` can never be covered by
  execution; it is covered arithmetically instead (upstream `(a)`/`(a2)`/`(a3)`
  oracle sweeps, and a downstream `(d0)` testset asserting the bounds are
  *tight*, not merely sound, against `Base.Checked.mul_with_overflow`). Do not
  read the absent dynamic coverage as a gap that a better test could close.

**Environmental caveat on the BVM number (see `bennettvm-5o86`):** 7820 is
*lower* than the pin's previous 9848 because **this box has no clang**, so the
clang-gated e2e blocks self-skip per the T5-corpus convention. Environmental,
not a regression — a70z only added a test file. But it means a "green" here is
~20 % weaker than one from the other box, announced only by two easily-missed
`@info` lines.
