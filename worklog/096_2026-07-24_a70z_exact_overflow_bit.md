# worklog chunk 096 — 2026-07-24 — Bennett-a70z exact constant-operand overflow bit

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
