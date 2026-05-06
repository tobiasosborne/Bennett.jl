# Bennett.jl ↔ Enzyme Parity — North Star

> **Status:** north-star aspiration, not a delivery commitment. This document
> defines the *target shape* of Bennett.jl's coverage, framed against
> Enzyme's mature capability surface (LLVM 18, Enzyme.jl 0.13.x, ground-truth
> source survey 2026-05-04). Concrete deliverables are tracked via `bd`;
> this file is the reference both must agree with.

## Premise

Enzyme is Bennett.jl's closest analogue: an LLVM-IR-to-something-else
transformation pass with a Julia frontend, layered analyses, an extensible
rule system, and a recursive inline-and-transform fallback. Where Enzyme
*differentiates*, Bennett *reverses*. Where Enzyme produces a gradient
function, Bennett produces a reversible classical circuit. The compilation
problems differ in their target — but the **input surface is identical**:
LLVM IR from Julia/C/Rust frontends, with rules for everything we choose
not to inline.

This makes Enzyme a useful capability mirror: anything Enzyme cleanly
handles is something a mature LLVM-IR transformer *can* handle, and is
therefore a fair benchmark for whether Bennett has reached parity.

## Architecture parity (already achieved)

| Component | Enzyme | Bennett |
|---|---|---|
| Frontend | Clang/Julia/Rust → LLVM IR | Julia → LLVM IR (via LLVM.jl C-API) |
| Two-phase | augmented forward + reverse | forward + CNOT-copy + reverse |
| Rule system | TableGen + `EnzymeRules.*` | `register_callee!` registry |
| Cache vs. recompute | `computeMinCache` (min-cut) | `BennettStrategy` (Default/Eager/ValueEager/Checkpoint/Pebbled/PebbledGroup) |
| Hard-stop philosophy | fail fast with typed errors | fail fast with typed `ArgumentError`/`AssertionError` |
| Activity model | per-value `const`/`active` | wire-partition (in-circuit / not) |
| Type analysis | TypeTree + TBAA + Rust DWARF | trust LLVM types directly |
| Memory shadow | per-allocation, same address space | ancilla wires returning to zero |

The core architectural pieces map cleanly. The remaining work is *coverage
breadth*, not structural redesign.

## Coverage parity — current status (2026-05-04)

### Tier A — at parity

- **LLVM control flow:** `br`, `switch`, `phi`, `select`, `ret`, loop
  unrolling.
- **Memory ops:** `load`, `store`, `alloca`, `getelementptr` — *including*
  runtime-indexed multi-origin loads/stores (Bennett-cb9y + Bennett-dnh,
  closed 2026-05-01). Bennett's `_MUX_SHAPES_NW` covers all (N, W) with
  N·W ≤ 64.
- **Aggregates:** `extractvalue`, `insertvalue`, `extractelement`,
  `insertelement`, `shufflevector`.
- **Vector ops:** SLP-vectorised IR (Bennett-cc0.7).
- **Casts:** `fpext`, `fptrunc`, `bitcast`, `trunc`, `zext`, `sext`,
  `fptosi/fptoui`, `sitofp/uitofp`.
- **Bit intrinsics:** `llvm.ctpop`, `llvm.ctlz`, `llvm.cttz`,
  `llvm.bitreverse`, `llvm.bswap`, `llvm.fshl`, `llvm.fshr` —
  *Bennett supports these as gates; Enzyme treats them as zero-derivative
  inactive*. **Bennett is richer here.**
- **Min/max/abs:** `llvm.umin/umax/smin/smax`, `llvm.abs`,
  `llvm.minnum/maxnum/minimum/maximum`.
- **Float manipulation:** `llvm.fabs`, `llvm.copysign`, `llvm.floor`,
  `llvm.ceil`, `llvm.trunc`, `llvm.rint`, `llvm.round`.
- **f64 transcendental family** — full LLVM intrinsic dispatch (Bennett
  beads in parens):
  - `llvm.sqrt.f64` (ux2 / 1pb), `llvm.fma.f64` / `llvm.fmuladd.f64` (0xx3 / h6f)
  - `llvm.exp.f64`, `llvm.exp2.f64` (cel)
  - `llvm.log.f64`, `llvm.log2.f64`, `llvm.log10.f64` (582)
  - `llvm.pow.f64`, `llvm.powi.f64.i32` (emv / jexo)
  - `llvm.sin.f64`, `llvm.cos.f64` (3mo, 2026-05-03)
  - `llvm.tan.f64` (s1zl, 2026-05-04), `llvm.atan.f64` (qpke, 2026-05-04),
    `llvm.asin.f64` (ckvj, 2026-05-04), `llvm.acos.f64` (bd7f, 2026-05-05)
    `llvm.atan2.f64` (7goc, 2026-05-06)
    — Tier C1.1 / C1.2 / C1.3 / C1.4 / C1.5 (below)
- **Hard stops match Enzyme's:** atomic non-fadd ops, `cmpxchg`, `invoke`,
  `landingpad`, `resume`, `catchpad/switch`, `indirectbr`, `callbr`,
  inline asm, `llvm.coro.*`, scalable vectors.

### Tier B — partial / in-flight

- **memcpy/memset/memmove** (`Bennett-hao` umbrella):
  - Phase 1 const-size memcpy: closed (Bennett-37mt)
  - Phase 2 const-c const-N memset: closed (Bennett-9nwt)
  - `[N x i8]` ArrayType extraction: closed (Bennett-munq)
  - Memmove with alias analysis: open (Bennett-yxr8)
  - Non-fresh dst destructive store: open (Bennett-zmry)
  - Global-pointer src QROM fan-out: open (Bennett-doih)
  - Variable-N: open (Bennett-ixiz, Bennett-xtu9)
  - Enzyme: full element-wise gradient or shadow-copy depending on type
- **Vectors beyond SLP:** non-SLP `llvm.masked.load/store`,
  `llvm.vector.reduce.*` open (Bennett-vb2). Enzyme handles
  `vector.reduce.fadd`/`fmax` and `masked.load/store` but not most others.
- **Float32 native arithmetic:** Bennett currently routes f32 through
  `fpext → f64-op → fptrunc` with documented double-rounding (CLAUDE.md
  §13). Bennett-3rph open. Enzyme has full f16/bf16/f32/f64/fp80/fp128.

### Tier C — north-star gaps (not yet addressed)

These are the deltas where Enzyme has functionality and Bennett has none.
Each is a candidate workstream; none is filed as a bead yet because the
broader strategy isn't pinned.

#### C1 — Trig completion
- `tan` — **closed** (Bennett-s1zl, 2026-05-04). musl `__tan` port reusing
  `_rp_rem_pio2` infrastructure from `fsin.jl`; max ULP = 1 on a 500k
  random sweep across 5 magnitude buckets up to 1e22.
- `atan` — **closed** (Bennett-qpke, 2026-05-04). Self-contained branchless
  port of musl `atan.c` — bounded-range rational reductions, no Cody-Waite
  / Payne-Hanek dependency. Max ULP ≤ 2 on a 500k random sweep + 1076-input
  subnormal binade sweep at 0 ULP.
- `asin` — **closed** (Bennett-ckvj, 2026-05-04). Branchless port of musl
  `e_asin.c` (FreeBSD/Sun 1993). Single ifelse-selected `_asin_R(z)` call
  per invocation (SLP-vectorisation guard per qpke gotcha #1); the
  rational `R(z)` and constants are module-private, **shared with
  `soft_acos`** (Bennett-bd7f) per CLAUDE.md §12. ≤2 ULP vs `Base.asin`
  on 100k random samples × 3 seeds across all four input regimes.
- `acos` — **closed** (Bennett-bd7f, 2026-05-05). Branchless port of musl
  `acos.c` reusing `_asin_R(z)` plus the 10 polynomial coefficients +
  `pio2_hi`/`pio2_lo` from `fasin.jl` (Bennett-ckvj) per CLAUDE.md §12.
  Four-regime branchless dispatch (tiny / small / pos-large / neg-large).
  ≤2 ULP vs `Base.acos` on 100k random × 3 seeds; subnormal-output proven
  absent per §13 (acos's range [0, π] never reaches the subnormal regime
  for any representable f64 input).
- `atan2` — **closed** (Bennett-7goc, 2026-05-06). Faithful port of musl
  `atan2.c`. Built on `soft_atan` (Bennett-qpke) per CLAUDE.md §12 —
  ONE soft_fdiv + ONE soft_atan call, the rest is XOR / ifelse / one
  fsub for quadrant offset. ≤2 ULP vs `Base.atan(y, x)` on 100k random
  × 3 seeds across 4 magnitude buckets × 4 quadrants. All special cases
  (axis points, ±0/±0, ±Inf/finite, ±Inf/±Inf, NaN propagation) bit-
  exact. **Two LLVM-ingest paths**: `llvm.atan2.f64` intrinsic AND libm
  `@atan2` external call (the latter for older LLVM <18 / `-fno-builtin`
  C/Rust outputs). Drive-by fix to the same instructions.jl block:
  tightened `llvm.{sin,cos,tan,atan,asin,acos}` prefixes with trailing
  `.` to prevent the silent miscompile that previously matched
  `llvm.atan2.f64` against the `llvm.atan` arm and dropped the second
  operand (~5/8 quadrants returned `atan(y)` not `atan2(y, x)`). Same
  class of bug pre-empted for sinh/cosh/tanh/asinh/acosh/atanh.
- `tanh` — **closed** (Bennett-m2bv, 2026-05-06). Branchless port of
  Julia stdlib `Base.tanh(::Float64)` (julia 1.12 base/special/
  hyperbolic.jl:128-159) — three regimes: degree-10 minimax polynomial
  in x² for `|x| ≤ 0.5` (coefficients verbatim from
  `Base.tanh_kernel`), `1 - 2/(exp(2|x|)+1)` for `0.5 < |x| < 22`,
  `±1` saturation for `|x| ≥ 22`. ONE `soft_exp_fast` call total
  (FTZ branch unreachable since exp arg is non-negative — saves
  ~1.4M gates vs `soft_exp`). ≤2 ULP vs `Base.tanh` on a 100k random
  sweep × 3 seeds × 4 magnitude buckets; subnormal-input preserved
  bit-exactly via the polynomial branch (`x²` underflows → 0,
  `tanh_kernel(0) = 1`, `x · 1 ≡ x`) — 0 ULP across all 1074
  subnormal binades × both signs (verified). Drive-by note: `musl`
  `s_tanh.c` couldn't be ported verbatim because Bennett.jl lacks
  `soft_expm1`; the Julia-stdlib polynomial-in-x² substitution
  sidesteps that gap.
- `sinh`, `cosh`, `asinh`, `acosh`, `atanh` — open

  Enzyme: TableGen via `IntrPattern` (LLVM ≥19) + C-library `CallPattern`.
  Bennett: 6 of 11 done. The playbook is well-rehearsed (3mo / 582 / emv
  / jexo / s1zl / qpke / ckvj / bd7f / 7goc / m2bv): port a vetted
  reference (musl / Arm Optimized Routines / Julia stdlib), ship per-
  bead regression tests with random sweep + subnormal-output testset
  (per CLAUDE.md §13).

#### C2 — Other transcendentals
- `expm1`, `log1p`, `cbrt`, `hypot`, `exp10`, `ldexp`, `frexp`, `scalbn`,
  `modf`, `fmod`, `remainder`, `fdim`, `sinpi`, `cospi`, `sinc`

  Enzyme: TableGen (~30 entries). Several of these (e.g. `expm1`,
  `log1p`) are *first-class numerically*: rolling them yourself via
  `exp(x) - 1` loses the precision that motivated their existence.
  Reference implementations exist in musl, openlibm, Julia stdlib.

#### C3 — Special functions
- `erf`, `erfc`, `erfi`, `erfinv`, Faddeeva variants
- `tgamma`, `lgamma`, `digamma`
- Bessel `j0`, `j1`, `y0`, `y1`, `jn`, `yn`

  Enzyme: TableGen (~20 entries). Bennett: zero. These are
  scientific-computing bread and butter, but the implementations are
  long (each ~200-500 LOC of polynomial table + range reduction).
  Lower priority than C1/C2 unless a downstream user (Sturm.jl?) needs
  them.

#### C4 — Complex arithmetic
- `__mulsc3`, `__muldc3`, `__multc3`, `__mulxc3` (complex multiply)
- `__divsc3`, `__divdc3`, `__divtc3`, `__divxc3` (complex divide)
- `cabs`, complex `sqrt`, `exp`, `log`, `pow`, `sin`, `cos`, ...

  Enzyme: TableGen via `CFMul`/`CFDiv`/`CFNeg`/`CFExp` patterns.
  Bennett: zero. Less culturally important to Julia (which uses
  `Complex{Float64}` with native struct layout), but raw .ll/.bc
  ingest from C/Rust will see these.

#### C5 — BLAS / LAPACK
- Level 1: `scal`, `axpy`, `dot`, `nrm2`, `copy`, `asum`
- Level 2: `gemv`, `trmv`, `ger`, `symv`, `spmv`, `trtrs`
- Level 3: `gemm`, `trmm`, `symm`, `syrk`, `syr2k`, `trsm`
- LAPACK: `potrf`, `potrs`, `lacpy`, `lascl`

  Enzyme: TableGen via `BlasDerivatives.td` (~20 routines, both modes).
  Bennett: zero, and structurally **harder** than the others — see
  separate discussion below.

#### C6 — Threading and concurrency
- OpenMP: `__kmpc_for_static_init/fini`, `__kmpc_barrier`,
  `__kmpc_critical`, OMP parallel tasks
- MPI: `MPI_{Send,Recv,Bcast,Reduce,Allreduce,Gather,Scatter,Barrier,...}`
- Julia threading: `Threads.@threads`, `Threads.@spawn`, `jl_new_task`,
  `Threads.threading_run`
- GPU barriers: `nvvm.barrier0`, `amdgcn.s_barrier`

  Enzyme: full rules in `parallelrules.jl` and `CallDerivatives.cpp`.
  Bennett: explicit non-goal under current model — atomic semantics
  collapse to single-thread, and reversibility under concurrent shared
  memory is an open research question. Document as **out of scope**
  unless/until quantum control demands it.

#### C7 — Bit ops Enzyme can't do
- `ctpop`, `bswap`, `bitreverse`, `fshl`, `fshr` are **Bennett-only
  capabilities**. Enzyme treats them as `KnownInactiveIntrinsics` (zero
  derivative), which is fine for autodiff but useless for general
  reversible compilation. **Listed here as a Bennett superpower, not a
  gap.**

## North-star vision: "every LLVM opcode in pure numerical code from
supported frontends, plus anything you write a rule for"

Concretely, this means:

1. **Tier A complete and pinned** with regression tests and subnormal
   sweeps where applicable. Already true for the listed items.
2. **Tier B closed**: memcpy/memset/memmove fully covers Julia+C+Rust
   IR shapes (8bys umbrella delivered); native f32 arithmetic shipped
   (Bennett-3rph) so we drop the double-rounding caveat; non-SLP vector
   ops covered (Bennett-vb2).
3. **Tier C1 + C2 shipped** as the highest-leverage extension: trig +
   inverse trig + hyperbolics + the precision-critical extras
   (`expm1`/`log1p`/`hypot`/`cbrt`). Each ships as a `soft_*` Julia
   function with bit-exact (or ≤1-ulp where impractical) parity vs.
   `Base`, plus LLVM intrinsic dispatch and per-bead regression test.
4. **Tier C3 + C4 deferred** until user demand surfaces — large surface
   area, niche audiences. Plumbing is identical to C1/C2 if someone
   does want them.
5. **Tier C5 (BLAS) handled by callee registration**, not in-line
   reversible compilation — see discussion below for why this is
   architecturally distinct.
6. **Tier C6 explicit non-goal** for v1.x — document as out-of-scope
   until quantum-control use cases (Sturm.jl) actually require it.

The yardstick: when a user `reversible_compile`s a numerical Julia
function, the only failure mode they should see is "no LLVM frontend
generated this opcode" or "external function not registered as callee."
Hitting "this `llvm.*` intrinsic isn't supported yet" is a bug we close
under this north star.

## Out-of-scope, deliberately

These are Enzyme features Bennett *should not* try to match:

- **Differentiation modes** (forward/reverse/batched/holomorphic): Bennett
  has one mode — reverse-the-circuit. The split-pass machinery and
  activity wrappers (`Active`/`Duplicated`/`BatchDuplicated`) are not
  applicable.
- **Higher-order autodiff** (Hessian-vector product, fwd-over-rev):
  conceptually meaningless for circuit reversal.
- **Sparsity/colouring API**: Bennett's wires are dense by construction.
- **TypeAnalysis lattice / TBAA**: Bennett trusts LLVM's type system
  directly because Julia-emitted IR is well-typed. We don't need an
  abstract interpretation to recover what `code_llvm(f, types;
  optimize=false)` gives us for free.
- **Activity analysis**: Bennett's wire-partition (in-circuit / not) is
  the structural equivalent and is decided lexically, not by
  flow-sensitive analysis.

## Reference: Enzyme source

External checkouts are gitignored under `external/`:
- `external/Enzyme/` — LLVM plugin, ~80k LOC C++
- `external/Enzyme.jl/` — Julia bindings, ~42k LOC

Key files for parity reference:
- `external/Enzyme/enzyme/Enzyme/AdjointGenerator.h` — opcode dispatch
- `external/Enzyme/enzyme/Enzyme/InstructionDerivatives.td` — TableGen
  rules for math intrinsics + named C library calls
- `external/Enzyme/enzyme/Enzyme/BlasDerivatives.td` — TableGen rules
  for BLAS/LAPACK
- `external/Enzyme/enzyme/Enzyme/CallDerivatives.cpp` — call/intrinsic
  hand-coded handlers
- `external/Enzyme.jl/src/internal_rules/math.jl` — Julia-level math
  rules (only `hypot` currently — the rest live in TableGen)
- `external/Enzyme.jl/src/rules/customrules.jl` — `EnzymeRules.*` plumbing
- `external/Enzyme.jl/src/internal_rules/inactive.jl` — statically-inactive
  function set (~120 names)

## Update protocol

When a north-star gap closes, update Tier B/C in this file in the same
commit as the close (per Bennett-58rl bundling convention). When a new
Enzyme capability is discovered that isn't catalogued here, append to
the relevant Tier and file a `bd` issue if Bennett wants to match it.
