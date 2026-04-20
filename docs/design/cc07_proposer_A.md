# Proposer A — cc0.7: vector-op handling in `ir_extract.jl`

**Milestone**: Bennett-cc0.7 — unblock `optimize=true` for functions that Julia
auto-vectorises into `<N x iM>` SIMD.
**Failing target**: `test/test_cc07_repro.jl` (uses
`benchmark/cc07_repro_n16.jl::ls_demo_16`). Currently crashes extraction with
`"Unsupported LLVM opcode: LLVMInsertElement"`. Current workaround is
`optimize=false`, which costs 3–50× in gate count because it also disables
sroa, mem2reg, simplifycfg, instcombine.
**Reference IR**: `/tmp/cc07_n16_ir.ll` (2694 bytes, N=16 linear-scan demo).
**Contract with co-proposer / implementer**: invariants in §4 and §8 are load-
bearing; the gate-count prediction in §8 is an upper bound, not a floor; the
`lower.jl` interaction in §9 must remain zero touches.

---

## 1. High-level approach — scalar lane-expansion at extraction time

### 1.1 One-liner

**Treat every vector SSA value as syntactic sugar for an N-tuple of named
scalar SSA values, and expand it entirely inside `ir_extract.jl`.** No
`IRVector*` IR nodes, no changes to `lower.jl`, no new gate types. Each
vector-typed LLVM SSA `%v` of type `<N x iM>` gets `N` per-lane synthetic
Symbols `__v_<id>_lane0 … __v_<id>_laneN-1`, and each vector opcode is
desugared into `N` scalar IR instructions over those per-lane names.

### 1.2 Why this shape

Four competing shapes were considered; I rank-ordered them and picked the
first:

| Shape | How a vector SSA is represented | Changes to `lower.jl`? | Gate-count risk | Complexity |
|---|---|---|---|---|
| **A (chosen): lane-expansion** | `N` named scalar SSAs recorded in a side-table `vec_lane_names::Dict{_LLVMRef, Vector{Symbol}}` | **None** | None — produces identical IR to the unvectorised `optimize=true` path | Low; all logic in `ir_extract.jl` |
| B: opaque wide integer | Single Symbol of width `N*M`; selects/adds on the wide int | Yes — `lower.jl` must strip-mine N·M bit widths, or we need bit-field extract | High: a `<8 x i8>` add would not be bitwise-equivalent to 8 parallel i8 adds because carry doesn't cross lanes; we'd have to emit masked adders, which is a different gate recipe per lane | Medium |
| C: new `IRVector*` IR nodes + new lowering handlers | One SSA name carrying lane count & per-lane width | Yes — ~8 new lowering handlers, each fan-outs into scalar lanes anyway | Need to duplicate every scalar lowering path (adder, icmp, select) for vector variants | High, and CLAUDE.md §12 violation (duplicate lowering) |
| D: run an LLVM pass (scalarizer / vector-combine) to lane-split before extraction | Vectors are gone before our walker sees them | None | Trusts an external pass; brittle across LLVM versions; doesn't solve a fresh vector that instcombine introduces | Low but fragile |

**Shape A wins on every axis except one** — it needs the extractor to
synthesise lane Symbols *before* first-pass naming so `_operand()` on
`extractelement`'s operand can resolve. §3 handles that.

### 1.3 Correspondence to the failing IR

For `/tmp/cc07_n16_ir.ll`:

| LLVM line | LLVM instruction | Lane-expanded IR produced |
|---|---|---|
| `%0 = insertelement <8 x i8> poison, i8 %seed, i64 0` | InsertElement into poison | `lane0 := %seed`; `lane1..lane7 := undef` (we special-case: `iconst(0)` for poison, see §4.2) |
| `%1 = shufflevector <8 x i8> %0, poison, <8 x i32> zeroinitializer` | Broadcast | `%1_laneK := %0_lane0` for K=0..7 (all lanes alias `%seed`) |
| `%2 = add <8 x i8> %1, <i8 16, 18, 20, 22, 24, 26, 28, 30>` | Vector add by constant-vector | 8× `IRBinOp(%2_laneK, :add, ssa(%1_laneK), iconst(16+2K), 8)` |
| `%12 = icmp eq <8 x i8> %2, %11` | Vector eq | 8× `IRICmp(%12_laneK, :eq, ssa(%2_laneK), ssa(%11_laneK), 8)` |
| `%29 = extractelement <8 x i1> %12, i64 0` | Lane 0 of %12 | `IRBinOp(%29, :add, ssa(%12_lane0), iconst(0), 1)` — trivial rename via add-0 (same pattern used for `freeze`, `ir_extract.jl:1142`) |

After expansion, `lower.jl` sees a scalar IR block with the same shape it
would see for the `optimize=false` (un-SLP-vectorised) code, minus the
allocas/stores that sroa/mem2reg eliminate — exactly the shape we want.

### 1.4 Fundamental invariant: **vector SSA never leaves `ir_extract.jl`**

No `IRVector*` struct is added to `ir_types.jl`. No LLVM vector type ever
appears in a ParsedIR. `_type_width` is extended **only** so that `_iwidth`
can be called on the per-lane element type when the dispatcher queries an
operand, never on the vector itself. This keeps the scope tight and satisfies
CLAUDE.md §12 (no duplicated lowering).

---

## 2. Per-opcode handlers — specification

All new logic lives inside `_convert_instruction` in `ir_extract.jl` (or in
private helpers called from it). Every handler either returns a
`Vector{IRInst}` of scalar instructions or `nothing` (if the vector value is
consumed entirely by a later `extractelement`/vector op, which is the common
case — but note `dest` still has to be reachable if a later op reads it, so
we *always* emit per-lane scalar instructions, even if the vector SSA itself
has no direct integer consumer).

### 2.1 Vector type detection helper

```julia
# Returns (n_lanes, elem_width) if the value's type is <N x iM> for M in {1,8,16,32,64}.
# Returns nothing for non-vector values.
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    et isa LLVM.IntegerType ||
        error("Unsupported vector element type $et (only integer lanes are supported); " *
              "got vector type $vt")
    n = LLVM.length(vt)
    w = LLVM.width(et)
    return (n, w)
end
```

### 2.2 `LLVMInsertElement`

```llvm
%dest = insertelement <N x iM> %src_vec, iM %scalar, i64 %lane_idx
```

LangRef (`https://llvm.org/docs/LangRef.html#insertelement-instruction`):
"If `%lane_idx` exceeds the length of `%src_vec` the result is poison."

Handler contract:
- `%lane_idx` MUST be a `ConstantInt` in scope. Dynamic lane indices are
  rejected with a clear error (see §5 out-of-scope).
- `%src_vec` is either a named SSA vector, or `poison`/`undef`/`zeroinitializer`.
- Produces: `N` per-lane Symbols copied from `%src_vec`'s lanes, with lane
  `%lane_idx` replaced by `%scalar`.

Expansion:
```
for k in 0:N-1:
    if k == lane_idx:
        lane_names[dest][k+1] = scalar_sym      # alias: no gates; see §3.3
    else:
        lane_names[dest][k+1] = src_lane_names[k+1]
```

Emitted IR: **zero instructions** (pure aliasing in the lane table).

### 2.3 `LLVMExtractElement`

```llvm
%dest = extractelement <N x iM> %vec, i64 %lane_idx
```

Handler contract:
- `%lane_idx` MUST be a `ConstantInt` (dynamic lane index = error).
- `%vec` must have already been lane-named (any vector SSA gets lane-named
  the moment it's defined — see §3).

Expansion: `dest` is simply renamed to the lane Symbol. But `dest` is already
in `names` from the first-pass walk and other IR may refer to it, so we can't
just re-point the dict. We use the same trick `freeze` uses
(`ir_extract.jl:1142`):

```julia
return IRBinOp(dest, :add, ssa(src_lane_names[lane_idx + 1]), iconst(0), elem_width)
```

Add-zero is folded by `lower.jl` into a CNOT-copy (width gates). For
`extractelement` of an i1 vector (the icmp-result case, line 49 of the IR),
`elem_width = 1` and the add-zero handler in `lower.jl` handles i1 correctly
(verified by `freeze` already using this pattern).

**Gate impact**: one CNOT-copy per extract (W gates for width W). For i1 this
is 1 CNOT, for i8 it's 8 CNOT. For the N=16 demo: 8 extractelements at i1 = 8
extra CNOT vs the optimize=false path. This is noise compared to the
reduction from dropping the sroa/mem2reg disablement.

### 2.4 `LLVMShuffleVector`

```llvm
%dest = shufflevector <N x iM> %v1, <N x iM> %v2, <L x i32> %mask
```

LangRef: the mask is a literal constant vector (not a runtime SSA in any LLVM
version we target — LLVM 12+); the output has `L` lanes; each mask element
is in `[0, 2N-1]` selecting from the concatenation `[v1, v2]`, or `-1` for
"undef lane". `L` may differ from `N` (shuffle can widen/narrow).

Handler contract:
- Mask is accessed via `LLVM.API.LLVMGetNumMaskElements(inst)` and
  `LLVM.API.LLVMGetMaskValue(inst, i)` (confirmed in
  `/home/tobias/.julia/packages/LLVM/fEIbx/lib/17/libLLVM.jl:6217, 6243`).
  These return a 32-bit signed int, with `-1` (or the sentinel
  `LLVMGetUndefMaskElement` constant which is also `-1`) indicating "undef".
- `%v1`, `%v2` must already be lane-named. `%v2 = poison` is allowed and
  common (see IR line 5).

Expansion:
```
L = LLVM.API.LLVMGetNumMaskElements(inst)
(N_in, W) = _vector_shape(v1)      # must equal _vector_shape(v2)
for k in 0:L-1:
    m = LLVM.API.LLVMGetMaskValue(inst, k)
    if m == -1:                     # undef lane
        lane_names[dest][k+1] = _synth_zero_lane(counter, W)   # fresh Symbol bound to iconst(0)
    elseif 0 <= m < N_in:
        lane_names[dest][k+1] = lane_names[v1][m+1]
    elseif N_in <= m < 2*N_in:
        lane_names[dest][k+1] = lane_names[v2][m - N_in + 1]
    else:
        error("shufflevector mask index $m out of range [0, $(2*N_in))")
```

Emitted IR: **zero instructions** (pure aliasing). Undef lanes: §4.2.

### 2.5 Vector-typed arithmetic / bitwise / shift ops

Opcodes: `LLVMAdd`, `LLVMSub`, `LLVMMul`, `LLVMAnd`, `LLVMOr`, `LLVMXor`,
`LLVMShl`, `LLVMLShr`, `LLVMAShr`. Detection: the existing binop branch
(`ir_extract.jl:662`) calls `_iwidth(inst)` which hits `_type_width`, which
currently errors on `LLVM.VectorType`. Fix: before the binop branch, check
`_vector_shape(inst) !== nothing` and route to the vector handler.

Expansion:
```julia
function _lower_vector_binop!(inst, op_sym, names, counter, lane_names)
    (N, W) = _vector_shape(inst)
    ops = LLVM.operands(inst)
    v1_lanes = _resolve_lane_names(ops[1], N, W, names, counter, lane_names)
    v2_lanes = _resolve_lane_names(ops[2], N, W, names, counter, lane_names)
    dest_lanes = lane_names[inst.ref]   # pre-allocated in first pass (§3)
    out = IRInst[]
    for k in 1:N
        push!(out, IRBinOp(dest_lanes[k], op_sym,
                           ssa_or_const(v1_lanes[k]),
                           ssa_or_const(v2_lanes[k]), W))
    end
    return out
end
```

`_resolve_lane_names` handles:
- Already-named SSA vector: look up in `lane_names`.
- `ConstantDataVector` (e.g. `<i8 16, i8 18, ...>` on line 6 of the IR):
  use `Base.getindex(cdv, k)` which returns the per-lane `ConstantInt`
  (confirmed at `/home/tobias/.julia/packages/LLVM/fEIbx/src/core/value/constant.jl:236`).
- `ConstantAggregateZero`: every lane is `iconst(0)`.
- `UndefValue` / `PoisonValue`: every lane is `iconst(0)` (see §4.2).
- `ConstantVector` (rare; wraps non-simple elements): iterate via
  `LLVM.operands(cv)` and constant-fold each.

`ssa_or_const(x)` returns `ssa(x)` if `x::Symbol`, `x` unchanged if
`x::IROperand`.

### 2.6 `LLVMICmp` (vector variant)

Detection: `_vector_shape(inst) !== nothing`. Note it's the *result* type
that's `<N x i1>`, not necessarily the operand type (LLVM allows vector icmp
on vector operands).

Expansion:
```julia
(N, _) = _vector_shape(inst)      # element width is always 1 (i1)
op_W = _vector_shape(ops[1])[2]    # operand lane width
for k in 1:N
    push!(out, IRICmp(dest_lanes[k], pred_sym,
                      ssa_or_const(v1_lanes[k]),
                      ssa_or_const(v2_lanes[k]), op_W))
end
```

### 2.7 `LLVMSelect` (vector variant)

LangRef: select on vectors can take either a scalar `i1` condition (broadcast)
or a `<N x i1>` vector condition. The existing handler hits `_iwidth(inst)`
which crashes on vector type.

Expansion:
```julia
(N, W) = _vector_shape(inst)
cond = ops[1]
cond_is_vec = _vector_shape(cond) !== nothing
cond_lanes = cond_is_vec ? _resolve_lane_names(cond, N, 1, ...) : nothing
for k in 1:N
    c_op = cond_is_vec ? ssa_or_const(cond_lanes[k]) : _operand(cond, names)
    push!(out, IRSelect(dest_lanes[k], c_op,
                        ssa_or_const(v1_lanes[k]),
                        ssa_or_const(v2_lanes[k]), W))
end
```

### 2.8 Vector casts: `LLVMSExt`, `LLVMZExt`, `LLVMTrunc`, `LLVMBitCast`

LangRef: vector ↔ vector casts preserve lane count; each lane is cast
independently.

Expansion:
```julia
(N, W_to) = _vector_shape(inst)
(N_src, W_from) = _vector_shape(ops[1])     # assert N_src == N
for k in 1:N
    push!(out, IRCast(dest_lanes[k], op_sym,
                      ssa_or_const(src_lanes[k]), W_from, W_to))
end
```

For `LLVMBitCast` specifically: if the *source* is a vector and the dest is
an integer of the same total width (or vice versa — rare but legal), this is
a ditch-wide reinterpret. Reject with a clear error and require
`optimize=true` + simplifycfg to clean it up first, or degrade to
`optimize=false` as a last resort. In the N=16 demo this does not appear.
Keep strictly as "vector bitcast to same-shape vector" for MVP.

### 2.9 Opcodes NOT seen in `/tmp/cc07_n16_ir.ll` but in scope

`LLVMUDiv`, `LLVMSDiv`, `LLVMURem`, `LLVMSRem` on vector types: same lane-
expansion. Not exercised by cc0.7 RED, but free to implement (the dispatcher
already has a `div/rem` arm at `ir_extract.jl:704`, just needs the vector
branch).

`LLVMFNeg`, `LLVMFCmp` on vector float types: **out of scope** for MVP (§5).
SoftFloat dispatch means Julia-level Float64 ops are already lowered to
integer soft-float calls before we see LLVM IR, so FP vector ops shouldn't
arise. If one does, we error with "FP vector ops unsupported — file a bug".

### 2.10 Constant vectors as operands

Three shapes seen in LLVM 17:

| LLVM literal | Julia type | Per-lane extraction |
|---|---|---|
| `<i8 16, i8 18, ...>` (simple integer elements) | `LLVM.ConstantDataVector` | `Base.getindex(cdv, k)` returns `ConstantInt`; convert with existing `_operand` |
| `zeroinitializer` on a vector type | `LLVM.ConstantAggregateZero` | every lane = `iconst(0)` |
| `<N x iM>` with non-literal lanes (e.g. all elements are other constants) | `LLVM.ConstantVector` | iterate `LLVM.operands(cv)`; each operand is already a constant |
| `poison` / `undef` | `LLVM.PoisonValue` / `LLVM.UndefValue` | every lane = `iconst(0)` (see §4.2) |

### 2.11 `poison` / `undef` policy

LangRef: `insertelement <N x iM> poison, ...` is the standard lane-broadcast
idiom. A lane written to later is well-defined; lanes left as `poison` are
undefined behaviour if observed.

**Policy**: model every `poison` / `undef` lane as `iconst(0)`. This is safe
because:
1. If the program reads the poison lane, it's UB — any value is legal.
2. If it doesn't read it (the common case — see IR line 4, which writes lane
   0 then broadcasts, so lanes 1..7 never matter), the downstream aliasing
   through `shufflevector` propagates the constant-zero through but the
   extractelements only pick the defined lanes.
3. Using `iconst(0)` means no wires are allocated for poison lanes —
   `lower.jl`'s constant-folding swallows them. No gate overhead.

Concretely, `_synth_zero_lane` returns a fresh Symbol alias for `iconst(0)`;
but better, we skip the Symbol entirely and put `iconst(0)` directly in
`lane_names[ref][k]` as a cached `IROperand`. See §3.2 for the typed
side-table.

---

## 3. Name-table integration — the load-bearing piece

### 3.1 The challenge

`ir_extract.jl` uses a two-pass approach (`:447`):

```julia
# Pass 1: name every instruction.
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        names[inst.ref] = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    end
end

# Pass 2: convert instructions (uses `names` and `_operand`).
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        ir_inst = _convert_instruction(inst, names, counter)
        ...
```

Pass 1's invariant: every LLVMValueRef used as an SSA operand later has a
Symbol in `names`. Pass 2's `_operand` relies on this: it errors on unknown
ref (`:1334`).

**For vectors**: when pass 2 hits an `insertelement`, it wants to look up the
*per-lane* Symbols of the src vector. Those per-lane Symbols don't exist in
`names` — vector SSAs were named *once* as a single Symbol. So `_operand`
gets the vector's outer Symbol, which is useless.

### 3.2 Solution — synthesise lane Symbols in pass 1

Add a parallel typed side-table:

```julia
# New in ir_extract.jl — lane naming side table
# Each vector SSA ref maps to a length-N vector of "lane slots". Each slot
# is either a Symbol (SSA lane name) or an IROperand (constant lane).
const LaneSlot = Union{Symbol, IROperand}
const LaneTable = Dict{_LLVMRef, Vector{LaneSlot}}
```

During pass 1, we extend the existing loop to also populate `lane_names` for
vector-typed results:

```julia
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        nm = LLVM.name(inst)
        names[inst.ref] = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        shape = _vector_shape(inst)
        if shape !== nothing
            (N, _W) = shape
            base = names[inst.ref]
            # Allocate N fresh Symbols; these are the SSA names every scalar
            # IRInst that writes into this vector will use as `dest`.
            lane_names[inst.ref] = LaneSlot[
                Symbol("$(base)_lane$(k-1)") for k in 1:N
            ]
        end
    end
end
```

Why this works:
- Pass 1 runs before **any** conversion. By the time pass 2 dispatches on
  `LLVMExtractElement`, the source vector's lane Symbols are guaranteed
  present (assuming the source was named in pass 1 — which is true because
  LLVM SSA dominance guarantees the source instruction precedes the use
  and pass 1 walks all blocks).
- Constant vectors (`ConstantDataVector`, `PoisonValue`, etc.) are **not**
  named in pass 1 (they're not `LLVM.Instruction`s). `_resolve_lane_names`
  (§2.5) handles them on the fly by producing `IROperand`s directly — no
  Symbols needed.

### 3.3 Aliasing: `insertelement` and `shufflevector` rewrite lane slots

When pass 2 converts an `insertelement`, it does NOT emit IRInsts. Instead
it rewrites `lane_names[dest.ref]` to share Symbols with the source:

```julia
# For insertelement dest:
src_lanes = get_lanes_or_const(ops[0])      # scalar or const fill for missing ref
lane_names[inst.ref] = copy(src_lanes)
lane_names[inst.ref][lane_idx + 1] = _operand_to_laneslot(ops[1], names)
```

Here `_operand_to_laneslot(scalar_val, names)` returns:
- `ssa(names[scalar_val.ref]).name` (a Symbol) if the scalar is SSA
- Wrapped `IROperand(:const, Sym(""), v)` if the scalar is a `ConstantInt`

The effect: lane 0 of `%1` (after the insertelement + shufflevector in the
demo) aliases to the Symbol `Symbol("seed::Int8")` — i.e. the function
parameter. No CNOT-copy, no wire allocation.

**Critical**: we're **overwriting** `lane_names[inst.ref]` that pass 1
populated. That's fine — pass 2 converts instructions in order, so by the
time we overwrite, nobody has consumed the pass-1 default yet. For vector
binops / icmps / selects / casts (§2.5–2.8), we *do* use the pass-1-allocated
per-lane Symbols as IRBinOp destinations — those are the ones emitted.

### 3.4 First-pass insertion point — exact diff

In `ir_extract.jl` at `:447`, the pass-1 naming loop. Add `lane_names`
declaration above it and the extra `shape !== nothing` branch inside:

```julia
# BEFORE (:409-452)
names = Dict{_LLVMRef, Symbol}()
args = Tuple{Symbol,Int}[]
ptr_params = Dict{Symbol, Tuple{Symbol, Int}}()
for (i, p) in enumerate(LLVM.parameters(func))
    ...
end
# Name all instructions (first pass)
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        nm = LLVM.name(inst)
        names[inst.ref] = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    end
end

# AFTER
names = Dict{_LLVMRef, Symbol}()
lane_names = LaneTable()           # NEW
args = Tuple{Symbol,Int}[]
ptr_params = Dict{Symbol, Tuple{Symbol, Int}}()
for (i, p) in enumerate(LLVM.parameters(func))
    ...
    # NEW — handle the unlikely case of a vector-typed function parameter
    ptype = LLVM.value_type(p)
    vshape = _vector_shape(p)
    if vshape !== nothing
        error("vector-typed function parameter is not supported " *
              "(param #$i, type $ptype)")
    end
end
# Name all instructions (first pass) — also pre-allocates vector lane Symbols
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        nm = LLVM.name(inst)
        base_sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        names[inst.ref] = base_sym
        vshape = _vector_shape(inst)
        if vshape !== nothing
            (N, _W) = vshape
            lane_names[inst.ref] = LaneSlot[
                Symbol("$(base_sym)_lane$(k-1)") for k in 1:N
            ]
        end
    end
end
```

### 3.5 Pass 1 must NOT eagerly resolve `insertelement` / `shufflevector`

Pass 1 only *allocates* default per-lane Symbols. It does NOT know yet which
instruction is insertelement vs which is add. Pass 2 is where the aliasing
rewrites happen — pass-2-order matches LLVM instruction order, which is
sufficient because LLVM SSA order respects def-before-use.

### 3.6 `_convert_instruction` dispatch plumbing

`_convert_instruction` gains a fifth argument, `lane_names`:

```julia
function _convert_instruction(inst, names, counter, lane_names=LaneTable())
    ...
end
```

Default empty argument keeps all existing call sites working (backward
compat). The module-walker (`_module_to_parsed_ir`) is the one site that
passes the populated `lane_names`.

---

## 4. Edge cases

### 4.1 Variable-lane shufflevector

**LangRef (`#shufflevector-instruction`)**: "The shuffle mask operand is
required to be a constant vector with either constant integer or undef
values." So the mask is *always* a compile-time constant in LLVM IR. We never
need to handle a dynamic mask.

Confirmed by the LLVM 17 C API: `LLVMGetMaskValue` returns a 32-bit int, and
`LLVMGetNumMaskElements` returns a count — both compile-time. No "dynamic
mask" API exists.

### 4.2 Undef / poison lanes in the mask or operands

Policy: **map to `iconst(0)` on the fly.** Never emit an "undef lane" Symbol
without backing. If a downstream scalar op would consume an undef-lane
operand, it silently gets `iconst(0)` — which is safe because UB (§2.11).

### 4.3 Mixed-lane-count operations

**LangRef**: vector binary ops require identical types on both operands —
same N and same M. `icmp`'s operands must match each other; the result is
`<N x i1>` where N matches operand N. `shufflevector` is the one exception:
result `L` may differ from input `N`, but both inputs must be `<N x iM>`
with the same N and M.

We don't need to support mixed-lane-count binary/icmp/select ops — LangRef
forbids them. Add an assertion: when converting a vector binop, assert
`_vector_shape(ops[0]) == _vector_shape(ops[1])` and error loudly with the
mismatch.

### 4.4 Nested vectors

**LangRef**: vector element types must be primitive — integer, float,
pointer, or bfloat. `<N x <M x iK>>` is **illegal**. No nested vectors to
worry about.

### 4.5 Vector load / store

**Out of scope for MVP.** LLVM can emit `load <N x iM>, ptr %p` and
`store <N x iM> %v, ptr %p` — e.g. if a `Vector{Int8}` is passed by pointer
and Julia vectorises the read. The `/tmp/cc07_n16_ir.ll` demo does NOT have
these (only `ret i8`, no vector load/store).

If one appears: error with
`"Vector load/store is not supported (opcode $opc). This pattern arises when Julia passes arrays by reference and LLVM vectorises the access. Workaround: reversible_compile(...; optimize=false) or refactor to pass scalars."`

### 4.6 Width-0 lanes — `<N x i1>`

Key question: how does an i1-vector lane extractelement lower? The icmp
result on IR line 16 has type `<8 x i1>`. Extract (line 49) reads lane 0 as
an `i1` scalar.

Per §2.3 we emit `IRBinOp(dest, :add, ssa(lane0), iconst(0), 1)`. The
`lower.jl` add handler on width-1 integers must work — let's verify: `freeze`
(`ir_extract.jl:1142`) uses the exact same pattern with `_iwidth(src)` which
for an i1 source returns 1. `IRBinOp(..., :add, ..., iconst(0), 1)` lowers to
a CNOT-copy of 1 wire. Confirmed safe (this is exactly how `fcmp` routes its
soft-fcmp i1 result through `IRCast(..., :trunc, ..., w, 1)` at
`ir_extract.jl:1229`).

### 4.7 Lane width 1 with no-op add-0 versus trunc

Alternative to `IRBinOp(:add, iconst(0))`: use `IRCast(:trunc, ..., 1, 1)`.
Both lower to a CNOT-copy. `:add, iconst(0)` is slightly preferred because
`lower.jl` is more likely to fold a zero-add than a self-trunc (the existing
`freeze` handler precedent).

### 4.8 Vector returned from a function

`ret <N x iM> %v`: the return type would be vector. Our extractor at
`:397-405` calls `_type_width(rt)` which crashes on VectorType. **Out of
scope** — extend `_type_width` to handle vector **only** if required by a
real test; the cc0.7 RED does not exercise this (ret i8). Add a descriptive
error message if encountered.

### 4.9 Vector phi

LangRef permits `phi <N x iM>`. **Out of scope for MVP** — not in the cc0.7
RED. If encountered, the vector-type guard in the phi handler (`ir_extract.jl:698`)
would currently route through `_iwidth` and crash; we'd need a
`_lower_vector_phi!` that emits N scalar `IRPhi`s per lane. Low complexity
if/when needed; defer.

### 4.10 Vector `freeze`

`freeze <N x iM>`: the existing handler (`:1142`) calls `_iwidth(src)` which
crashes. Fix: check `_vector_shape(src) !== nothing` and emit N per-lane
`IRBinOp(:add, iconst(0), 1)`. Simple, but add to the implementation only if
a test exercises it (not in N=16 demo).

---

## 5. Out-of-scope — explicit errors

All of these emit fail-loud `error()` per CLAUDE.md §1:

1. **Vector element type non-integer** (FP, ptr): `"Vector element type $et must be an integer (i1/i8/i16/i32/i64) — got $et. Float vectors are not yet supported; SoftFloat dispatch should route scalar floats before vectorisation."`

2. **Dynamic lane index** (`extractelement`/`insertelement` with SSA
   lane-idx): `"Dynamic lane index in $opc is not supported. LLVM typically emits constant lane indices when the vector comes from SLP auto-vectorisation; dynamic indices arise from explicit @llvm.vector.reduce or user-level SIMD intrinsics, which Bennett.jl does not handle."`

3. **Scalable vectors** (`<vscale x N x iM>`): `LLVMScalableVectorTypeKind`
   appears in `libLLVM.jl:486`. Error: `"Scalable vector type $vt is not supported — Bennett.jl requires a fixed lane count."`

4. **Vector load / store** (§4.5): see error message there.

5. **Vector-typed function parameter / return**: §3.4, §4.8.

6. **Vector `phi`** (§4.9).

7. **FP vector ops** (`fadd <N x double>`, `fcmp <N x double>`): error with
   the same "SoftFloat should have dispatched first" message.

8. **Vector bitcast between unequal total widths** or vector↔scalar bitcast
   (§2.8): error. The one case we might regret erroring on is the trivial
   `<N x iM> → <K x iL>` where `N*M == K*L` — it arises in bitcast-heavy
   code. Defer unless a concrete test needs it.

9. **`insertelement` / `shufflevector` where the source vector is not named
   or constant** (defensive): error. In practice this cannot happen — LLVM
   SSA dominance guarantees the source is defined and named.

### 5.1 Justification for erroring on these

CLAUDE.md §1 (fail loud) + §5 (LLVM IR is source of truth): silently
degrading a dynamic-lane extractelement into, say, a MUX-tree would be a
phantom correctness hazard. Better to crash and surface the case as a new bd
issue than ship a subtle miscompile.

---

## 6. Tests beyond the RED test

All five are ≤10-line Julia functions whose LLVM IR (under `optimize=true`)
exercises exactly one vector opcode in isolation. Each test:
1. Asserts `extract_parsed_ir` succeeds.
2. Asserts `verify_reversibility(reversible_compile(...))`.
3. Sweeps representative inputs against the Julia oracle.

### 6.1 `test_cc07_micro_splat.jl` — insertelement + shufflevector broadcast

```julia
function f_splat(x::Int8)::Int8
    t = (x + Int8(1), x + Int8(2), x + Int8(3), x + Int8(4))
    return t[1] + t[2] + t[3] + t[4]
end
```

Expected IR: 4 adds, likely SLP-packed into `<4 x i8>`. Tests
`insertelement` + `shufflevector` broadcast + vector `add` + extractelement.

### 6.2 `test_cc07_micro_veccmp.jl` — vector icmp + extractelement

```julia
function f_veccmp(a::Int8, b::Int8, c::Int8, d::Int8, k::Int8)::Int8
    h1 = (a == k)
    h2 = (b == k)
    h3 = (c == k)
    h4 = (d == k)
    return Int8((h1 | h2) & (h3 | h4))
end
```

Expected IR: 4 icmp eq ops, may pack to `<4 x i8>` compare → `<4 x i1>` →
extractelement.

### 6.3 `test_cc07_micro_vsel.jl` — vector select

```julia
function f_vsel(a::Int8, b::Int8, c::Int8, d::Int8, cond::Bool)::Int8
    x1 = ifelse(cond, a, b)
    x2 = ifelse(cond, c, d)
    return x1 + x2
end
```

Expected IR: 2 selects on `i1` cond over scalars, possibly packed to
`<2 x i8>` select with i1 scalar cond.

### 6.4 `test_cc07_micro_vshift.jl` — vector shift

```julia
function f_vshift(a::Int32, b::Int32, s::Int32)::Int32
    return (a << s) | (b << s)
end
```

Expected IR: two parallel `shl`, candidate for `<2 x i32>` pack.

### 6.5 `test_cc07_micro_vundef.jl` — poison/undef lane survival

```julia
function f_partial(x::Int16, y::Int16)::Int16
    t = (x + Int16(1), y + Int16(2))
    return t[1]   # only lane 0 is read — lane 1 is poison-equivalent at best
end
```

Tests that the undef-lane policy (§2.11) doesn't break when pass-2
extractelement only touches a subset of lanes.

### Notes on micro-test selection

- The RED test itself (`test_cc07_repro.jl`) is the integration test at
  N=16. The micros pin each opcode so a regression isolates the handler.
- Each micro-test's gate count should be **at most** the equivalent
  `optimize=false` gate count for the same Julia function. Pin these as
  BENCHMARKS.md entries once GREEN (CLAUDE.md §6).
- Verify `optimize=true` ≤ `optimize=false` by sanity-checking: under
  vectorisation we should gain (from sroa/mem2reg) and lose nothing (since
  lane expansion produces the same scalar IR the un-vectorised path would).

---

## 7. Concrete diff sketch

Target: `src/ir_extract.jl` only. Line counts approximate.

### 7.1 New helpers (prepend near the top, after `_auto_name`)

```julia
# --- vector lane expansion (cc0.7) ---

const LaneSlot = Union{Symbol, IROperand}
const LaneTable = Dict{_LLVMRef, Vector{LaneSlot}}

"""Return (n_lanes, elem_width) if `val` has LLVM vector type; nothing otherwise."""
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    et isa LLVM.IntegerType ||
        error("Unsupported vector element type $et in $vt " *
              "(only integer lanes are supported)")
    return (LLVM.length(vt), LLVM.width(et))
end

"""
Turn an LLVM value into a length-N vector of LaneSlots. Handles:
  - named SSA vector (lookup in `lane_names`);
  - `ConstantDataVector`, `ConstantVector`;
  - `ConstantAggregateZero`;
  - `PoisonValue`, `UndefValue` — all lanes → iconst(0);
  - broadcast of a scalar SSA (rare, not emitted by LLVM SLP; error loudly
    if encountered to flag a new case).
"""
function _resolve_lane_slots(val::LLVM.Value, N::Int, W::Int,
                              names::Dict{_LLVMRef, Symbol},
                              lane_names::LaneTable)::Vector{LaneSlot}
    if val isa LLVM.ConstantDataVector
        length(val) == N || error("ConstantDataVector length $(length(val)) ≠ expected $N")
        return LaneSlot[_operand(val[k], names) for k in 1:N]
    elseif val isa LLVM.ConstantAggregateZero
        return LaneSlot[iconst(0) for _ in 1:N]
    elseif val isa LLVM.ConstantVector
        ops = LLVM.operands(val)
        length(ops) == N || error("ConstantVector lane count $(length(ops)) ≠ expected $N")
        return LaneSlot[_operand(ops[k], names) for k in 1:N]
    elseif val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        # Undef/poison lanes: map to iconst(0). UB if read; safe to emit.
        return LaneSlot[iconst(0) for _ in 1:N]
    elseif haskey(lane_names, val.ref)
        ls = lane_names[val.ref]
        length(ls) == N ||
            error("Vector SSA %$(val) has $(length(ls)) lanes, expected $N " *
                  "(LLVM type mismatch — should not happen per LangRef)")
        return ls
    else
        error("Cannot resolve lane slots for operand $(string(val)) (type $(LLVM.value_type(val))). " *
              "Expected a named vector SSA, ConstantDataVector, ConstantVector, " *
              "ConstantAggregateZero, UndefValue, or PoisonValue.")
    end
end

"""A lane slot becomes an IROperand: Symbol→ssa, IROperand pass-through."""
_slot_to_operand(s::Symbol) = ssa(s)
_slot_to_operand(o::IROperand) = o
```

### 7.2 First-pass addition — after line `:452`

```julia
# Pre-allocate per-lane Symbols for every vector-typed instruction result.
# Pass 2's vector handlers use these as destination SSA names; pass-1 order
# guarantees they're ready before any consumer looks them up.
lane_names = LaneTable()
for bb in LLVM.blocks(func)
    for inst in LLVM.instructions(bb)
        vshape = _vector_shape(inst)
        vshape === nothing && continue
        (N, _W) = vshape
        base = names[inst.ref]
        lane_names[inst.ref] = LaneSlot[
            Symbol("$(base)_lane$(k-1)") for k in 1:N
        ]
    end
end
```

### 7.3 `_convert_instruction` changes

Augment the signature to accept `lane_names`:

```julia
function _convert_instruction(inst, names, counter, lane_names::LaneTable=LaneTable())
```

Insert the vector-dispatch block **before** the existing binop branch
(`ir_extract.jl:662`):

```julia
# --- vector opcodes (cc0.7) ---
vshape_res = _vector_shape(inst)
# Vector-typed result → dispatch to vector handler, ignoring the scalar branches.
if vshape_res !== nothing
    return _convert_vector_instruction(inst, names, counter, lane_names)
end
```

Then add the new `_convert_vector_instruction` dispatcher (below). It
mirrors the scalar dispatcher but uses lane expansion:

```julia
function _convert_vector_instruction(inst, names, counter, lane_names)
    opc = LLVM.opcode(inst)
    (N, W) = _vector_shape(inst)
    dest_lanes = lane_names[inst.ref]

    # insertelement: pure aliasing — no IR emitted, rewrite lane table.
    if opc == LLVM.API.LLVMInsertElement
        ops = LLVM.operands(inst)
        src_vec, scalar, lane_idx_val = ops[1], ops[2], ops[3]
        lane_idx_val isa LLVM.ConstantInt ||
            error("insertelement with dynamic lane index is not supported")
        k = convert(Int, lane_idx_val)
        0 <= k < N || error("insertelement lane index $k out of range [0, $N)")
        # Start from the source vector's slots (default-allocated in pass 1 if %src
        # is an SSA instruction, or synthesised per §2.10 if it's a constant).
        src_slots = _resolve_lane_slots(src_vec, N, W, names, lane_names)
        # Overwrite dest's lane-0 allocation with the aliased slots.
        new_slots = copy(src_slots)
        new_slots[k + 1] = scalar isa LLVM.ConstantInt ?
            iconst(convert(Int, scalar)) :
            (haskey(names, scalar.ref) ? names[scalar.ref] :
             error("insertelement scalar operand %$(scalar) is not named"))
        lane_names[inst.ref] = new_slots
        return nothing
    end

    # shufflevector: pure aliasing via mask lookup.
    if opc == LLVM.API.LLVMShuffleVector
        ops = LLVM.operands(inst)
        v1, v2 = ops[1], ops[2]
        (N_in, W_in) = _vector_shape(v1)
        _vector_shape(v2) == (N_in, W_in) ||
            error("shufflevector operand shapes mismatch")
        W == W_in ||
            error("shufflevector result element width $W ≠ input $W_in")
        v1_slots = _resolve_lane_slots(v1, N_in, W_in, names, lane_names)
        v2_slots = _resolve_lane_slots(v2, N_in, W_in, names, lane_names)
        L = Int(LLVM.API.LLVMGetNumMaskElements(inst.ref))
        L == N || error("shufflevector mask length $L ≠ result lane count $N")
        new_slots = LaneSlot[]
        for k in 0:(L - 1)
            m = Int(LLVM.API.LLVMGetMaskValue(inst.ref, k))
            if m == -1               # undef lane
                push!(new_slots, iconst(0))
            elseif 0 <= m < N_in
                push!(new_slots, v1_slots[m + 1])
            elseif N_in <= m < 2*N_in
                push!(new_slots, v2_slots[m - N_in + 1])
            else
                error("shufflevector mask index $m out of range [0, $(2*N_in))")
            end
        end
        lane_names[inst.ref] = new_slots
        return nothing
    end

    # Vector binops.
    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        ops = LLVM.operands(inst)
        v1_slots = _resolve_lane_slots(ops[1], N, W, names, lane_names)
        v2_slots = _resolve_lane_slots(ops[2], N, W, names, lane_names)
        out = IRInst[]
        for k in 1:N
            # dest_lanes[k] is always a Symbol at this point (pass 1 allocated it).
            dk = dest_lanes[k]::Symbol
            push!(out, IRBinOp(dk, _opcode_to_sym(opc),
                               _slot_to_operand(v1_slots[k]),
                               _slot_to_operand(v2_slots[k]), W))
        end
        return out
    end

    # Vector udiv/sdiv/urem/srem.
    if opc in (LLVM.API.LLVMUDiv, LLVM.API.LLVMSDiv,
               LLVM.API.LLVMURem, LLVM.API.LLVMSRem)
        opname = opc == LLVM.API.LLVMUDiv ? :udiv :
                 opc == LLVM.API.LLVMSDiv ? :sdiv :
                 opc == LLVM.API.LLVMURem ? :urem : :srem
        ops = LLVM.operands(inst)
        v1_slots = _resolve_lane_slots(ops[1], N, W, names, lane_names)
        v2_slots = _resolve_lane_slots(ops[2], N, W, names, lane_names)
        out = IRInst[]
        for k in 1:N
            dk = dest_lanes[k]::Symbol
            push!(out, IRBinOp(dk, opname,
                               _slot_to_operand(v1_slots[k]),
                               _slot_to_operand(v2_slots[k]), W))
        end
        return out
    end

    # Vector icmp. Note: dest type is <N x i1>; operand width differs.
    if opc == LLVM.API.LLVMICmp
        ops = LLVM.operands(inst)
        (_, op_W) = _vector_shape(ops[1])
        v1_slots = _resolve_lane_slots(ops[1], N, op_W, names, lane_names)
        v2_slots = _resolve_lane_slots(ops[2], N, op_W, names, lane_names)
        pred_sym = _pred_to_sym(LLVM.predicate(inst))
        out = IRInst[]
        for k in 1:N
            dk = dest_lanes[k]::Symbol
            push!(out, IRICmp(dk, pred_sym,
                              _slot_to_operand(v1_slots[k]),
                              _slot_to_operand(v2_slots[k]), op_W))
        end
        return out
    end

    # Vector select. Condition may be scalar i1 or <N x i1>.
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        cond = ops[1]
        cond_shape = _vector_shape(cond)
        cond_slots = if cond_shape === nothing
            # broadcast scalar i1 condition
            nothing
        else
            cond_shape[1] == N ||
                error("vector select cond lane count $(cond_shape[1]) ≠ result $N")
            _resolve_lane_slots(cond, N, 1, names, lane_names)
        end
        v1_slots = _resolve_lane_slots(ops[2], N, W, names, lane_names)
        v2_slots = _resolve_lane_slots(ops[3], N, W, names, lane_names)
        out = IRInst[]
        for k in 1:N
            dk = dest_lanes[k]::Symbol
            c_op = cond_slots === nothing ? _operand(cond, names) :
                   _slot_to_operand(cond_slots[k])
            push!(out, IRSelect(dk, c_op,
                                _slot_to_operand(v1_slots[k]),
                                _slot_to_operand(v2_slots[k]), W))
        end
        return out
    end

    # Vector sext/zext/trunc (lane-wise cast).
    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        src = LLVM.operands(inst)[1]
        (_, from_W) = _vector_shape(src)
        src_slots = _resolve_lane_slots(src, N, from_W, names, lane_names)
        out = IRInst[]
        for k in 1:N
            dk = dest_lanes[k]::Symbol
            push!(out, IRCast(dk, opname, _slot_to_operand(src_slots[k]),
                              from_W, W))
        end
        return out
    end

    # Vector bitcast (same-shape only; cross-shape errors).
    if opc == LLVM.API.LLVMBitCast
        src = LLVM.operands(inst)[1]
        src_shape = _vector_shape(src)
        src_shape === nothing &&
            error("vector-to-scalar bitcast not supported (dest is vector but src is $(LLVM.value_type(src)))")
        src_shape == (N, W) ||
            error("cross-shape vector bitcast not supported: $(src_shape) → ($N, $W)")
        src_slots = _resolve_lane_slots(src, N, W, names, lane_names)
        # Same-shape: alias the lane slots. No gates.
        lane_names[inst.ref] = copy(src_slots)
        return nothing
    end

    error("Unsupported vector LLVM opcode: $opc in instruction: $(string(inst))")
end
```

### 7.4 `extractelement` handler — scalar-typed result, vector source

Placed BEFORE the existing select handler (`:680`) to catch the scalar-
dest/vector-src opcode. It's dispatched by the scalar `_convert_instruction`:

```julia
# cc0.7 — extractelement: scalar result from a vector operand.
if opc == LLVM.API.LLVMExtractElement
    ops = LLVM.operands(inst)
    src_vec, lane_idx_val = ops[1], ops[2]
    (N, W) = _vector_shape(src_vec) === nothing ?
        error("extractelement source is not a vector: $(LLVM.value_type(src_vec))") :
        _vector_shape(src_vec)
    lane_idx_val isa LLVM.ConstantInt ||
        error("extractelement with dynamic lane index is not supported")
    k = convert(Int, lane_idx_val)
    0 <= k < N || error("extractelement lane index $k out of range [0, $N)")
    slots = _resolve_lane_slots(src_vec, N, W, names, lane_names)
    # Emit a trivial add-zero to materialise the scalar as `dest` at width W.
    return IRBinOp(dest, :add, _slot_to_operand(slots[k + 1]), iconst(0), W)
end
```

### 7.5 Call-site wiring

In `_module_to_parsed_ir` at `:485`, pass `lane_names` through:

```julia
# BEFORE
ir_inst = _convert_instruction(inst, names, counter)
# AFTER
ir_inst = _convert_instruction(inst, names, counter, lane_names)
```

### 7.6 Total diff size

| Area | Lines added | Lines changed |
|---|---:|---:|
| New helpers (`_vector_shape`, `_resolve_lane_slots`, `_slot_to_operand`) | ~50 | 0 |
| First-pass lane-symbol allocation | ~12 | 0 |
| `_convert_instruction` signature + dispatch prepend | ~8 | 1 |
| `extractelement` scalar handler | ~20 | 0 |
| `_convert_vector_instruction` (all vector opcodes) | ~150 | 0 |
| Call-site updates | ~2 | 2 |
| **Total** | **~240** | **~3** |

Single file, single atomic commit. Zero touches to `lower.jl`, `ir_types.jl`,
`bennett.jl`, or any test beyond the new microtests.

---

## 8. Gate-count impact prediction

### 8.1 Baselines — what optimize=false gives us for ls_demo_16

From the cc0.7 bd note: "3–50× in gate count" under optimize=false. Precise
number not in prompt. I'll reason structurally.

### 8.2 Structure of the vectorised IR (from `/tmp/cc07_n16_ir.ll`)

After lane expansion at extraction, the scalar IR contains:

| Source IR op | Lane-expanded scalar IRInsts | Gate cost per IRInst (rough) |
|---|---|---|
| 1 × insertelement (line 4) | 0 (pure aliasing) | 0 |
| 1 × shufflevector broadcast (line 5) | 0 (pure aliasing) | 0 |
| 1 × vector add by const (line 6) | 8 × IRBinOp(add) @ i8 | ≈8 × 50 = 400 Toffoli (ripple adder, but: all const-add so much cheaper — probably ~8 × 24 = ~200) |
| 8 × scalar add (lines 7–13) | 8 × IRBinOp(add) @ i8 | Same ≈ 200 |
| 1 × insertelement (line 14) | 0 | 0 |
| 1 × shufflevector (line 15) | 0 | 0 |
| 1 × vector icmp eq (line 16) | 8 × IRICmp @ i8 | ≈8 × 32 = 256 (icmp XOR-reduction; constant may halve) |
| 8 × scalar add (lines 17–40) | 8 × IRBinOp(add) @ i8 | ≈200 |
| 8 × scalar icmp (lines 19–39) | 8 × IRICmp @ i8 | ≈256 |
| 16 × scalar select (lines 41–64) | 16 × IRSelect @ i8 | 16 × 24 ≈ 384 |
| 8 × extractelement (lines 49–63) | 8 × IRBinOp(add, 0) @ i1 | 8 × 1 = 8 CNOT (trivial) |

Rough ceiling: ~1800 Toffoli + some CNOT, but sroa/mem2reg/instcombine should
fold a lot of it (e.g. the two scalar chains of adds compute `seed + const`
repeatedly — instcombine typically CSE's these).

### 8.3 Expected post-fix optimize=true gate count

The structural claim is: **lane expansion produces IR bit-for-bit equivalent
to what `optimize=true` *would* produce if LLVM hadn't SLP-vectorised.** In
other words, post-fix we generate the same scalar IRInsts that the unvec-
torised optimize=true path would generate — maybe slightly more (extra add-0
renames on extractelements), maybe slightly less (constants propagate through
lane aliasing without a CNOT-copy).

Prediction: within 5% of the hypothetical "unvectorised optimize=true" count.
Concretely for ls_demo_16:
- optimize=false cost: call it **G_false**.
- post-fix optimize=true cost: **G_true ≈ G_false / [3–50×]** per the bd
  description of the optimize=false tax. So we expect a **3–50× reduction**
  in gate count for ls_demo_16.
- Fixed overhead from lane expansion: ≈ 8 CNOTs per extractelement = 8 extra
  CNOTs total (negligible).

### 8.4 Regression guarantee for non-vectorised functions

**Invariant**: if a function's IR contains no `LLVM.VectorType` values, the
new code is never entered. Specifically:
- `_vector_shape(inst) === nothing` on every scalar-only instruction →
  the guard at §7.3 skips the vector dispatch.
- `lane_names` is allocated as an empty Dict and never populated.
- `_convert_instruction`'s existing branches fire unchanged.

Therefore: **every existing gate-count baseline is preserved byte-for-byte.**
In particular the `ls_demo_4` / N≤3 corpus (which currently passes with
`optimize=true` because 3 adds doesn't trigger SLP) stays identical. CLAUDE.md
§6 invariants are honoured.

### 8.5 Empirical verification plan (for implementer)

1. Run the N=16 RED test → assert GREEN.
2. Run all tests in `test/` — every `@test gate_count(...) == N` must still
   pass.
3. Run `benchmark/run_benchmarks.jl` → diff against committed baselines; all
   non-N=16 entries must be byte-identical.
4. Print `gate_count` of ls_demo_16 post-fix; compare to the optimize=false
   baseline from the cc0.7 bd note. Expect ≥3× reduction.

---

## 9. Interaction with `lower.jl` — **zero touches**

### 9.1 Invariant

The lane-expansion approach produces scalar `IRBinOp` / `IRICmp` / `IRSelect`
/ `IRCast` nodes **identical in shape** to those `lower.jl` already handles
for scalar Julia code. No new IR type is introduced. The ParsedIR returned to
`lower()` is scalar-only.

### 9.2 Verification

`lower.jl` dispatches on IR node type (via `if inst isa IRBinOp` etc.).
There is no pathway in the design where a vector-typed IR value reaches
`lower.jl`:
- Vector SSAs are never stored in `ParsedIR.blocks[*].instructions` — they
  only live in the extractor-local `lane_names`.
- No new IR node type is introduced.
- `_type_width` is **not** extended for vector types (because vector values
  never appear as operand widths at lowering time).

### 9.3 Why zero touches is the right answer

CLAUDE.md §12 (no duplicated lowering): if we added `IRVectorBinOp` and a
matching `lower_vector_binop!`, that handler would fan out into scalar
`IRBinOp`s internally — duplicating logic already present. Better to fan out
at extraction.

CLAUDE.md §5 (LLVM IR is source of truth): `optimize=true` already gives us
the scalar lane structure; LLVM's SLP is just a packaging of the scalar
operations. Undoing the packaging at the extractor boundary is the narrowest
intervention.

CLAUDE.md §6 (gate-count baselines): zero-touch to `lower.jl` guarantees no
regression on non-vectorised functions (§8.4).

### 9.4 The one exception where `lower.jl` might need attention

If a vector op's lane expansion emits an `IRBinOp(:add, ..., iconst(0), 1)`
for an i1 extractelement, we rely on `lower.jl` handling width-1 add-zero as
a CNOT-copy. This already works (the `freeze` handler `ir_extract.jl:1142`
emits this exact pattern for i1 inputs, confirmed by existing test coverage).
**No new lower.jl code needed**; only a dependency on existing behaviour. If
a future `lower.jl` refactor broke i1 add-zero, the cc0.7 tests would catch
it immediately.

### 9.5 Cascade: downstream modules

`dep_dag.jl`, `liveness.jl`, `diagnostics.jl`, `bennett.jl`, `simulator.jl` —
none see vector IR nodes and none need changes. Lane-expanded scalar IRInsts
have the same `.dest` / `.width` / `.op` fields as hand-written scalar ops,
so all their existing analyses work unchanged.

---

## 10. Implementer checklist

1. **RED confirmed**: run `test/test_cc07_repro.jl` as-is, watch the
   `LLVMInsertElement` error.
2. Add `LaneSlot`, `LaneTable`, `_vector_shape`, `_resolve_lane_slots`,
   `_slot_to_operand` helpers. Verify they don't break anything (run full
   suite — should still pass, because they're unreferenced).
3. Extend pass-1 naming loop with lane-symbol allocation. Run full suite —
   still passes (unreferenced).
4. Thread `lane_names` through `_convert_instruction` signature. Run full
   suite — still passes (default empty arg).
5. Implement `_convert_vector_instruction` and the `extractelement` scalar
   handler. Guard the dispatch at `:662`. Run `test_cc07_repro.jl` → should
   now extract; lowering may still blow up if any scalar IRInst has
   unexpected widths.
6. Debug lowering-side errors, typically by adding more comprehensive error
   messages in `_resolve_lane_slots`.
7. Run `test_cc07_repro.jl` → GREEN.
8. Add micro-tests from §6 (one at a time; each GREEN before the next).
9. Run full test suite (`Pkg.test()`) — every existing test must still pass
   byte-for-byte on gate count.
10. Regenerate `BENCHMARKS.md` — assert byte-identical on all non-cc07
    entries.
11. Update `WORKLOG.md` per CLAUDE.md §0 with:
    - vector opcodes handled vs. deferred
    - `LLVMGetMaskValue` usage note
    - poison/undef policy choice (§2.11)
    - gate-count comparison for ls_demo_16.
12. Commit + push per CLAUDE.md Session Completion protocol.

---

## 11. Summary — why this design

- **Scalar-expansion at the extractor boundary** makes vector ops
  first-class *without* polluting the IR or lowering.
- **Lane Symbols synthesised in pass 1** solves the two-pass naming problem
  with 12 extra lines in the existing loop.
- **`insertelement` / `shufflevector` are pure aliasing** — zero gates, zero
  new IR.
- **`extractelement`, binops, icmp, select, cast** all become N scalar
  IRInsts of a kind `lower.jl` already handles. No `lower.jl` diff.
- **Fail-loud on out-of-scope cases** (dynamic lane idx, FP vectors,
  scalable vectors, vector load/store, vector phi/ret) per CLAUDE.md §1 —
  these are all new bd issues if they arise in practice.
- **Zero-regression on existing baselines** because the vector code path is
  gated behind `_vector_shape(...) !== nothing`, which is false for every
  function that doesn't trigger SLP.
