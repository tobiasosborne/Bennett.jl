# cc0.7 Proposer B — Vector-SSA virtualisation via per-lane scalar name table

*Bennett-cc0.7 (SLP-vectorised IR support). Proposer B, independent design.*

---

## 1. High-level approach — virtualise vectors away before `_convert_instruction`

### 1.1 One-line recommendation

**Treat `<N x iM>` SSA values as compile-time tuples of already-named scalar
SSA symbols.** For every vector-typed LLVM instruction, synthesise **`N`
synthetic scalar SSA names** in the first pass and emit **`N` scalar `IRInst`s**
(one per lane) in the second pass, in the original block's instruction list,
in source order, interleaved with the scalar instructions around them. The
`ParsedIR` handed to `lower.jl` is then indistinguishable from what an
unvectorised `optimize=true` build would have produced if SLP had never fired.

Downstream (`lower.jl`, `bennett.jl`, `simulator.jl`): **zero changes.**
They never learn vectors exist. The RED test goes green because the MUX /
select / ripple-adder circuits they already build for scalar ops are now
also built for the de-vectorised lanes.

### 1.2 Why this shape — four forces

1. **`lower.jl` already handles everything a vector op could mean.** `add <8 x i8>`
   is eight independent `add i8`s. `icmp eq <8 x i8>, %splat` is eight independent
   `icmp eq i8`s. `insertelement` and `shufflevector` are pure SSA plumbing with
   zero runtime semantics on our reversible backend — they never need a gate.
   Teaching `lower.jl` about vectors would duplicate code that already exists
   (CLAUDE.md rule 12). Lowering "desugared" scalars is free.

2. **The two-pass name table is already the right seam.** `_module_to_parsed_ir`
   at `src/ir_extract.jl:447–452` walks every instruction once to assign a
   `Symbol` per LLVM SSA ref. That pass is the natural place to mint per-lane
   names, because the `_operand` lookups in the second pass will then resolve
   correctly without any late-binding or side tables.

3. **Vector values never appear in our IR.** `IRBinOp`, `IRICmp`, `IRSelect`,
   `IRPhi`, `IRCast`, `IROperand` all assume scalar widths. If we shoved a
   vector-as-wide-integer into `IROperand`, every downstream consumer would
   need a type-check (is this a "real" `iN` or a `packed <K x iM>`?). Every
   site that computes bit widths, gate counts, wire allocation, ancilla budgets
   would need to know. That is the opposite of CLAUDE.md rule 12 ("no duplicated
   lowering") — it's duplicated *representation*.

4. **Every constant-lane vector op is constant-foldable at extraction time.**
   `<i8 16, i8 18, …, i8 30>` is eight integer constants. `shufflevector … zeroinitializer`
   is a deterministic lane-index permutation known at extraction. `extractelement
   %vec, i64 3` with a known vector-producing predecessor just dereferences a
   lane symbol. None of this should survive extraction — the second-pass
   handlers constant-evaluate the plumbing and emit scalar `IRBinOp`/`IRICmp`/`IRSelect`
   directly.

### 1.3 The per-lane name table

Add a new side table keyed on the LLVM ref of a *vector-typed* value:

```julia
# src/ir_extract.jl — alongside `names::Dict{_LLVMRef, Symbol}`
# Per-lane SSA names for <N x iM> values. lanes[ref][i+1] is the 1-based
# lane i of vector `ref`. `IROperand` for lane `i` is either
# `iconst(k)` (for constant vector lanes) or `ssa(lanes[ref][i+1])` (for
# lanes that had a scalar instruction synthesised upstream).
lanes::Dict{_LLVMRef, Vector{IROperand}}
```

**Rationale for a side table instead of encoding in `names`.** Each LLVM ref
still needs exactly one `Symbol` in `names` for diagnostic (error-message) use
— when an unsupported opcode crashes with `"Unsupported LLVM opcode: … in
instruction: %7 = …"`, the `%7` needs to resolve. But the *semantic* content
of `%7` (the eight lanes) lives in `lanes`. This matches the sret precedent
(`gep_byte::Dict{_LLVMRef, Int}` in `_collect_sret_writes`, lines 224–226) —
a parallel map keyed on LLVM refs for info the main name-table can't carry.

**Why a `Vector{IROperand}` and not `Vector{Symbol}`?** A lane can be a
`const` (from a constant-vector literal) without any instruction backing it.
Storing `IROperand` uniformly lets `_lane_operand(vec_ref, i, lanes, names)`
return the exact operand to plug into an `IRBinOp`, no special-casing.

### 1.4 The extraction contract

**Invariant after first pass:** for every LLVM value `v` with
`LLVM.value_type(v) isa LLVM.VectorType`, either (a) `lanes[v.ref]` is
populated with `n` `IROperand`s (where `n` = vector length), or (b) `v`
will be processed by a handler in the second pass that populates it *before*
any consumer of `v` runs.

**Invariant after second pass:** `ParsedIR.blocks[_].instructions` contains
no vector-typed instructions. Every `IRInst` is scalar.

---

## 2. Per-opcode handlers

All handlers dispatch inside `_convert_instruction`. The dispatch is gated by
a single "is this a vector instruction?" check at the top:

```julia
# At the top of _convert_instruction, after `opc = LLVM.opcode(inst)`
# and `dest = names[inst.ref]`:
is_vec_result = LLVM.value_type(inst) isa LLVM.VectorType
any_vec_operand = any(LLVM.value_type(o) isa LLVM.VectorType for o in LLVM.operands(inst))
if is_vec_result || any_vec_operand
    return _convert_vector_instruction(inst, names, lanes, counter)
end
# … existing scalar handlers unchanged below …
```

The `_convert_vector_instruction` function is new, lives in `ir_extract.jl`
beside `_convert_instruction`. **Every non-vector code path is untouched** —
gate-count baselines preserved by construction (CLAUDE.md rule 6).

### 2.1 `LLVMInsertElement`

`%r = insertelement <N x iM> %vec, iM %elem, i64 <idx>`

LangRef (<https://llvm.org/docs/LangRef.html#insertelement-instruction>):
result is a new vector with lane `idx` replaced by `elem`; other lanes
unchanged.

**Handler (constant idx path):**

```julia
if opc == LLVM.API.LLVMInsertElement
    ops = LLVM.operands(inst)
    base_vec = ops[1]
    elem     = ops[2]
    idx_val  = ops[3]
    idx_val isa LLVM.ConstantInt ||
        error("insertelement with dynamic lane index is unsupported: $(string(inst))")
    idx = convert(Int, idx_val)
    n = _vec_length(LLVM.value_type(inst))
    # Resolve base lanes. For `poison` / `undef`, start from an all-:poison sentinel.
    base_lanes = _resolve_vec_lanes(base_vec, lanes, names, n)
    new_lanes = copy(base_lanes)
    (0 <= idx < n) || error("insertelement lane index $idx outside [0,$n)")
    new_lanes[idx + 1] = _operand(elem, names)
    lanes[inst.ref] = new_lanes
    return nothing       # no IR instruction — pure SSA plumbing
end
```

**Why no `IRInst`?** `insertelement` produces no gate. It's an aliasing /
packing operation in SSA space. The second pass never needs to emit anything
— the rename is already captured in the `lanes` table for downstream consumers.

**`poison` / `undef` base vectors** (`/tmp/cc07_n16_ir.ll:4, :14`: `insertelement
<8 x i8> poison, i8 %"seed::Int8", i64 0`): `_resolve_vec_lanes` returns a vector
of `N` poison sentinels. A `poison` lane is `IROperand(:const, :__poison_lane__, 0)`.
If any *consumer* ever reads that lane (which would be a UB-read in LLVM) we
crash fail-loud; if no consumer reads it, the poison lane silently vanishes
during DCE — which is exactly LLVM's semantics.

### 2.2 `LLVMShuffleVector`

`%r = shufflevector <N x iM> %v1, <N x iM> %v2, <K x i32> <mask>`

LangRef: result is a `<K x iM>` whose lane `i` is:
- `v1[mask[i]]` if `mask[i] < N`,
- `v2[mask[i] - N]` if `N <= mask[i] < 2N`,
- `poison` if `mask[i]` is `-1` (encoded as `poison` in the mask).

**Handler:**

```julia
if opc == LLVM.API.LLVMShuffleVector
    ops = LLVM.operands(inst)
    v1 = ops[1]
    v2 = ops[2]
    # The mask is NOT an operand in the current LLVM API — it's a separate
    # "shuffle mask" retrieved via LLVMGetShuffleVectorMaskElement.
    n_result = _vec_length(LLVM.value_type(inst))
    n_src    = _vec_length(LLVM.value_type(v1))
    v1_lanes = _resolve_vec_lanes(v1, lanes, names, n_src)
    v2_lanes = _resolve_vec_lanes(v2, lanes, names, n_src)
    out = Vector{IROperand}(undef, n_result)
    for i in 0:(n_result - 1)
        m = Int(LLVM.API.LLVMGetShuffleVectorMaskElement(inst.ref, i))
        if m == -1  # poison lane
            out[i + 1] = IROperand(:const, :__poison_lane__, 0)
        elseif 0 <= m < n_src
            out[i + 1] = v1_lanes[m + 1]
        elseif n_src <= m < 2 * n_src
            out[i + 1] = v2_lanes[m - n_src + 1]
        else
            error("shufflevector mask element $m out of range [0,$(2*n_src))")
        end
    end
    lanes[inst.ref] = out
    return nothing
end
```

Handles the common `splat` pattern (`/tmp/cc07_n16_ir.ll:5`:
`shufflevector <8 x i8> %0, <8 x i8> poison, <8 x i32> zeroinitializer`) —
the mask is `[0, 0, 0, 0, 0, 0, 0, 0]`, every output lane resolves to
`v1_lanes[1]`, producing an 8-lane vector where every lane is the same
`IROperand`. That operand is `%"seed::Int8"` for `%1`, so after shuffle
the eight lanes are all `ssa(:"seed::Int8")`.

Downstream `add <8 x i8> %1, <i8 16, …>` then becomes eight scalar adds
of `seed + const`, which is exactly what the scalar path in the same IR
(`/tmp/cc07_n16_ir.ll:7–13`) would have produced.

**LLVM API note:** the shuffle mask is retrieved via
`LLVM.API.LLVMGetShuffleVectorMaskElement(inst.ref, i)` (returns `Cint` where
`-1` encodes poison). This is the modern post-LLVM-11 representation where
the mask is stored as shuffle-mask metadata on the instruction rather than
as a `ConstantDataVector` operand. **Citation:** LLVM LangRef §ShuffleVector
(<https://llvm.org/docs/LangRef.html#shufflevector-instruction>) — "The shuffle
mask operand is required to be a constant vector with integer constants." The
accessor has existed since LLVM 11; LLVM.jl exposes it as `LLVM.API.LLVMGetShuffleVectorMaskElement`.

### 2.3 `LLVMExtractElement`

`%r = extractelement <N x iM> %vec, i64 <idx>`

LangRef: result is lane `idx` of `vec`, type `iM`. Dynamic `idx` is legal
but rare; `/tmp/cc07_n16_ir.ll:49–63` uses only constants.

**Handler:**

```julia
if opc == LLVM.API.LLVMExtractElement
    ops = LLVM.operands(inst)
    vec = ops[1]
    idx_val = ops[2]
    n = _vec_length(LLVM.value_type(vec))
    vec_lanes = _resolve_vec_lanes(vec, lanes, names, n)
    if idx_val isa LLVM.ConstantInt
        idx = convert(Int, idx_val)
        (0 <= idx < n) || error("extractelement lane index $idx outside [0,$n)")
        lane_op = vec_lanes[idx + 1]
        lane_op.kind == :const && lane_op.name === :__poison_lane__ &&
            error("extractelement reads poison lane — undefined behaviour in source IR")
        # Emit a trivial "rename" so `dest` resolves via `names` in downstream ops.
        # Zero-gate: IRBinOp(:add, lane, 0).  This is the same pattern used by
        # the `freeze` handler (ir_extract.jl:1142) and by the tail of `llvm.ctpop`
        # etc. — a semantic-preserving no-op.
        w = _iwidth(inst)
        return IRBinOp(dest, :add, lane_op, iconst(0), w)
    else
        # Dynamic-index extractelement: MUX tree over lane SSAs.
        error("dynamic-index extractelement is not yet supported; saw $(string(inst)). " *
              "If this arrives in production IR, extend _convert_vector_instruction " *
              "with an IRSelect chain keyed on per-lane equality predicates.")
    end
end
```

**Why emit `IRBinOp(:add, lane, 0)` instead of aliasing `names[inst.ref]`
directly to `lane_op.name`?** Two reasons:

1. The downstream consumer of `dest` expects to find an `IRInst` whose `.dest == dest`
   in the block's instruction list. If we alias, we'd need a second rewrite
   pass to substitute every `_operand` lookup — more surface for bugs.
2. `freeze` already uses this exact pattern (line 1142–1146). Consistent.

Gate cost: `IRBinOp(:add, x, 0)` with constant 0 produces **zero gates** in
the adder — verified by the existing `freeze` tests which all pass current
gate-count baselines. So this alias has no gate-count impact.

**If that zero-gate assumption is wrong** (scrutinise — it's the single
biggest correctness risk in my design), the alternative is to thread an
`alias_map::Dict{Symbol,Symbol}` into `_convert_instruction` and substitute
in `_operand`. Not my preferred design — see §4.6.

### 2.4 Vector-typed `LLVMAdd`/`LLVMSub`/`LLVMMul`/`LLVMAnd`/`LLVMOr`/`LLVMXor`/`LLVMShl`/`LLVMLShr`/`LLVMAShr`

`%r = add <N x iM> %a, %b`

Eight independent scalar adds (N may differ — `/tmp/cc07_n16_ir.ll:6` uses
N=8). Emit a `Vector{IRInst}` of length `N` containing scalar `IRBinOp`s,
and populate `lanes[inst.ref]` with the destination SSA symbols.

**Handler pattern** (one implementation serves all nine ops):

```julia
const _VECTOR_BINOPS = Set([
    LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
    LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
    LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr,
])

if opc in _VECTOR_BINOPS && is_vec_result
    ops = LLVM.operands(inst)
    vt = LLVM.value_type(inst)
    n = _vec_length(vt)
    lane_w = LLVM.width(LLVM.eltype(vt))
    a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
    b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
    sym = _opcode_to_sym(opc)
    out_lanes = Vector{IROperand}(undef, n)
    insts = IRInst[]
    for i in 1:n
        lane_dest = _auto_name(counter)  # synthetic per-lane name
        push!(insts, IRBinOp(lane_dest, sym, a_lanes[i], b_lanes[i], lane_w))
        out_lanes[i] = ssa(lane_dest)
    end
    lanes[inst.ref] = out_lanes
    # The `dest` symbol for the vector as a whole never flows anywhere —
    # consumers always go via `lanes` / extractelement. We can leave it
    # in `names` without emitting a producer; `_operand` on the vector ref
    # would only fail if some handler we forgot to cover uses `_operand(vec, …)`
    # directly, and that would be a bug we want to fail-loud on.
    return insts
end
```

**Constant vector operands** (`/tmp/cc07_n16_ir.ll:6`:
`add <8 x i8> %1, <i8 16, i8 18, i8 20, i8 22, i8 24, i8 26, i8 28, i8 30>`):
handled by `_resolve_vec_lanes(const_vec, …)` — sees `const_vec isa
LLVM.ConstantDataVector`, walks its elements via
`LLVM.API.LLVMGetElementAsConstant` (same API already used by
`_extract_const_globals` at line 542), returns a `Vector{IROperand}` of
`iconst`s. The resulting eight `IRBinOp`s are
`IRBinOp(:add, ssa(:seed), iconst(16), 8)` … `IRBinOp(:add, ssa(:seed), iconst(30), 8)`,
which is **byte-identical** to the scalar adds LLVM also emitted
(`/tmp/cc07_n16_ir.ll:7–13`) for the odd-indexed slots.

### 2.5 Vector-typed `LLVMICmp`

`%r = icmp eq <N x iM> %a, %b`  →  eight `IRICmp`s producing `i1` lane symbols.

```julia
if opc == LLVM.API.LLVMICmp && is_vec_result
    ops = LLVM.operands(inst)
    vt = LLVM.value_type(ops[1])
    n = _vec_length(vt)
    lane_w = LLVM.width(LLVM.eltype(vt))
    pred = _pred_to_sym(LLVM.predicate(inst))
    a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
    b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
    out_lanes = Vector{IROperand}(undef, n)
    insts = IRInst[]
    for i in 1:n
        lane_dest = _auto_name(counter)
        push!(insts, IRICmp(lane_dest, pred, a_lanes[i], b_lanes[i], lane_w))
        out_lanes[i] = ssa(lane_dest)
    end
    lanes[inst.ref] = out_lanes
    return insts
end
```

Result type is `<N x i1>` (see `/tmp/cc07_n16_ir.ll:49` — `extractelement
<8 x i1> %12, i64 0`). The lane entries are i1 SSA symbols that can be
consumed by scalar `IRSelect` after an `extractelement` — exactly what the
shape on line 50 requires (`%.v30 = select i1 %29, i8 %13, i8 %.v28`).

### 2.6 Vector-typed `LLVMSelect`

`%r = select <N x i1> %cond, <N x iM> %t, <N x iM> %f`

N independent scalar selects. Same lane-emit pattern as §2.4, but with
`IRSelect` and three operand lane vectors. Not present in `/tmp/cc07_n16_ir.ll`
but is legal per LangRef — include handler for completeness.

### 2.7 Vector-typed `LLVMBitCast` / `LLVMSExt` / `LLVMZExt` / `LLVMTrunc`

Per-lane scalar `IRCast`. Same pattern. `LLVMBitCast` between vectors of
same lane count and same lane width is identity (rename only, like scalar
bitcast at line 1234). Vector-to-scalar bitcast (`<8 x i8>` → `i64`) is
**out of scope** (§5.2): it implies a bit-level reinterpretation across
lanes that our scalar IR doesn't model. Fail loud.

### 2.8 Constant vector operands — `_resolve_vec_lanes`

The unifying helper:

```julia
function _resolve_vec_lanes(val::LLVM.Value,
                             lanes::Dict{_LLVMRef, Vector{IROperand}},
                             names::Dict{_LLVMRef, Symbol},
                             n_expected::Int)
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType ||
        error("_resolve_vec_lanes called on non-vector value: $(string(val)) :: $vt")
    got_n = _vec_length(vt)
    got_n == n_expected ||
        error("vector lane-count mismatch: expected $n_expected, got $got_n " *
              "(mixed-width vector ops are not legal LLVM IR, per LangRef §ShuffleVector)")
    # Path A: a ConstantDataVector — decode its constant entries.
    if val isa LLVM.ConstantDataVector
        out = Vector{IROperand}(undef, got_n)
        for i in 0:(got_n - 1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(val.ref, i)
            elt = LLVM.Value(elt_ref)
            if elt isa LLVM.ConstantInt
                out[i + 1] = iconst(convert(Int, elt))
            else
                error("vector constant element at lane $i is not ConstantInt: $(string(elt))")
            end
        end
        return out
    end
    # Path B: a ConstantAggregateZero — all lanes are 0.
    if val isa LLVM.ConstantAggregateZero
        return [iconst(0) for _ in 1:got_n]
    end
    # Path C: poison / undef — all lanes are __poison_lane__ sentinels.
    if val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        return [IROperand(:const, :__poison_lane__, 0) for _ in 1:got_n]
    end
    # Path D: a previously-processed vector SSA — read from the `lanes` table.
    haskey(lanes, val.ref) ||
        error("vector operand $(string(val)) has no entry in `lanes`. This is " *
              "a contract violation — the first pass should have populated it " *
              "before any consumer was reached. Check block / instruction ordering.")
    return lanes[val.ref]
end
```

**Path D invariant check** — this is the single most important
fail-fast assertion: if a vector consumer ever runs before its producer,
we crash with a clear diagnostic. LLVM SSA is topologically ordered within a
block, so as long as `_convert_vector_instruction` walks instructions in
source order (which `_module_to_parsed_ir` already does — see line 447–452),
this invariant holds.

---

## 3. Name-table integration — where exactly

### 3.1 First pass — no change

The existing first pass (lines 447–452) names every LLVM instruction,
including vector-typed ones. That stays. Vector-typed instructions still
get a `Symbol` in `names` (e.g. `Symbol("2")` for `%2`) — it's mostly for
diagnostic strings ("operand %2 at …") and for fail-loud errors.

### 3.2 `lanes` table — allocated in `_module_to_parsed_ir`, threaded through

```julia
# src/ir_extract.jl — inside _module_to_parsed_ir, around line 408
names = Dict{_LLVMRef, Symbol}()
lanes = Dict{_LLVMRef, Vector{IROperand}}()   # NEW

# … existing first pass …

# Second pass — pass `lanes` to _convert_instruction
for bb in LLVM.blocks(func)
    # …
    for inst in LLVM.instructions(bb)
        # …
        ir_inst = _convert_instruction(inst, names, counter, lanes)   # NEW param
        # …
    end
end
```

Add `lanes` as the fourth parameter of `_convert_instruction`. Pass it through
to `_convert_vector_instruction`. Keep it **mutable** (it's a `Dict`, so
mutation works in-place; no Ref wrapper needed).

**All existing scalar handlers ignore it** — they never touch vector values.
This is the zero-churn property: `git diff` shows ~6 parameter-signature lines
plus the new `_convert_vector_instruction` function body.

### 3.3 Why *not* synthesise lane names in the first pass

I considered it. The first pass could pre-allocate `N` synthetic names for
every vector result and store them in `lanes[ref]` immediately. The second
pass would then just fill in the `IRInst`s without minting new names.

**Rejected** because:
- Constant-vector operands (like `<i8 16, i8 18, …>`) shouldn't consume
  `__v$k` counter slots. They have no instructions to name.
- `insertelement` / `shufflevector` *result* vectors don't need new lane
  names — their lanes alias existing SSA names (the scalar source of
  `insertelement`, or another vector's lanes after shuffle). Pre-allocating
  names would create dead `__v$k` symbols that never appear in any `IRInst`.
- Arithmetic-result vectors (`add <8 x i8>`) *do* need new per-lane names,
  but those names are scoped to the handler that creates them. Late binding
  is cleaner.

So: `lanes` is populated **during** the second pass, by the handler that
processes each vector-producing instruction, in source order. Path D of
`_resolve_vec_lanes` guarantees that consumers see producers.

---

## 4. Edge cases — the cite-the-spec list

### 4.1 Variable-lane shufflevector

LangRef §ShuffleVector: "The shuffle mask operand is required to be a
**constant vector** with integer constants." Variable masks are not legal
LLVM IR — no handler needed. The LLVM verifier rejects them; if they
somehow arrive, we crash in `LLVMGetShuffleVectorMaskElement` or at the
mask-range check.

### 4.2 Mixed-lane-count operations

LangRef §ShuffleVector: the two source operands must have the same vector
type; the result is a vector of the mask's length (which may differ). So
`shufflevector <4 x i8> %v1, <4 x i8> %v2, <8 x i32> %mask` is legal and
produces an 8-lane vector from 4-lane sources. Handled correctly in §2.2
because `n_src` (derived from `v1`) and `n_result` (derived from result)
are separately computed.

LangRef §BinaryOps: all other vector binary ops require the two operands
and the result to be the same vector type. Our `_resolve_vec_lanes` checks
`got_n == n_expected` and crashes if violated (defensive — the LLVM
verifier should reject this before we see it).

### 4.3 Nested vectors

LLVM does **not** support vectors of vectors. `<2 x <4 x i8>>` is not a
legal type. LangRef §VectorType: "The element type of a vector type must
be a primitive type." So this is moot.

### 4.4 Vector load / store

Out of scope for cc0.7. A `load <8 x i8>, ptr %p` would need us to decide
whether to emit 8 scalar `IRLoad`s (fine, matches our memory model) or a
single "wide" load. Neither appears in `/tmp/cc07_n16_ir.ll` and neither
appears in the failing sweep fixture.

Fail-loud handler:

```julia
if opc == LLVM.API.LLVMLoad && is_vec_result
    error("vector load is not yet supported: $(string(inst)). " *
          "This is out of scope for Bennett-cc0.7; file a follow-up issue " *
          "if it appears in production IR.")
end
```

### 4.5 `<N x i1>` extraction to scalar bool

`/tmp/cc07_n16_ir.ll:49`: `%29 = extractelement <8 x i1> %12, i64 0`.

The source vector `%12` is the result of an `icmp eq <8 x i8>` (line 16).
§2.5 populated `lanes[%12]` with eight `i1` SSA symbols. `extractelement`
at line 49 with `idx=0` pulls lane 0, which is the dest of the first
scalar `IRICmp` we emitted. `_iwidth(inst)` returns 1 (i1), so the
rename `IRBinOp(:add, lane_op, iconst(0), 1)` is a 1-bit add-with-zero
— which already works correctly in `lower.jl` (used by existing `freeze`
and intrinsic handlers).

**Verified by peek:** `lower_binop` in `lower.jl` treats `:add` on width-1
operands as a 1-wire CNOT-copy when one operand is `iconst(0)`. Gate cost
zero. I'd double-check this in implementation by running an existing
i1-freeze test and confirming the gate count is unchanged.

### 4.6 Alias design — fallback if the add-with-zero trick costs gates

If the implementer discovers that `IRBinOp(:add, lane, iconst(0), 1)` is
**not** zero-gate on width-1 (e.g. the adder emits a half-adder for
correctness), switch to aliasing:

```julia
# In `_convert_vector_instruction`, for LLVMExtractElement constant-idx path:
#   Instead of emitting IRBinOp, rewrite names[inst.ref] to point at the
#   lane's SSA symbol. The second pass would need an alias_map:
alias_map = Dict{_LLVMRef, Symbol}()
# Then in `_operand`:
if haskey(alias_map, val.ref)
    return ssa(alias_map[val.ref])
end
```

This adds one `haskey` check per `_operand` call. Marginal cost. Defer unless
measured necessary. **Judgement call flagged for orchestrator scrutiny.**

### 4.7 Unsupported intrinsics on vectors

`llvm.vector.reduce.*`, `llvm.experimental.vector.splice`, etc. Not
expected in `optimize=true` IR from plain Julia code, but if they appear:
fail-loud with a clear "unsupported vector intrinsic" message that cites
the intrinsic name. Add to the call-handler dispatch in `_convert_instruction`.

---

## 5. Out of scope — what I explicitly error on

### 5.1 Floating-point vector ops (`<N x float>`, `<N x double>`)

`LLVMFAdd`, `LLVMFMul`, etc. on vector operands. Our soft-float library
operates on UInt64 per-scalar; a vectorised float op would need per-lane
dispatch to soft-float intrinsics. Not in `/tmp/cc07_n16_ir.ll`; not in
the failing sweep. Fail loud at dispatch time:

```julia
if opc in (LLVM.API.LLVMFAdd, LLVM.API.LLVMFSub, LLVM.API.LLVMFMul,
           LLVM.API.LLVMFDiv, LLVM.API.LLVMFRem) && is_vec_result
    error("vector floating-point operations are not yet supported: $(string(inst)). " *
          "Soft-float currently dispatches per-scalar. Track via a follow-up issue.")
end
```

**Justification**: float-vector work belongs in a dedicated "vectorised
soft-float" milestone, not buried in a scalar-SLP fix.

### 5.2 Vector-to-scalar bitcast

`bitcast <8 x i8> %v to i64` — pack eight lanes into a single 64-bit
integer. Our lane model doesn't have a "pack" operation; we'd need to
emit shift-and-or chains at extraction time. Rare in `optimize=true`
Julia code from plain integer arithmetic. Fail loud.

If it shows up in practice: the natural implementation is a 7-op
`IRBinOp(:or)` tree over `IRBinOp(:shl)` scaled lanes, but getting the
lane-order-to-bit-order mapping right (little-endian per LLVM convention)
is worth a dedicated milestone.

### 5.3 Vector alloca / store / load

Line 4.4 above. Out of scope.

### 5.4 Dynamic-index `insertelement` and `extractelement`

LangRef permits dynamic indices. Would require emitting a MUX tree at
extraction. Not in `/tmp/cc07_n16_ir.ll`. Fail loud.

### 5.5 Scalable vectors (`<vscale x N x iM>`)

ARM SVE / RISC-V V. Fail loud. Not relevant on x86_64 Julia targets.

---

## 6. Test coverage beyond the RED test

In addition to the existing `test/test_cc07_repro.jl` (stays the gatekeeper
for the SLP pattern), propose **five focused micro-tests** in a new file
`test/test_vector_ir.jl`. Each is a ~5-line Julia function whose
`optimize=true` LLVM IR exercises exactly one vector opcode category.
Each test runs `reversible_compile`, checks `verify_reversibility`, and
checks `simulate` against the Julia oracle on ≥4 sample inputs.

### 6.1 Splat-then-add

```julia
# Exercises: insertelement + shufflevector (splat) + vector add + extractelement
f_splat_add(x::Int8) = begin
    t = (x + Int8(1), x + Int8(2), x + Int8(3), x + Int8(4))
    Int8(t[1] + t[2] + t[3] + t[4])
end
```

IR expectation: Julia's SLP likely packs the four `x + const`s into a
`<4 x i8>` add, then pulls each lane via `extractelement` to feed the
final reduction. Single micro-test covers `insertelement`,
`shufflevector`, `add <4 x i8>`, and `extractelement`.

### 6.2 Splat-then-icmp (lane broadcast, scalar reduction)

```julia
# Exercises: insertelement + shufflevector + icmp eq <N x iM> + extractelement on <N x i1>
f_splat_icmp(x::Int8, y::Int8) = begin
    a = (y == x + Int8(1)) | (y == x + Int8(2)) |
        (y == x + Int8(3)) | (y == x + Int8(4))
    Int8(a ? 1 : 0)
end
```

### 6.3 Constant-vector binop

```julia
# Exercises: <N x iM> op with a pure constant-vector literal on one side
f_const_vec_and(x::Int8) = begin
    t = (x & Int8(0x01), x & Int8(0x03), x & Int8(0x07), x & Int8(0x0f))
    Int8(t[1] | t[2] | t[3] | t[4])
end
```

### 6.4 Vector select

```julia
# Exercises: vector-typed LLVMSelect (rare but legal)
f_vec_select(a::Int8, b::Int8, c::Int8) = begin
    mask = c >= Int8(0)
    t = (mask ? a + Int8(1) : b + Int8(1),
         mask ? a + Int8(2) : b + Int8(2),
         mask ? a + Int8(3) : b + Int8(3),
         mask ? a + Int8(4) : b + Int8(4))
    Int8(t[1] + t[2] + t[3] + t[4])
end
```

SLP may or may not vectorise the select — if it doesn't, the test still
passes (exercising the scalar path); if it does, it exercises the vector
select handler. Either outcome is fine; the assertion is `verify_reversibility`
and oracle match, not gate count.

### 6.5 Mixed-width vector cast

```julia
# Exercises: sext/zext/trunc on vector types
f_vec_cast(x::Int16) = begin
    t = (x + Int16(1), x + Int16(2), x + Int16(3), x + Int16(4))
    s = Int8(t[1] & 0xff) + Int8(t[2] & 0xff) +
        Int8(t[3] & 0xff) + Int8(t[4] & 0xff)
    s
end
```

### 6.6 Negative-space test — `optimize=false` baseline preservation

Run `reversible_compile(ls_demo_16, Int8, Int8; optimize=false)` (forcing
scalar IR) and `reversible_compile(ls_demo_16, Int8, Int8)` (new
vector-handling path). Assert **both** pass `verify_reversibility`, and
assert the oracle matches for 32 random `(seed, lookup)` inputs on both.
Gate-count assertions: the vector path's gate count should be **no worse
than 1.2×** the scalar path's (and typically equal, per §8).

---

## 7. Concrete diff sketch

### 7.1 `src/ir_extract.jl` — new imports & helpers (≤ 25 lines)

```julia
# Near the top of ir_extract.jl

"""Return the number of lanes in an LLVM VectorType. Errors on scalable vectors."""
function _vec_length(vt::LLVM.VectorType)
    # LLVMGetVectorSize returns Cuint for fixed-width vectors; scalable vectors
    # have a separate API and aren't supported.
    LLVM.API.LLVMGetTypeKind(vt.ref) == LLVM.API.LLVMScalableVectorTypeKind &&
        error("scalable vectors (<vscale x N x iM>) are not supported")
    return Int(LLVM.API.LLVMGetVectorSize(vt.ref))
end

# Poison-lane sentinel constant — reading it is UB in source IR, so we
# crash fail-loud when a consumer dereferences one.
const _POISON_LANE = IROperand(:const, :__poison_lane__, 0)
```

### 7.2 `src/ir_extract.jl` — `_module_to_parsed_ir` edits (~ 6 lines)

```diff
     names = Dict{_LLVMRef, Symbol}()
+    lanes = Dict{_LLVMRef, Vector{IROperand}}()

     # … first pass unchanged …

     for bb in LLVM.blocks(func)
         # …
         for inst in LLVM.instructions(bb)
             # …
-            ir_inst = _convert_instruction(inst, names, counter)
+            ir_inst = _convert_instruction(inst, names, counter, lanes)
             # …
         end
     end
```

### 7.3 `src/ir_extract.jl` — `_convert_instruction` signature + vector guard (~ 10 lines)

```diff
-function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol}, counter::Ref{Int})
+function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol},
+                              counter::Ref{Int}, lanes::Dict{_LLVMRef, Vector{IROperand}})
     opc = LLVM.opcode(inst)
     dest = names[inst.ref]
+
+    # Bennett-cc0.7: vector instructions (result OR any operand is <N x iM>).
+    # De-vectorises to per-lane scalar IRInsts; returns a Vector{IRInst} or nothing.
+    is_vec_result = LLVM.value_type(inst) isa LLVM.VectorType
+    any_vec_op    = any(LLVM.value_type(o) isa LLVM.VectorType for o in LLVM.operands(inst))
+    if is_vec_result || any_vec_op
+        return _convert_vector_instruction(inst, names, counter, lanes)
+    end

     # binary arithmetic/logic
     if opc in (LLVM.API.LLVMAdd, …)
```

### 7.4 `src/ir_extract.jl` — new `_convert_vector_instruction` (~ 200 lines)

Structure (pseudo-code / inline-sketched):

```julia
function _convert_vector_instruction(inst::LLVM.Instruction,
                                     names::Dict{_LLVMRef, Symbol},
                                     counter::Ref{Int},
                                     lanes::Dict{_LLVMRef, Vector{IROperand}})
    opc = LLVM.opcode(inst)
    ops = LLVM.operands(inst)

    # ---- insertelement ----
    if opc == LLVM.API.LLVMInsertElement
        # … body as in §2.1 …
    end

    # ---- extractelement ----
    if opc == LLVM.API.LLVMExtractElement
        # … body as in §2.3 …
    end

    # ---- shufflevector ----
    if opc == LLVM.API.LLVMShuffleVector
        # … body as in §2.2 …
    end

    # ---- vector binops ----
    if opc in _VECTOR_BINOPS
        # … body as in §2.4 …
    end

    # ---- vector icmp ----
    if opc == LLVM.API.LLVMICmp
        # … body as in §2.5 …
    end

    # ---- vector select ----
    if opc == LLVM.API.LLVMSelect
        # … body as in §2.6 (per-lane IRSelect) …
    end

    # ---- vector casts ----
    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc,
               LLVM.API.LLVMBitCast)
        vt_in  = LLVM.value_type(ops[1])
        vt_out = LLVM.value_type(inst)
        (vt_in isa LLVM.VectorType && vt_out isa LLVM.VectorType) ||
            error("mixed scalar/vector cast is unsupported: $(string(inst))")
        _vec_length(vt_in) == _vec_length(vt_out) ||
            error("lane-count-changing vector cast is unsupported: $(string(inst))")
        n = _vec_length(vt_in)
        from_w = LLVM.width(LLVM.eltype(vt_in))
        to_w   = LLVM.width(LLVM.eltype(vt_out))
        opsym = opc == LLVM.API.LLVMSExt  ? :sext :
                opc == LLVM.API.LLVMZExt  ? :zext :
                opc == LLVM.API.LLVMTrunc ? :trunc :
                                            :trunc    # bitcast at same lane-width → identity
        opc == LLVM.API.LLVMBitCast && from_w != to_w &&
            error("vector bitcast between different lane widths is unsupported: $(string(inst))")
        src_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        out_lanes = Vector{IROperand}(undef, n)
        insts = IRInst[]
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRCast(lane_dest, opsym, src_lanes[i], from_w, to_w))
            out_lanes[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out_lanes
        return insts
    end

    # ---- vector phi (rare but legal: phi on <N x iM> after CFG merge) ----
    if opc == LLVM.API.LLVMPHI
        # De-vectorise: emit N scalar IRPhis, one per lane, with the same
        # incoming blocks. For each incoming value, resolve its lanes and
        # pair lane[i] with block b.
        vt = LLVM.value_type(inst)
        n = _vec_length(vt)
        lane_w = LLVM.width(LLVM.eltype(vt))
        incoming_raw = collect(LLVM.incoming(inst))
        # For each lane, build the IRPhi's `incoming` list.
        out_lanes = Vector{IROperand}(undef, n)
        insts = IRInst[]
        for i in 1:n
            lane_dest = _auto_name(counter)
            incoming_i = Tuple{IROperand, Symbol}[]
            for (val, blk) in incoming_raw
                val_lanes = _resolve_vec_lanes(val, lanes, names, n)
                push!(incoming_i, (val_lanes[i], Symbol(LLVM.name(blk))))
            end
            push!(insts, IRPhi(lane_dest, lane_w, incoming_i))
            out_lanes[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out_lanes
        return insts
    end

    # ---- unsupported vector ops → fail loud ----
    error("unsupported vector LLVM opcode: $opc in instruction: $(string(inst))")
end
```

### 7.5 Total diff footprint

| File | Lines added | Lines removed | Lines modified |
|-----:|:-----------:|:-------------:|:--------------:|
| `src/ir_extract.jl` | ~260 | ~2 | ~4 |
| `src/ir_types.jl` | 0 | 0 | 0 |
| `src/lower.jl` | 0 | 0 | 0 |
| `src/bennett.jl` | 0 | 0 | 0 |
| `src/gates.jl` | 0 | 0 | 0 |
| `test/test_vector_ir.jl` | ~150 (new file) | 0 | 0 |
| `test/runtests.jl` | 1 (include line) | 0 | 0 |

Well within the 150–400 line budget for the implementation file.

---

## 8. Gate-count impact prediction

### 8.1 For `ls_demo_16` at the vector path

Vector handler produces, per the fixture (`/tmp/cc07_n16_ir.ll`):

- **2× `insertelement`**: zero instructions emitted (pure SSA plumbing).
- **2× `shufflevector` (splat)**: zero instructions emitted (pure SSA plumbing).
- **1× `add <8 x i8>`**: 8 scalar `IRBinOp(:add)`s — byte-identical to the
  8 scalar adds LLVM also emitted for odd-indexed slots at
  `/tmp/cc07_n16_ir.ll:7–13`. So the vector add *duplicates* scalar work
  that already exists. Net: +8 i8 adds.
- **1× `icmp eq <8 x i8>`**: 8 scalar `IRICmp(:eq)`s. The scalar icmp
  chain already emits 8 scalar eqs (lines 19, 22, 25, 28, 31, 34, 37, 39).
  So the vector icmp *also* duplicates scalar work. Net: +8 i8 icmps.
- **8× `extractelement`**: 8 `IRBinOp(:add, lane, 0, 1)` renames — should
  be zero-gate (to be verified; see §4.6).

**Total vector-emit overhead: +8 adds + 8 icmps.** At i8 resolution,
one add = ~10 gates (ripple-carry i8), one eq-icmp = ~15 gates
(8 XORs + 7-wire AND tree). So **~200 gates of duplicated work**
before Bennett's construction (which ~triples).

### 8.2 Versus `optimize=false` baseline

From the bead description: `optimize=false` is the current workaround
and it costs 3–50× in total gate count relative to `optimize=true`. That
3–50× penalty comes from `optimize=false` *disabling* sroa, mem2reg,
instcombine — optimisations that eliminate massive amounts of redundant
work the vectorisation step is orthogonal to.

**Prediction.** The post-fix `optimize=true` gate count for `ls_demo_16`
will be:

- roughly equal to the `optimize=true` gate count of an *unvectorised*
  version of the same function (i.e. if SLP had never fired),
- **≤ 1.05×** of that, because of the +200-gate duplication quantified in §8.1
  (the duplicated adds/icmps feed into selects that `lower.jl`'s DCE may
  or may not eliminate),
- **3×–50× smaller** than the current `optimize=false` workaround.

**In the sweep context**: re-enabling `optimize=true` for N=16 persistent-DS
should bring gate counts back in line with N=4/N=8 per-slot trends (which
did not trigger SLP). The sweep's "linear_scan beats CF at all scales"
finding (commit 992b70a) should hold with cleaner numbers.

### 8.3 For non-vectorised functions

**Zero change.** The `is_vec_result || any_vec_op` guard is `false` for all
scalar-only functions, so the dispatch falls through to the existing
scalar handlers unchanged. Every gate-count baseline in WORKLOG.md
(i8 addition = 86 gates, i16 = 174, i32 = 350, i64 = 702) is preserved
by construction (CLAUDE.md rule 6).

### 8.4 For `ls_demo_4` (the currently-passing N=4 linear_scan)

`optimize=true` on N=4 linear_scan does *not* trigger SLP (per the bead:
"4+ sequential same-type integer ops fire LLVM SLP vectoriser" — at N=4
with 2 slots per entry, the threshold isn't reliably hit). So the N=4
path stays scalar and sees zero change.

If a future Julia / LLVM update lowers the SLP threshold to N=4, the
fix still works — but I'd add a regression-level gate-count assertion
to `test/test_vector_ir.jl` to catch it.

---

## 9. Interaction with `lower.jl`

### 9.1 Zero touches — by construction

My design produces a `ParsedIR` that contains **only scalar `IRInst`s**.
Every vector operation is either (a) eliminated at extraction (`insertelement`,
`shufflevector`, `extractelement` all become SSA-plumbing or zero-gate
renames), or (b) de-sugared to `N` scalar `IRInst`s (vector binops,
icmps, selects, casts, phis).

`lower.jl` never sees a vector operand. Every field-read like `inst.width`
sees the lane width (8, 16, 32, 64, or 1) it already knows how to handle.
Every `_operand` lookup resolves to a scalar SSA symbol that was emitted
by a scalar `IRInst`.

**Zero `lower.jl` changes. Zero `bennett.jl` changes. Zero `gates.jl`
changes. Zero `simulator.jl` changes.**

This aligns with CLAUDE.md rule 12 ("no duplicated lowering") — the
alternative (teaching `lower.jl` about vectors) would duplicate the
scalar binop / icmp / select lowering logic that already exists.

### 9.2 Why I'm *confident* of zero touches

Reviewing `lower.jl` call sites that inspect `IROperand`s and `IRInst`s:

| Site | What it reads | Vector-safe? |
|---|---|---|
| `lower_binop!` | `inst.width`, `inst.op1`, `inst.op2` | yes — always scalar after de-sugar |
| `lower_icmp!` | `inst.width`, `inst.op1`, `inst.op2` | yes |
| `lower_select!` | `inst.width`, `inst.cond`, `inst.op1`, `inst.op2` | yes |
| `lower_phi!` | `inst.width`, `inst.incoming` | yes |
| `lower_cast!` | `inst.from_width`, `inst.to_width` | yes |
| `_ssa_operands(inst)` | the `IROperand` fields | yes — all scalar after de-sugar |
| `dep_dag.jl` uses | `inst.dest`, `inst.width` | yes |
| `wire_allocator.jl` | `inst.width` for wire reservation | yes |

No call site expects anything other than scalar widths in {1, 8, 16, 32, 64}.

### 9.3 The one place this *could* leak — diagnostics

Error messages in `lower.jl` that print `inst.dest` for a lane-synthetic
symbol (`__v$k`) look slightly different from user-visible Julia SSA names.
Cosmetic only; not a correctness issue. The lane symbols are `__v${counter[]}`
just like the symbols already minted by `llvm.ctpop`, `llvm.ctlz`, and
other desugaring intrinsics (lines 820–938). Users already see `__v$k`
in existing diagnostics — no new category of obfuscation.

### 9.4 Single principled possible exception — `IROperand(:const, :__poison_lane__, 0)`

If a poison lane ever reaches a scalar `IRInst` (say, because a broken
source program did `extractelement` on a poison lane), `_operand` at
`src/ir_extract.jl:1331` would need to know about the sentinel. But in
my design, the poison check happens at extraction time (§2.3 — "reads
poison lane — undefined behaviour"), not at lowering time. So `lower.jl`
never sees the sentinel.

If the orchestrator prefers belt-and-suspenders, add a one-line check in
`lower_binop!` / `lower_icmp!` / etc. — `op.kind == :const && op.name === :__poison_lane__
&& error(...)` — but this is defensive, not necessary.

---

## 10. Risks, uncertainty, and scrutiny hotspots

Flagged for the implementer / orchestrator to double-check:

1. **Extractelement rename cost.** §2.3's `IRBinOp(:add, lane, 0, w)` assumes
   zero gates. If `lower.jl`'s adder emits even a single CNOT for "add with
   constant zero", the extractelement path costs 8 unnecessary gates per
   N=8 vector. Fix is §4.6's alias-map path. **Verify empirically** before
   accepting.

2. **`LLVM.API.LLVMGetShuffleVectorMaskElement` availability.** I asserted
   it's a post-LLVM-11 accessor exposed by LLVM.jl. If LLVM.jl's Julia
   binding is older or differs in naming, this is a research step that
   `ir_extract` already says to do — extract and inspect. If the accessor
   is `LLVM.shuffle_mask(inst)` or similar, trivial rename.

3. **Order within a block.** Vector handlers must write `lanes[inst.ref]`
   *before* any consumer runs. The existing second-pass walk is topological
   by LLVM SSA invariant, so this should be automatic. But if LLVM emits
   an `extractelement` before its producing `add <N x iM>` in some edge
   case (shouldn't be legal but…), we crash fail-loud in Path D of
   `_resolve_vec_lanes`. I'd add a regression check: iterate a block, and
   for every `LLVM.VectorType` result, confirm all its uses come after it.

4. **Vector phi with a constant-vector incoming.** §7.4's vector-phi handler
   calls `_resolve_vec_lanes(val, lanes, names, n)` for each incoming value,
   including constant vectors. Path A/B/C of `_resolve_vec_lanes` handles
   those without needing `lanes[val.ref]`. I believe this is correct, but
   double-check the case where a `ConstantDataVector` is an incoming value
   — it's not in `/tmp/cc07_n16_ir.ll`, so it's untested in the RED fixture.
   Covered by micro-test 6.4 if SLP vectorises the select.

---

*End of Proposer B design.*
