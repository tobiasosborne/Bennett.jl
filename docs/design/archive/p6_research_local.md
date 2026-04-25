# T5-P6 — Local ground-truth audit: NTuple callee plumbing for `:persistent_tree`

**Bead**: Bennett-z2dj (implementer research step). Labels: `3plus1,core`.
**Date**: 2026-04-21.
**Scope**: illuminate every mechanism in the Bennett.jl pipeline that touches
NTuple-typed function args / returns, to inform a proper fix for
`lower_call!` + `ir_extract`'s sret handling when the `:persistent_tree` arm
needs to emit an `IRCall` to `linear_scan_pmap_set(::NTuple{9,UInt64},
::Int8, ::Int8) :: NTuple{9,UInt64}`.

**Method**: read the source, run Julia to capture actual LLVM IR and actual
error messages, verify nothing by extrapolation. No source edits.

---

## §1 — `IRCall` + `ParsedIR.args` + `ret_elem_widths` data model

### 1.1 `IRCall` definition

**File:** `src/ir_types.jl:111-117`

```julia
struct IRCall <: IRInst
    dest::Symbol
    callee::Function       # Julia function to compile and inline
    args::Vector{IROperand}
    arg_widths::Vector{Int}
    ret_width::Int
end
```

**Semantics:**

- `dest`: SSA name bound to the return value in the caller's `vw` map.
- `callee::Function`: a Julia `Function` value. `lower_call!` (see §2)
  takes this value and **re-invokes `extract_parsed_ir(callee, arg_types)`**
  synthesising `arg_types` from the arg count alone (the bug).
- `args::Vector{IROperand}`: caller-side operand references (SSA or
  `iconst`).
- `arg_widths::Vector{Int}`: caller-side bit width per argument (a flat
  integer, **not** per-element-width aggregate descriptors). E.g. for a
  576-bit NTuple state this would be `[576, 8, 8]`.
- `ret_width::Int`: total return bit width (a single integer, not a list).
  For an `NTuple{9,UInt64}` return this would be `576`.

**Critical field absent**: no callee argument *types* (`Tuple{...}`) carried
here. The only surviving type information is the `callee` function itself —
whose method table `methods(callee)` is where the true Julia signature lives.

### 1.2 `ParsedIR` definition

**File:** `src/ir_types.jl:167-182`

```julia
struct ParsedIR
    ret_width::Int
    args::Vector{Tuple{Symbol, Int}}
    blocks::Vector{IRBasicBlock}
    ret_elem_widths::Vector{Int}   # [8] for i8, [8,8] for [2 x i8]
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}
    memssa::Any
    _instructions_cache::Vector{IRInst}
end
```

- `args::Vector{Tuple{Symbol, Int}}`: one `(name, total_bit_width)` per
  Julia parameter. NTuple args arrive as a single
  `(:state::Tuple, 576)` entry — see §3 param loop and §4 confirmed IR.
- `ret_width::Int`: total return bit width (sum of elements for an
  aggregate return).
- `ret_elem_widths::Vector{Int}`: element-width decomposition. `[8]` for
  scalar `i8`; `[8,8]` for a `Tuple{Int8,Int8}`; `[64,64,64,64,64,64,64,64,64]`
  for an `NTuple{9,UInt64}` return.

### 1.3 How `ret_elem_widths` is populated

**File:** `src/ir_extract.jl:645-657`

```julia
if sret_info !== nothing
    ret_width       = sret_info.n_elems * sret_info.elem_width
    ret_elem_widths = [sret_info.elem_width for _ in 1:sret_info.n_elems]
else
    ft = LLVM.function_type(func)
    rt = LLVM.return_type(ft)
    ret_width = _type_width(rt)
    ret_elem_widths = if rt isa LLVM.ArrayType
        [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
    else
        [ret_width]
    end
end
```

Three sources:
- `sret` path: length `n`, every element = `elem_width` (homogeneous by
  construction — heterogeneous struct returns are rejected at line
  `src/ir_extract.jl:383-387`).
- `LLVM.ArrayType` return (by-value aggregate return, n=2 in practice):
  length and elem width read directly.
- Scalar integer return: single-element vector `[ret_width]`.

### 1.4 Consumers of multi-element `ret_elem_widths`

**File:** `src/simulator.jl:42-55`

```julia
function _read_output(bits, output_wires, elem_widths)
    if length(elem_widths) == 1
        return _read_int(bits, output_wires, 1, elem_widths[1])
    else
        vals = Vector{Int64}(undef, length(elem_widths))
        off = 0
        for (k, ew) in enumerate(elem_widths)
            vals[k] = _read_int(bits, output_wires, off + 1, ew)
            off += ew
        end
        return Tuple(vals)
    end
end
```

The simulator splits the flat `output_wires` vector using `elem_widths` into
a Julia `Tuple`. `test_sret.jl:44-54` exercises `n=8 UInt32` returns — passes
today.

**File:** `src/lower.jl:458`

```julia
lr = LoweringResult(gates, wire_count(wa), input_wires, output_wires,
                     input_widths, parsed.ret_elem_widths, constant_wires,
                     gate_groups)
```

`parsed.ret_elem_widths` is forwarded untouched to `LoweringResult.output_elem_widths`
(field declared at `src/lower.jl:27`), which is forwarded to
`ReversibleCircuit.output_elem_widths` at `src/bennett_transform.jl:14`.

**File:** `src/Bennett.jl:133`

```julia
return ParsedIR(W, new_args, new_blocks, [W for _ in parsed.ret_elem_widths])
```

`_narrow_ir` preserves the length but replaces every element width — OK for
i8→narrow, undefined for multi-word returns narrowed to a non-element-width.
Not called on the `:persistent_tree` path.

### 1.5 Existing multi-element `ret_elem_widths` use

Every path that flows through `ParsedIR → LoweringResult → ReversibleCircuit`
uses multi-element `ret_elem_widths`. Tests verified working:

- `test/test_sret.jl` — up to `n=8 UInt32` sret returns.
- `test/test_tuple.jl` — n=2 by-value aggregate returns (`(b, a)`).
- `test/test_extractvalue.jl` — n=2 aggregate returns + single-element extract.

Empirically confirmed via `julia --project`:

```
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                          optimize=false, preprocess=true)
  # ret_width=576
  # args=[(:state::Tuple, 576), (:k::Int8, 8), (:v::Int8, 8)]
  # ret_elem_widths=[64,64,64,64,64,64,64,64,64]
```

So the downstream pipeline already handles `ret_elem_widths` of length 9.
The blockers are strictly at extraction and `lower_call!`.

---

## §2 — `lower_call!` full mechanics

### 2.1 The function

**File:** `src/lower.jl:1865-1925`

```julia
function lower_call!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                     vw::Dict{Symbol,Vector{Int}}, inst::IRCall;
                     compact::Bool=false)
    # Pre-compile the callee function
    arg_types = Tuple{(UInt64 for _ in inst.args)...}         # [1869]  ← THE BUG
    callee_parsed = extract_parsed_ir(inst.callee, arg_types) # [1870]
    callee_lr = lower(callee_parsed; max_loop_iterations=64)  # [1871]

    if compact
        callee_circuit = bennett(callee_lr)                   # [1876]

        wire_offset = wire_count(wa)
        allocate!(wa, callee_circuit.n_wires)

        for (i, arg_op) in enumerate(inst.args)
            caller_wires = resolve!(gates, wa, vw, arg_op, inst.arg_widths[i])
            w = inst.arg_widths[i]
            callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)  # [1885]
            for bit in 1:w
                callee_wire = callee_circuit.input_wires[callee_start + bit] + wire_offset
                push!(gates, CNOTGate(caller_wires[bit], callee_wire))
            end
        end

        for g in callee_circuit.gates
            push!(gates, _remap_gate(g, wire_offset))
        end

        result_wires = [w + wire_offset for w in callee_circuit.output_wires]
        vw[inst.dest] = result_wires
    else
        # identical shape; uses callee_lr instead of callee_circuit.
        # Code lines 1900-1924.
    end
end
```

### 2.2 The two branches

- `compact=true` (line 1873): applies `bennett()` to the callee —
  forward + copy-out + uncompute — the callee's ancillae are freed and
  only output wires remain live. Used by `reversible_compile(..., compact_calls=true)`.
- `compact=false` (default, line 1900): inlines only the callee's *forward*
  gates. The caller's own Bennett pass handles uncompute. Used by default
  `reversible_compile`.

Both branches share identical arg-wiring and output-wiring shapes; they differ
only in (a) which object (`callee_circuit` vs. `callee_lr`) provides
`input_wires` / `output_wires` / gates, and (b) whether the copy+reverse
prelude/epilogue is inlined along with the forward gates.

### 2.3 Arg wiring contract

Line 1885 — the only place `callee_parsed.args[j][2]` is used:

```julia
callee_start = sum(callee_parsed.args[j][2] for j in 1:(i-1); init=0)
```

This computes the wire offset within the callee's flat `input_wires` array at
which the i-th caller arg should be CNOT-copied. `args[j][2]` is the
callee's `j`-th argument **bit width**. For an `NTuple{9,UInt64}, Int8, Int8`
callee the offsets are `0, 576, 584`.

`inst.arg_widths[i]` is the caller-side bit width (line 1884). If these don't
match `callee_parsed.args[i][2]`, bits overflow or are truncated *silently* —
there's no cross-check. The loop blindly trusts `inst.arg_widths[i]` ==
`callee_parsed.args[i][2]`.

**Observation:** if we do fix `arg_types` at line 1869 so the callee extracts
its real signature, the wiring contract (arg widths match) is naturally
satisfied because the caller (in the new persistent-tree dispatcher arm) will
have computed `arg_widths = [576, 8, 8]` from the same `NTuple{9,UInt64}`
state bundle.

### 2.4 Return wiring contract

Lines 1898 and 1922:

```julia
result_wires = [w + wire_offset for w in callee_circuit.output_wires]  # or callee_lr.output_wires
vw[inst.dest] = result_wires
```

`output_wires` is a flat `Vector{Int}` (confirmed via live probe:
`okasaki_pmap_set` circuit has `length(output_wires)=192`, `output_elem_widths=[64,64,64]`
— the 192 wires carry the 3 slots concatenated). No element-boundary
information flows back through `vw[inst.dest]` — the caller is responsible
for slicing via later GEPs/extracts.

For the `:persistent_tree` arm: the 576-wire result is stored as a single
entry in `vw`. If the caller then does an `extractvalue` to read element i,
`lower_extractvalue!` at `src/lower.jl:1817-1828` slices `arr[offset+1 :
offset+elem_width]` — works uniformly.

### 2.5 Is the hardcoded `UInt64` historical or load-bearing?

**Historical-only.** Every callee currently registered via `register_callee!`
has a method signature that is *exactly* `(UInt64, UInt64, ...) -> UInt64`.
Confirmed via `grep -E '^@?(inline\s+)?function soft_'`:

```
src/softfloat/fmul.jl:14: soft_fmul(a::UInt64, b::UInt64)::UInt64
src/divider.jl:8:         soft_udiv(a::UInt64, b::UInt64)::UInt64
src/divider.jl:27:        soft_urem(a::UInt64, b::UInt64)::UInt64
src/softfloat/fsub.jl:7:  soft_fsub(a::UInt64, b::UInt64)::UInt64
src/softfloat/fadd.jl:16: soft_fadd(a::UInt64, b::UInt64)::UInt64
src/softfloat/fcmp.jl:8:  soft_fcmp_olt(a::UInt64, b::UInt64)::UInt64
src/softfloat/fcmp.jl:57: soft_fcmp_oeq(a::UInt64, b::UInt64)::UInt64
src/softfloat/fround.jl:16:soft_trunc(a::UInt64)::UInt64
src/softfloat/fround.jl:51:soft_floor(a::UInt64)::UInt64
src/softfloat/fround.jl:76:soft_ceil(a::UInt64)::UInt64
src/softfloat/fsqrt.jl:31: soft_fsqrt(a::UInt64)::UInt64
src/softfloat/fma.jl:28:   soft_fma(a::UInt64, b::UInt64, c::UInt64)::UInt64
src/softmem.jl: 14 × soft_mux_{load,store}[_guarded]_NxW(::UInt64...)::UInt64
```

All 44 registered callees (enumerated at `src/Bennett.jl:163-209`) take and
return `UInt64`. This makes `Tuple{(UInt64 for _ in inst.args)...}` an
accurate (though brittle) encoding for the current corpus.

### 2.6 Live reproduction of the bug

```
$ julia --project
using Bennett
using Bennett: IRCall, ssa, iconst, lower_call!, WireAllocator, ReversibleGate
using Bennett: linear_scan_pmap_set, allocate!
inst = IRCall(:res, linear_scan_pmap_set,
              [ssa(:state), ssa(:k), ssa(:v)], [576, 8, 8], 576)
gates = ReversibleGate[]; wa = WireAllocator()
vw = Dict{Symbol,Vector{Int}}()
vw[:state] = allocate!(wa, 576); vw[:k] = allocate!(wa, 8); vw[:v] = allocate!(wa, 8)
lower_call!(gates, wa, vw, inst)
# → ERROR: "no unique matching method found for the specified argument types"
```

The method lookup `linear_scan_pmap_set(::UInt64, ::UInt64, ::UInt64)` fails
because the real method is `linear_scan_pmap_set(::NTuple{9,UInt64}, ::Int8, ::Int8)`
(verified via `methods(linear_scan_pmap_set)`, one method only).

### 2.7 Every call site of `lower_call!`

Internal emitters (widths always `[64, 64, 64]` or `[64, 64, 64, 64]`):

| Site | Callee | Arg widths | Ret width |
|---|---|---|---|
| `src/lower.jl:1469` | `soft_udiv` / `soft_urem` | `[64, 64]` | `64` |
| `src/lower.jl:1765-1767` | `soft_mux_load_4x8` | `[64, 64]` | `64` |
| `src/lower.jl:1790-1792` | `soft_mux_load_8x8` | `[64, 64]` | `64` |
| `src/lower.jl:2408-2417` | `soft_mux_store_4x8` / `_guarded_4x8` | `[64, 64, 64]` / `[64,64,64,64]` | `64` |
| `src/lower.jl:2443-2452` | `soft_mux_store_8x8` / `_guarded_8x8` | `[64, 64, 64]` / `[64,64,64,64]` | `64` |
| `src/lower.jl:2494-2535` (eval'd) | `soft_mux_{load,store}_{2x8,2x16,4x16,2x32}` | all 64-bit scalars | `64` |

External emitters (from `ir_extract.jl` — dispatched at
`src/lower.jl:160-161` via `_lower_inst!` on `IRCall`):

| Site | Callee | Notes |
|---|---|---|
| `src/ir_extract.jl:1351` | Any `_lookup_callee` hit (soft_*, user-registered) | widths from `LLVM.width(ot)` per int operand |
| `src/ir_extract.jl:1447,1455` | `soft_fptosi` | single `[src_w]` → `dst_w`, often `[64] → 64` |
| `src/ir_extract.jl:1472,1479` | `soft_sitofp` | single `[src_w]` → `64` |
| `src/ir_extract.jl:1520` | `soft_fcmp_{olt,oeq,ole,une}` | `[w, w] → w` (then trunc to i1) |

Every single call site passes scalar UInt64-shaped args. The hardcoded
`arg_types = Tuple{(UInt64 for _ in inst.args)...}` is therefore correct
*by coincidence of the currently registered callee corpus*, not by design.

**Upshot:** fixing line 1869 to derive the real callee signature (via
`methods(inst.callee)`, or an explicit type list carried on `IRCall`) is
**strictly additive** for current consumers — every existing callee has
all-UInt64 args so the old and new computation agree.

---

## §3 — `extract_parsed_ir` and sret handling

### 3.1 Entry point

**File:** `src/ir_extract.jl:41-81`

```julia
function extract_parsed_ir(f, arg_types::Type{<:Tuple};
                           optimize::Bool=true,
                           preprocess::Bool=false,
                           passes::Union{Nothing,Vector{String}}=nothing,
                           use_memory_ssa::Bool=false)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))
    # ...
    effective_passes = String[]
    if preprocess
        append!(effective_passes, DEFAULT_PREPROCESSING_PASSES)  # sroa,mem2reg,simplifycfg,instcombine
    end
    if passes !== nothing
        append!(effective_passes, passes)
    end

    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        if !isempty(effective_passes)
            _run_passes!(mod, effective_passes)
        end
        result = _module_to_parsed_ir(mod)
        dispose(mod)
    end
    # ...
end
```

`DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg", "instcombine"]`
(line 23). `preprocess=false` by default; `optimize=true` by default.

### 3.2 `_detect_sret`

**File:** `src/ir_extract.jl:370-404`

```julia
function _detect_sret(func::LLVM.Function)
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    found = nothing
    for (i, p) in enumerate(LLVM.parameters(func))
        attr = LLVM.API.LLVMGetEnumAttributeAtIndex(func, UInt32(i), kind_sret)
        attr == C_NULL && continue
        fname = LLVM.name(func)
        if found !== nothing
            error("ir_extract.jl: function @$fname has multiple sret parameters ...")
        end
        ty = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(attr))
        ty isa LLVM.ArrayType || error(
            "ir_extract.jl: sret pointee is $ty in @$fname; only [N x iM] " *
            "aggregates are supported ...")
        et = LLVM.eltype(ty)
        et isa LLVM.IntegerType || error(
            "ir_extract.jl: sret aggregate element type $et in @$fname is not " *
            "an integer ...")
        w = LLVM.width(et)
        w ∈ (8, 16, 32, 64) || error(
            "ir_extract.jl: sret element width $w in @$fname is not in " *
            "{8,16,32,64}; got aggregate $ty")
        n = LLVM.length(ty)
        elem_bytes = w ÷ 8
        found = (param_index = i, param_ref = p.ref, agg_type = ty,
                 n_elems = n, elem_width = w,
                 elem_byte_size = elem_bytes,
                 agg_byte_size = n * elem_bytes)
    end
    return found
end
```

Returns a NamedTuple or `nothing`. Enforced constraints:
- exactly one sret param per function (fail-loud otherwise)
- pointee must be `[N x iM]` (homogeneous array; heterogeneous structs like
  `Tuple{UInt32,UInt64}` are explicitly rejected — see `test/test_sret.jl:119-123`)
- element type must be `LLVM.IntegerType`
- element width ∈ {8, 16, 32, 64}

The `NTuple{9,UInt64}` return case satisfies all constraints — agg type is
`[9 x i64]`, elem width 64 ∈ {8,16,32,64}.

### 3.3 `_collect_sret_writes`

**File:** `src/ir_extract.jl:430-553`

Classifies every instruction touching the sret pointer:

| Pattern | Classification |
|---|---|
| `store iM %v, ptr %sret_return` (byte offset 0) | slot 0 |
| `store iM %v, ptr %gep_sret_byte_K` (K = i·elem_byte_size) | slot i |
| `%gep = getelementptr inbounds i8, ptr %sret_return, i64 K` | consumed (tracked in gep_byte map) |
| `%gep = getelementptr inbounds [N x iM], ptr %sret_return, i64 i` | consumed |
| `llvm.memcpy(ptr %sret_return, ptr %source, i64 72, i1 false)` | **rejected** (line 453) |
| dynamic-offset GEP | **rejected** (line 480-482) |
| `store <N x iM>` (vector store into sret GEP) | **rejected** (line 518-520) |
| store width ≠ elem width | **rejected** (line 522-525) |
| misaligned byte offset | **rejected** (line 526-528) |
| duplicate store to same slot | **rejected** (line 532-535) |
| slot never written | **rejected** (line 548) |

### 3.4 Exact VectorType rejection site

**File:** `src/ir_extract.jl:517-520`

```julia
vt = LLVM.value_type(val)
vt isa LLVM.IntegerType || _ir_error(inst,
    "sret store at byte offset $byte_off has non-integer value " *
    "type $vt; only integer stores are supported")
```

Exact error message fires for `store <4 x i64> %19, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx"`
— verified locally by running:

```
$ julia --project -e '
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8})
'
# → ir_extract.jl: store in @julia_g_1741:%top:   store <4 x i64> %19,
#   ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8 —
#   sret store at byte offset 8 has non-integer value type
#   LLVM.VectorType(<4 x i64>); only integer stores are supported
```

### 3.5 Exact memcpy rejection site

**File:** `src/ir_extract.jl:445-461`

```julia
if opc == LLVM.API.LLVMCall
    ops = LLVM.operands(inst)
    n_ops = length(ops)
    if n_ops >= 1
        cname = try LLVM.name(ops[n_ops]) catch; "" end
        if startswith(cname, "llvm.memcpy")
            if n_ops >= 2 && ops[1].ref === sret_ref
                _ir_error(inst,
                    "sret with llvm.memcpy form is not supported " *
                    "(emitted under optimize=false). Re-compile with " *
                    "optimize=true (Bennett.jl default) or set " *
                    "preprocess=true to canonicalise via SROA/mem2reg.")
            end
        end
    end
end
```

Fires under `optimize=false`. Verified via:

```
$ julia --project -e '
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false)
'
# → ir_extract.jl: call in @julia_g_2169:%L86:   call void
#   @llvm.memcpy.p0.p0.i64(ptr align 8 %sret_return, ptr align 8 %"new::Tuple",
#   i64 72, i1 false) — sret with llvm.memcpy form is not supported
#   (emitted under optimize=false). Re-compile with optimize=true
#   (Bennett.jl default) or set preprocess=true to canonicalise via SROA/mem2reg.
```

### 3.6 `_synthesize_sret_chain`

**File:** `src/ir_extract.jl:563-578`

```julia
function _synthesize_sret_chain(sret_info, slot_values::Dict{Int, IROperand},
                                counter::Ref{Int})
    n  = sret_info.n_elems
    ew = sret_info.elem_width
    chain = IRInst[]
    agg_op = IROperand(:const, :__zero_agg__, 0)
    last_dest = Symbol("")
    for k in 0:(n - 1)
        dest = _auto_name(counter)
        push!(chain, IRInsertValue(dest, agg_op, slot_values[k], k, ew, n))
        agg_op = ssa(dest)
        last_dest = dest
    end
    ret_inst = IRRet(ssa(last_dest), n * ew)
    return (chain, ret_inst)
end
```

Emits a chain of `IRInsertValue(dest_k, agg_op, slot_values[k], k, ew, n)`
followed by `IRRet` — downstream lowering (`lower_insertvalue!` at
`src/lower.jl:1830-1853`) handles this shape uniformly.

### 3.7 Integration into main walker

**File:** `src/ir_extract.jl:708-737`

```julia
sret_writes = sret_info === nothing ? nothing :
              _collect_sret_writes(func, sret_info, names)

blocks = IRBasicBlock[]
for bb in LLVM.blocks(func)
    label = Symbol(LLVM.name(bb))
    insts = IRInst[]
    terminator = nothing

    for inst in LLVM.instructions(bb)
        if sret_writes !== nothing && inst.ref in sret_writes.suppressed
            continue
        end
        if sret_writes !== nothing &&
           LLVM.opcode(inst) == LLVM.API.LLVMRet &&
           isempty(LLVM.operands(inst))
            chain, ret_inst = _synthesize_sret_chain(
                sret_info, sret_writes.slot_values, counter)
            append!(insts, chain)
            terminator = ret_inst
            continue
        end
        # ... normal conversion
    end
end
```

The synthesised `IRInsertValue` chain + `IRRet` is emitted at the `ret void`
terminator of the block that contains it. For single-block returning
functions (both linear_scan `optimize=true` and post-SROA `optimize=false`
variants), this is the entry block.

### 3.8 Pointer param ("NTuple by ref") handling

**File:** `src/ir_extract.jl:669-698`

```julia
for (i, p) in enumerate(LLVM.parameters(func))
    nm = LLVM.name(p)
    sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    names[p.ref] = sym
    if sret_info !== nothing && i == sret_info.param_index
        continue  # sret param is output buffer, not input
    end
    ptype = LLVM.value_type(p)
    if ptype isa LLVM.IntegerType
        push!(args, (sym, LLVM.width(ptype)))
    elseif ptype isa LLVM.FloatingPointType
        push!(args, (sym, _type_width(ptype)))
    elseif ptype isa LLVM.PointerType
        deref = _get_deref_bytes(func, p)  # reads `dereferenceable(N)` attribute
        if deref > 0
            w = deref * 8
            push!(args, (sym, w))
            ptr_params[sym] = (sym, deref)
        end
    end
end
```

`NTuple{9,UInt64}` arrives as a pointer param with `dereferenceable(72)`. The
walker treats it as a 576-bit flat wire array. This is why
`extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false,
preprocess=true)` produces `args=[(:state::Tuple, 576), (:k::Int8, 8),
(:v::Int8, 8)]`.

### 3.9 `insertvalue` / `extractvalue` handling

**File:** `src/ir_extract.jl:1028-1052`

```julia
# extractvalue — select one element from an aggregate
if opc == LLVM.API.LLVMExtractValue
    ops = LLVM.operands(inst)
    agg_val = ops[1]
    idx_ptr = LLVM.API.LLVMGetIndices(inst)
    idx = unsafe_load(idx_ptr)  # 0-based
    agg_type = LLVM.value_type(agg_val)
    ew = LLVM.width(LLVM.eltype(agg_type))
    ne = LLVM.length(agg_type)
    return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
end

# insertvalue
if opc == LLVM.API.LLVMInsertValue
    # ... identical shape
    return IRInsertValue(dest, _operand(agg_val, names),
                         _operand(elem_val, names), idx, ew, ne)
end
```

Both work on homogeneous `[N x iM]` aggregates. Lowering at
`src/lower.jl:1817-1853`:

- `lower_extractvalue!`: `n_elems × elem_width` flat wire array, slices
  `[offset+1 : offset+elem_width]` out via CNOT-copy (W gates per extract).
- `lower_insertvalue!`: copies the aggregate, replacing element at `index`
  (`total_w` CNOTs).

For the NTuple-return callee, `_synthesize_sret_chain` emits one
`IRInsertValue(dest_k, agg, slot[k], k, 64, 9)` per slot — same shape as n=2
by-value aggregates, same lowering.

---

## §4 — What IR does Julia actually emit for `NTuple{9,UInt64}` returns?

All IR excerpts below captured locally via `julia --project` with the stated
flags. Files saved at `/tmp/g_opt.ll`, `/tmp/g_noopt.ll`,
`/tmp/g_noopt_sroa.ll`, `/tmp/lsdemo.ll`.

### 4.1 The blocker: `optimize=true` (default) — vectorized SROA stores

**Function signature:**
```
define void @julia_g_190(
    ptr noalias nocapture noundef nonnull sret([9 x i64]) align 8 dereferenceable(72) %sret_return,
    ptr nocapture noundef nonnull readonly align 8 dereferenceable(72) %"state::Tuple",
    i8 signext %"k::Int8",
    i8 signext %"v::Int8") #0 {
```

Four parameters:
1. `sret_return :: ptr sret([9 x i64])` — output buffer, deref=72.
2. `"state::Tuple" :: ptr` — input state, deref=72.
3. `"k::Int8" :: i8`
4. `"v::Int8" :: i8`

**Store pattern (the bug source):**

```
  store i64 %2, ptr %sret_return, align 8                                         ; slot 0, offset 0  OK
  %"new::Tuple.sroa.2.0.sret_return.sroa_idx" = getelementptr inbounds i8, ptr %sret_return, i64 8
  %18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr", align 8                         ; <4 x i64> load
  %19 = select <4 x i1> %17, <4 x i64> %6, <4 x i64> %18
  store <4 x i64> %19, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8     ; slots 1-4, OFFSET 8 — FAILS
  %"new::Tuple.sroa.6.0.sret_return.sroa_idx" = getelementptr inbounds i8, ptr %sret_return, i64 40
  store i64 %8, ptr %"new::Tuple.sroa.6.0.sret_return.sroa_idx", align 8            ; slot 5, offset 40
  ...
  store i64 %13, ptr %"new::Tuple.sroa.9.0.sret_return.sroa_idx", align 8           ; slot 8, offset 64
  ret void
```

**Critical shape (bit-exact from `/tmp/g_opt.ll:38-54`):** Julia/LLVM's SROA
splits the `[9 x i64]` aggregate such that the middle four slots (indices
1,2,3,4 → bytes 8,16,24,32) are written as a **single `<4 x i64>` vector
store**. Slots 0, 5, 6, 7, 8 are clean `i64` stores at offsets 0, 40, 48, 56,
64. So the aggregate is written by 1 + 1 + 4 = 6 slot-worth of stores but
physically only 6 store instructions (1 scalar + 1 vector + 4 scalar).

**Why SROA picks 4-element blocks:** The ifelse pattern
```
k1 = _ls_pick(0, target, k_u, s[2])
v1 = _ls_pick(0, target, v_u, s[3])
k2 = _ls_pick(1, target, k_u, s[4])
v2 = _ls_pick(1, target, v_u, s[5])
```
is 4 consecutive same-predicate selects, which SLP vectorizes into
`<4 x i64>`. Slot 0 (count) is independent. Slots 5-8 (k3,v3,k4,v4) have
different predicates and are not vectorized.

### 4.2 The other blocker: `optimize=false` — memcpy form

**File:** `/tmp/g_noopt.ll:12-209`

```
top:
  %"new::Tuple" = alloca [9 x i64], align 8
  ; ... many blocks (L15, L16, ..., L84) doing per-slot ifelse+select via branches
L84:
  %23 = getelementptr inbounds i8, ptr %"new::Tuple", i32 0
  store i64 %4, ptr %23, align 8                                    ; into local alloca
  ... eight more i64 stores into %"new::Tuple" at offsets 0,8,...,64
  br label %L86

L86:
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sret_return, ptr align 8 %"new::Tuple", i64 72, i1 false)
  ret void
```

Julia builds an `alloca [9 x i64]`, stores into it per-slot, then `memcpy`s
the whole thing to the sret buffer. `_collect_sret_writes` sees the memcpy,
identifies the destination as `%sret_return`, and errors at
`ir_extract.jl:453-457`.

### 4.3 Workaround: `optimize=false, preprocess=true`

Running `preprocess=true` on `optimize=false` IR applies SROA — which
promotes the `%"new::Tuple"` alloca, inlines the per-slot stores directly
into `%sret_return`, and eliminates the memcpy. Post-pass IR at
`/tmp/g_noopt_sroa.ll:49-66`:

```
  store i64 %14, ptr %sret_return, align 8                           ; slot 0
  %"new::Tuple.sroa.2.0.sret_return.sroa_idx" = getelementptr inbounds i8, ptr %sret_return, i64 8
  store i64 %11, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8   ; slot 1
  ... seven more i64 stores at offsets 16, 24, 32, 40, 48, 56, 64
  ret void
```

All nine stores are `i64` — the existing sret pre-walk handles them.
Confirmed locally:

```
$ julia --project -e '
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
pir = Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8}; optimize=false, preprocess=true)
println(pir.args); println(pir.ret_elem_widths)
'
# args=[(:state::Tuple, 576), (:k::Int8, 8), (:v::Int8, 8)]
# ret_elem_widths=[64, 64, 64, 64, 64, 64, 64, 64, 64]
```

### 4.4 Contrast: Okasaki `NTuple{3, UInt64}` works out-of-the-box

`okasaki_pmap_set(::OkasakiState, ::Int8, ::Int8) :: OkasakiState` with
`OkasakiState == NTuple{3, UInt64}` extracts cleanly under default
`optimize=true`:

```
$ julia --project -e '
using Bennett
h(s::Bennett.OkasakiState, k::Int8, v::Int8) = Bennett.okasaki_pmap_set(s, k, v)
pir = Bennett.extract_parsed_ir(h, Tuple{Bennett.OkasakiState, Int8, Int8})
println(pir.args); println(pir.ret_elem_widths)
'
# args=[(:s::Tuple, 192), (:k::Int8, 8), (:v::Int8, 8)]
# ret_elem_widths=[64, 64, 64]
```

IR inspection (function body, truncated) shows **0 vector stores**:

```
define void @julia_h_190(ptr sret([3 x i64]) ... %sret_return,
                          ptr ... %"s::Tuple", i8 ..., i8 ...) {
top:
  ; ... arithmetic ...
  ; three clean i64 stores into %sret_return at offsets 0, 8, 16
  ret void
}
```

SLP doesn't kick in for n=3 because there's no 2^k-sized consecutive
same-predicate select chain. The linear_scan case is specifically tripped by
Julia emitting 4 consecutive selects for `k1,v1,k2,v2` that pattern-match
SLP.

### 4.5 Confirmation: `_ls_demo` works because NTuple never crosses ABI

**File:** `test/test_persistent_interface.jl:18-25`

```julia
function _ls_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                  k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.linear_scan_pmap_new()
    s = Bennett.linear_scan_pmap_set(s, k1, v1)
    s = Bennett.linear_scan_pmap_set(s, k2, v2)
    s = Bennett.linear_scan_pmap_set(s, k3, v3)
    return Bennett.linear_scan_pmap_get(s, lookup)
end
```

All args and return are `Int8`. Generated LLVM IR (`/tmp/lsdemo.ll:8-18`):

```
define i8 @julia__ls_demo_229(i8 signext %"k1::Int8", i8 signext %"v1::Int8",
                               i8 signext %"k2::Int8", i8 signext %"v2::Int8",
                               i8 signext %"k3::Int8", i8 signext %"v3::Int8",
                               i8 signext %"lookup::Int8") #0 {
L159:
  %.not4 = icmp eq i8 %"k3::Int8", %"lookup::Int8"
  %.not3 = icmp eq i8 %"k2::Int8", %"lookup::Int8"
  %.not = icmp eq i8 %"k1::Int8", %"lookup::Int8"
  %narrow = select i1 %.not, i8 %"v1::Int8", i8 0
  %.v = select i1 %.not3, i8 %"v2::Int8", i8 %narrow
  %.v5 = select i1 %.not4, i8 %"v3::Int8", i8 %.v
  ret i8 %.v5
}
```

Julia's inliner + constant prop eliminates the NTuple state entirely — every
`pmap_new`/`pmap_set`/`pmap_get` is inlined, slot assignments are SSA-value
assignments, and the final compiled IR is a 6-line chain of i8 selects. No
sret. No `<N x iM>` stores. No call. This is why the existing
`test_persistent_interface.jl` tests pass while the proposed
`:persistent_tree` arm (which emits an *actual* IRCall to
`linear_scan_pmap_set`) does not.

---

## §5 — Multi-language `.ll` / `.bc` ingest

### 5.1 Entry points

**File:** `src/ir_extract.jl:111-191`

```julia
function extract_parsed_ir_from_ll(path::AbstractString;
                                    entry_function::AbstractString, ...)
    ir_string = read(path, String)
    ...
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        try
            result = _extract_from_module(mod, entry_function, effective_passes)
        ...
    end
    return result
end

function extract_parsed_ir_from_bc(path::AbstractString;
                                    entry_function::AbstractString, ...)
    ...
    LLVM.Context() do _ctx
        @dispose membuf = LLVM.MemoryBufferFile(String(path)) begin
            mod = parse(LLVM.Module, membuf)
            try
                result = _extract_from_module(mod, entry_function, effective_passes)
            ...
        end
    end
    return result
end
```

Both funnel into `_extract_from_module` → `_module_to_parsed_ir(mod; entry_function=...)`
→ `_module_to_parsed_ir_on_func` (line 632) — the same core walker used by
the Julia-function path.

### 5.2 Derivation of arg types without a Julia method

These paths do **not** need a Julia method signature; `_module_to_parsed_ir_on_func`
reads types directly from `LLVM.value_type(p)` (param), `LLVM.return_type(ft)`
(return), and `_detect_sret(func)` (sret attribute). The sret-param attribute
carries the pointee type via `LLVMGetTypeAttributeValue(attr)`
(`src/ir_extract.jl:382`). This is how the sret synthesised chain works on
raw .ll input without ever calling `methods()`.

### 5.3 Aggregate args / returns on the generic path

Aggregate returns are handled uniformly (sret attribute or `LLVM.ArrayType`
return) — same mechanism as the Julia path.

Aggregate args via `dereferenceable(N)` on pointer params are also handled
uniformly (line 689, `_get_deref_bytes`).

Non-homogeneous struct returns ({i32, i64}) are not supported on either
path — same `_detect_sret` rejection.

### 5.4 Lessons for callee type recovery

If we eventually carry explicit arg *types* on `IRCall` (not just widths),
the `from_ll` / `from_bc` paths are the natural stress test — they construct
callees outside the Julia method table. Any fix in `lower_call!` that
assumes `methods(inst.callee)` works will need a fallback for these paths.

**But:** `_lookup_callee` (line 215-228) is gated on the callee being a
Julia `Function` registered in `_known_callees`. External-IR callees never
emit IRCall today — they're rejected earlier because the LLVM name doesn't
match the `julia_` / `j_` mangling pattern in the lookup regex. So the fix
scope can be restricted to "Julia-function callees" without losing
generality for current use.

---

## §6 — Existing callees — what types flow through `lower_call!`?

Full enumeration at `src/Bennett.jl:163-208`:

```julia
register_callee!(soft_fadd)                 # (UInt64, UInt64) -> UInt64
register_callee!(soft_fsub)                 # ""
register_callee!(soft_fmul)                 # ""
register_callee!(soft_fma)                  # (UInt64, UInt64, UInt64) -> UInt64
register_callee!(soft_fneg)                 # (UInt64) -> UInt64
register_callee!(soft_fcmp_olt)             # (UInt64, UInt64) -> UInt64
register_callee!(soft_fcmp_oeq)             # ""
register_callee!(soft_udiv)                 # (UInt64, UInt64) -> UInt64
register_callee!(soft_urem)                 # ""
register_callee!(soft_fdiv)                 # ""
register_callee!(soft_fsqrt)                # (UInt64) -> UInt64
register_callee!(soft_fpext)                # ""
register_callee!(soft_fptrunc)              # ""
register_callee!(soft_exp)                  # ""
register_callee!(soft_exp2)                 # ""
register_callee!(soft_exp_fast)             # ""
register_callee!(soft_exp2_fast)            # ""
register_callee!(soft_exp_julia)            # ""
register_callee!(soft_exp2_julia)           # ""
register_callee!(soft_fptosi)               # ""
register_callee!(soft_sitofp)               # ""
register_callee!(soft_fcmp_ole)             # (UInt64, UInt64) -> UInt64
register_callee!(soft_floor)                # (UInt64) -> UInt64
register_callee!(soft_ceil)                 # ""
register_callee!(soft_trunc)                # ""
register_callee!(soft_fcmp_une)             # (UInt64, UInt64) -> UInt64
register_callee!(soft_mux_store_4x8)        # (UInt64, UInt64, UInt64) -> UInt64
register_callee!(soft_mux_load_4x8)         # (UInt64, UInt64) -> UInt64
register_callee!(soft_mux_store_8x8)        # (UInt64, UInt64, UInt64) -> UInt64
register_callee!(soft_mux_load_8x8)         # (UInt64, UInt64) -> UInt64
register_callee!(soft_mux_store_2x8)        # ""
register_callee!(soft_mux_load_2x8)         # ""
register_callee!(soft_mux_store_2x16)       # ""
register_callee!(soft_mux_load_2x16)        # ""
register_callee!(soft_mux_store_4x16)       # ""
register_callee!(soft_mux_load_4x16)        # ""
register_callee!(soft_mux_store_2x32)       # ""
register_callee!(soft_mux_load_2x32)        # ""
register_callee!(soft_mux_store_guarded_2x8)   # (UInt64, UInt64, UInt64, UInt64) -> UInt64
register_callee!(soft_mux_store_guarded_4x8)   # ""
register_callee!(soft_mux_store_guarded_8x8)   # ""
register_callee!(soft_mux_store_guarded_2x16)  # ""
register_callee!(soft_mux_store_guarded_4x16)  # ""
register_callee!(soft_mux_store_guarded_2x32)  # ""
```

**Observation 1: every single callee takes and returns `UInt64`.** Not one
takes an NTuple, aggregate, struct, or non-UInt64 type.

**Observation 2:** `soft_mux_*` callees internally treat their single
`UInt64` arg as a "packed array" — but at the Julia type level, it's a
`UInt64` scalar. The packing/unpacking is handled by the caller through
`_wires_to_u64!` and `_operand_to_u64!` (`src/lower.jl:2571-2598`) before
the `IRCall`. This is the relevant precedent but does not cross the type
boundary.

**Observation 3:** none of the callees returns a "packed" UInt64 that the
caller slices. `soft_mux_load_4x8` returns a 64-bit "packed slot" but the
actual extracted 8-bit slot value is sliced via `ctx.vw[tmp_sym][1:8]` at
`src/lower.jl:1769` — i.e. a caller-side wire slice, not an extractvalue on
an aggregate callee return.

### 6.1 Conclusion for §6

The persistent-tree arm would be the **first** callee with an aggregate
Julia arg or return. No existing pattern in the code directly supports it;
the workaround for soft_mux (pack state into UInt64 via `_wires_to_u64!` at
the caller, unpack 8 bits at the caller post-call) is **not applicable**
because the state is 576 bits — it doesn't fit in a UInt64.

---

## §7 — Existing lowering paths that might handle aggregate callee args/returns

### 7.1 `src/softmem.jl` `soft_mux_store_*x8`

All soft_mux callees take a **scalar** `UInt64` argument. They are not
aggregates. The 4-byte or 8-byte "packed array" interpretation happens at
the wire level via `_wires_to_u64!` which:

1. Allocates 64 fresh wires (line `src/lower.jl:2571-2579`).
2. CNOT-copies the source wires (up to 64) into the low bits.
3. Returns the 64-wire vector as a packed "UInt64" handle.

The callee sees a 64-bit integer. Its IR has `i64` param, not `<4 x i8>` or
`[4 x i8]`.

After the call, `soft_mux_load_4x8` returns a 64-bit value; the caller
slices bits 1-8 via `ctx.vw[tmp_sym][1:8]` (line 1769). The aggregate-ness is
entirely caller-synthesised.

This pattern is **not reusable** for 576-bit NTuple state — the arg
wouldn't fit in UInt64. We need a genuinely aggregate-arg-aware call path.

### 7.2 `src/persistent/harness.jl`

The harness does NOT call `reversible_compile` on `linear_scan_pmap_set`
directly. Its `compile_and_verify_pmap` does not appear in the current file
(I verified via a `grep`-equivalent):

**File:** `src/persistent/harness.jl:89-93` (comment excerpt):

```
# NOTE: there is no factory for "demo function" — Bennett.jl extracts
# LLVM IR best from top-level (not closure) function definitions per
# CLAUDE.md §5.  Each per-impl test file defines its OWN top-level demo
# function (3 sets + 1 get) using its impl's protocol functions.  See
# test/test_persistent_interface.jl `_ls_demo` for the template.
```

The harness relies on each test file defining a top-level demo function that
bakes inline the `pmap_new/set/get` calls. Julia inlines through, SROA
destructures the state into Int8 scalar SSA, and no ABI crossing occurs.

### 7.3 `src/persistent/linear_scan.jl` `_LS_STATE_LEN`

**File:** `src/persistent/linear_scan.jl:23-26`

```julia
const _LS_MAX_N = 4
const _LS_STATE_LEN = 1 + 2 * _LS_MAX_N    # = 9 UInt64s

const LinearScanState = NTuple{_LS_STATE_LEN, UInt64}
```

The state is always `NTuple{9, UInt64}`. 9 is specifically the size that
triggers the `<4 x i64>` vectorization seen in §4.1 (LLVM groups slots 1-4
into a single vector select + store because they share a predicate).

If `_LS_MAX_N` were 3 (state = 7 UInt64), or 8 (state = 17 UInt64), the
store pattern would differ. With `max_n=3`:

```
state[1] = count
state[2,3] = (k1, v1)
state[4,5] = (k2, v2)
state[6,7] = (k3, v3)
```

That's 6 same-predicate-kind selects (2×3 pairs), which SLP will likely
vectorize as `<2 x i64>` pairs — but `<2 x i64>` vector stores into sret
GEPs would hit the same VectorType rejection.

---

## §8 — Existing SRET/memcpy handling — data model

### 8.1 Data model summary

`_detect_sret` returns a NamedTuple:
```
(param_index::Int, param_ref::LLVMValueRef, agg_type::LLVM.ArrayType,
 n_elems::Int, elem_width::Int, elem_byte_size::Int, agg_byte_size::Int)
```

`_collect_sret_writes` returns:
```
(slot_values::Dict{Int, IROperand},   # 0-based slot index → IROperand
 suppressed::Set{_LLVMRef})             # refs to suppress from the block walk
```

`slot_values` is a **dense** dict — every slot must be written (line 548)
before `ret void`. No guard for conditional writes. No merging across
branches.

### 8.2 Canonicaliser? No explicit one in source

There is no `_canonicalise_sret_writes` or similar preprocessor. The
pipeline relies on LLVM's SROA pass to turn vector stores into scalar
stores and to eliminate the `%new::Tuple` alloca + memcpy. This is
configured only via the public `preprocess=true` kwarg, which runs
`DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg",
"instcombine"]` on the parsed module.

**Empirical finding:** `preprocess=true` alone on `optimize=true` output
does **NOT** fix the `<4 x i64>` vector store (confirmed via live probe —
see §11.1). The vector store persists through `["sroa", "mem2reg",
"simplifycfg", "instcombine"]`. Additional passes I tested — `scalarizer`
alone, `scalarizer,sroa`, `scalarizer,sroa,mem2reg`, `sroa,instcombine` —
also do NOT fix it under `optimize=true`.

**What DOES fix it:** `optimize=false, preprocess=true`. The memcpy-form
(from the alloca + memcpy emission path) is SROA-canonicalisable; the
vector-store form (post-`optimize=true` SLP vectorization) is not, by the
passes currently invoked. This is a key finding:

```
$ julia --project -e '
using Bennett
g(state::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(state, k, v)
for (opt, passes) in [(true, String[]), (true, ["sroa","mem2reg","simplifycfg","instcombine"]),
                      (true, ["scalarizer","sroa","mem2reg"]),
                      (false, ["sroa"]), (false, ["sroa","mem2reg"])]
    try
        pir = Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                                         optimize=opt, passes=passes)
        println("OK opt=$opt passes=$passes")
    catch e
        println("FAIL opt=$opt passes=$passes: $(sprint(showerror, e)[1:120])")
    end
end
'
# FAIL opt=true passes=String[]: ir_extract.jl: store in ... store <4 x i64>
# FAIL opt=true passes=["sroa","mem2reg","simplifycfg","instcombine"]: <4 x i64>
# FAIL opt=true passes=["scalarizer","sroa","mem2reg"]: <4 x i64>
# OK   opt=false passes=["sroa"]
# OK   opt=false passes=["sroa","mem2reg"]
```

### 8.3 Interpretation

The SLP vectorization that produces `<4 x i64>` runs earlier in the LLVM
pipeline than SROA. By the time we get the `optimize=true` IR string, the
vectorized stores are already in place, and SROA (which acts on allocas,
not on vector-typed values) can't undo them. The LLVM pass that would
undo it is `scalarizer` — but `scalarizer` acts on vector *ops*, not
vector *stores*; the store stays `<4 x i64>` because its value is a
vector SSA value.

What would work at the LLVM pass level:
- `loop-vectorize=false,slp-vectorize=false` on emission (not exposed by
  `code_llvm`).
- `-slp-threshold=infinity` — not a canonical NPM pass name.
- A LoadStoreVectorizer INVERSE pass (doesn't exist in LLVM).
- Running a custom pass that decomposes `<N x iM>` stores into N scalar
  stores — not in `LLVM.jl`'s exposed pass set.

---

## §9 — LLVM.jl primitives we have access to

### 9.1 Vector type inspection

**LLVM.jl exposes** (probed via `names(LLVM.API; all=true)`):

- `LLVM.VectorType` — Julia type for `<N x T>`
- `LLVM.API.LLVMGetVectorSize(ref)` — get N
- `LLVM.API.LLVMVectorTypeKind` — discriminator enum
- `LLVM.eltype(vt)` — element type
- `LLVM.length(vt)` — N (alias for GetVectorSize)
- `LLVM.width(eltype(vt))` — element bit width

Existing code already uses these at `src/ir_extract.jl:1846-1858` in
`_vector_shape`:

```julia
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    et isa LLVM.IntegerType ||
        error("ir_extract.jl: vector with non-integer element type ...")
    w = LLVM.width(et)
    w ∈ (1, 8, 16, 32, 64) ||
        error("ir_extract.jl: vector element width $w is not supported ...")
    return (LLVM.length(vt), w)
end
```

So we can detect `<4 x i64>` shape cheaply in `_collect_sret_writes`.

### 9.2 Vector lane extraction

**File:** `src/ir_extract.jl:1863-1907`

`_resolve_vec_lanes(val, lanes, names, n_expected)` already decomposes a
vector SSA ref into per-lane `IROperand`s. It handles:

- Previously-processed SSA vectors (via `lanes::Dict`).
- `ConstantDataVector` (splat values).
- `ConstantAggregateZero`.

For a `<4 x i64>` value reaching a store, we could:
1. Run `_resolve_vec_lanes(val, lanes, names, 4)` to get 4 scalar IROperands.
2. Emit 4 separate sret slot stores.

The code is already written; it just isn't invoked from `_collect_sret_writes`.

### 9.3 Memcpy handling

LLVM.jl exposes `LLVM.API.LLVMIsAMemCpyInst(ref)` and `LLVM.API.LLVMBuildMemCpy`.
The existing `_collect_sret_writes` already recognises memcpy by name match:

```julia
cname = try LLVM.name(ops[n_ops]) catch; "" end
if startswith(cname, "llvm.memcpy")
    ...
end
```

An inliner-style canonicalisation (memcpy → N individual loads + stores)
would require:
1. Identify memcpy source (operand 2) and size (operand 3).
2. Walk backwards to find the stores into the source alloca.
3. Replace those stores' destinations with `%sret_return` + appropriate GEP.

This is essentially a hand-rolled SROA. Easier to just lean on the
existing SROA pass (already in `DEFAULT_PREPROCESSING_PASSES`).

### 9.4 Pass management

`_run_passes!(mod, passes)` at `src/ir_extract.jl:195-202` uses
`LLVM.NewPMPassBuilder`. Any LLVM New-Pass-Manager string is accepted
(e.g., "sroa", "mem2reg", "scalarizer"). Multiple passes chain via comma.

---

## §10 — Existing preprocess pipeline

### 10.1 `DEFAULT_PREPROCESSING_PASSES`

**File:** `src/ir_extract.jl:23`

```julia
const DEFAULT_PREPROCESSING_PASSES = ["sroa", "mem2reg", "simplifycfg", "instcombine"]
```

Applied when `preprocess=true`. Complementary to (not a replacement for) the
`optimize` kwarg which controls `code_llvm`'s internal optimisation level.

### 10.2 What each pass does (for our purposes)

- `sroa` (Scalar Replacement Of Aggregates): promotes `alloca [N x iM]`
  into N scalar allocas or SSA values. Kills the optimize=false
  `%"new::Tuple" = alloca [9 x i64]` and its subsequent memcpy.
- `mem2reg`: promotes allocas to SSA. Complementary to SROA.
- `simplifycfg`: collapses the empty merge blocks visible in the
  `optimize=false` IR (L15/L16/L17/... all just forwarding to the next).
- `instcombine`: local peephole. Folds redundant loads after SROA.

### 10.3 What happens under `optimize=true`

Julia's `code_llvm(...; optimize=true)` runs the full Julia optimization
pipeline, which includes SROA + mem2reg internally. The `optimize=true`
output is already SROA'd. The remaining pain-point (§4.1) is that Julia's
pipeline also runs SLP vectorization, which produces the `<4 x i64>`
stores. SROA cannot undo SLP's work.

### 10.4 `optimize` vs. `preprocess` matrix

Empirically (§8.2):

| optimize | preprocess | NTuple{9,UInt64} → NTuple{9,UInt64} |
|---|---|---|
| true  | false | FAIL — `<4 x i64>` store |
| true  | true  | FAIL — `<4 x i64>` store persists |
| false | false | FAIL — memcpy form |
| false | true  | OK — SROA decomposes memcpy form |

The only currently-supported extraction path for this function is
`optimize=false, preprocess=true`.

### 10.5 No LLVM pass to undo SLP

LLVM has no canonical "descalarize vector stores" pass. The closest is
`scalarizer`, but it operates on vector arithmetic, not vector
loads/stores. The `LoopVectorize` pass has an option to disable, but
`code_llvm` doesn't expose it.

---

## §11 — Test coverage we can lean on

### 11.1 `test_sret.jl` (aggregate returns)

**File:** `test/test_sret.jl:1-137` — 8 testsets. Covers:

- n=3 UInt32 identity (`(a, b, c) = f(a, b, c)`)
- n=4 UInt32 with arithmetic
- n=8 UInt32 identity
- n=3 UInt8, n=3 UInt64, n=3 Int32
- mixed arg widths with homogeneous return (UInt8, UInt16, UInt32 → UInt32³)
- regression: n=2 by-value still works
- error: heterogeneous struct-typed sret is rejected
- error: memcpy-form is rejected with helpful message

**No test** exercises n=9 UInt64 return. **No test** triggers SLP. `n=8
UInt32` works because 8 × 4 bytes = 32 bytes — too small for SLP to
heuristically prefer vectorization, or the select chain is broken by a
phi/arithmetic op.

### 11.2 `test_tuple.jl` (by-value aggregate returns)

**File:** `test/test_tuple.jl:1-35` — 3 testsets. Covers:

- Swap pair (n=2 Int8): `(b, a)`
- Complex mul real (n=2): `(a_re * b_re, a_im * b_re)`
- Dot product (n=1 scalar return via arithmetic)

Only n=2 — below LLVM's SLP threshold.

### 11.3 `test_ntuple_input.jl` (NTuple by-reference input)

**File:** `test/test_ntuple_input.jl:1-33` — 2 testsets. Covers:

- 3-element NTuple input: `process3(t::NTuple{3, Int8})::Int8`
- 2-element NTuple input: `tuple_max(t::NTuple{2, Int8})::Int8`

Scalar returns only — no sret. Both confirm the dereferenceable-pointer ABI
for NTuple input args.

### 11.4 `test_extractvalue.jl`

**File:** `test/test_extractvalue.jl:1-47` — 3 testsets. Covers:

- Swap pair with `extractvalue`.
- First element extraction: `t = (a+b, a-b); return t[1]`
- Three-way branch.

All n=2 aggregate returns.

### 11.5 `test_intrinsics.jl` (memcpy via @llvm.memcpy)

**File:** `test/test_intrinsics.jl:1-320` — tested intrinsics: ctpop, ctlz,
cttz, bitreverse, bswap, fneg, bitcast, fabs, fcmp_ole, etc. `grep memcpy
test/test_intrinsics.jl` — no match. `llvm.memcpy` is **not** exercised as a
primary intrinsic anywhere in the test suite. The only memcpy test is in
`test_sret.jl:125-136` which asserts the error message for memcpy-form
sret under optimize=false.

### 11.6 `test_ir_memory_types.jl`

**File:** `test/test_ir_memory_types.jl` — unit tests for IR types (IRStore,
IRAlloca, width narrowing, operand lists). Doesn't exercise aggregate
returns.

### 11.7 Observations on test coverage

- **No test exercises an NTuple-to-NTuple callee invocation.** The
  persistent-tree arm would be the first.
- **No test exercises SLP vectorization interacting with sret.** The n=9
  case is the first.
- **No test exercises sret with multi-slot-batched stores (`<N x iM>` into
  sret GEP).**
- Regression baseline for sret: `test_sret.jl:116` asserts
  `gate_count(swap2 circuit).total == 82`. Any sret extraction change must
  preserve this.

---

## §12 — The actual bug surface (synthesis)

### 12.1 Bug A — `lower_call!` hardcoded UInt64 arg_types

**Location:** `src/lower.jl:1869`

**Narrow or wide?** Narrow if the fix introspects the callee's method
table; wide if it requires a new `IRCall` field.

**Narrow fix option:** Replace line 1869 with:

```julia
arg_types = Tuple{(p for p in methods(inst.callee)[1].sig.parameters[2:end])...}
```

Verified via live probe:

```
$ julia --project -e '
using Bennett
m = first(methods(Bennett.linear_scan_pmap_set))
println(Tuple{m.sig.parameters[2:end]...})
'
# Tuple{NTuple{9, UInt64}, Int8, Int8}
```

**Caveats** (all tractable):
- Callees with multiple methods: ambiguous. Mitigation: cross-check via
  `inst.arg_widths` against the method's parameter widths
  (`sum(sizeof(p)*8 for p in params) == sum(inst.arg_widths)`). If no
  method matches, fail loud.
- Callees with `Vararg` methods: no current callee uses them; reject in MVP.
- External-IR callees (from `extract_parsed_ir_from_ll`): `inst.callee` is
  always a Julia Function (from `_known_callees`), so `methods()` works.

**Wider-fix option:** Add `arg_types::Type{<:Tuple}` to `IRCall` struct.
Every IRCall construction site (13 of them per §2.7) would need to pass
this. Byte-identical result for scalar-UInt64 callees if default is
`Tuple{(UInt64 for _ in ...)...}`.

**Breakage risk of narrow fix:** minimal. Every existing callee has a
single method, and every method has UInt64 args — both new and old
derivation produce identical `Tuple{UInt64, ...}`. All gate-count baselines
preserved.

### 12.2 Bug B — vector-sret in `ir_extract`

**Location:** `src/ir_extract.jl:517-520`

**Narrow or wide?** Narrow — add a vector-store handler case to
`_collect_sret_writes`.

**Narrow fix:** Before the `vt isa LLVM.IntegerType` check, add:

```julia
if vt isa LLVM.VectorType
    # Decompose <N x iM> store into N slot writes.
    (n_lanes, lane_w) = _vector_shape(val)
    lane_w == ew || _ir_error(inst,
        "sret vector store lane width $lane_w != element width $ew")
    # byte_off is the starting offset; lanes fill byte_off, byte_off+eb, ...
    for lane in 0:(n_lanes-1)
        slot_off = byte_off + lane * eb
        slot = slot_off ÷ eb
        (0 <= slot < n) || _ir_error(inst,
            "sret vector store lane $lane slot $slot is out of range [0, $n)")
        haskey(slot_values, slot) && _ir_error(inst,
            "sret vector store lane $lane slot $slot has multiple stores")
        # Resolve the lane's IROperand using the existing vector lane helper
        slot_values[slot] = _resolve_vec_lanes(val, lanes, names, n_lanes)[lane + 1]
    end
    push!(suppressed, inst.ref)
    continue
end
```

**Caveats:**
- `_resolve_vec_lanes` is in `_convert_vector_instruction` scope; making it
  callable from `_collect_sret_writes` requires plumbing the `lanes` side
  table through. The lanes dict is currently built in pass 2; the sret
  pre-walk runs before pass 2. Either (a) move the pre-walk after pass 2
  (changes the ordering invariant), (b) build the `lanes` dict in
  `_collect_sret_writes` itself for vector values, or (c) restrict to the
  case where `val` is a concrete vector SSA whose producer is trivial
  (e.g., `select <N x i1>`). Option (b) is ~40 LOC.
- The narrow fix only works if the source vector is decomposable — i.e.
  its producing instruction is `select <N x i1>` / `insertelement` /
  `shufflevector` / constant. If the value comes from a runtime intrinsic
  we can't see into, we have to fail loud.

**Does "wider refactor" buy anything?** Possibly — moving sret decoding
into pass 2 (interleaved with the main walker) gives natural access to
`lanes`. But that's a bigger change to the ordering invariant, and
increases the risk of regressions on the n=3 UInt32 test (82 gates).

### 12.3 Bug C — memcpy-sret in `ir_extract`

**Location:** `src/ir_extract.jl:451-461`

**Narrow or wide?** Both options are tractable.

**Narrow fix:** Canonicalise memcpy-of-alloca into per-slot stores before
the main walk. This is what SROA already does — so the pragmatic narrow
fix is to **expand the `_detect_sret` + `_collect_sret_writes` preamble to
always run SROA + mem2reg when sret is detected**, regardless of the
`preprocess` kwarg.

Already-working path confirmed: `optimize=false, preprocess=true` extracts
the linear_scan IR successfully. Running SROA unconditionally when sret is
present would make `optimize=false` (the more predictable, IR-stable mode
per CLAUDE.md rule 9) work out-of-the-box.

**Wider refactor:** implement a manual memcpy expander in `ir_extract.jl`.
~80 LOC. More surface area for bugs.

**Recommendation:** narrow fix (always-run-SROA-when-sret) unless there's a
specific reason the extra passes would harm something. Known risk:
`optimize=false` mode is prized precisely because it doesn't run
unpredictable passes — a user asking for `optimize=false` might be
surprised if SROA runs under the hood. But the alternative is "sret is
supported only under `optimize=true`" which is more surprising.

### 12.4 Latent bugs that would surface

- `_narrow_ir` (`src/Bennett.jl:120-134`) sets `ret_elem_widths = [W for _ in
  parsed.ret_elem_widths]`. For an `NTuple{9, UInt64}` return (9 elements of
  64-bit each), narrowing to W=8 would produce 9 elements of 8-bit — 72-bit
  return. This is probably correct semantics but untested. Not in the
  `:persistent_tree` critical path (never called on persistent-state
  circuits).
- `lower_call!` doesn't check that `sum(inst.arg_widths) ==
  sum(callee_parsed.args[j][2])`. If the caller computes widths differently
  from the callee, wires silently misalign. Fixing the arg_types bug
  exposes this — we should add an assertion.
- `lower_call!` always re-extracts + re-lowers the callee per call.
  Pre-existing concern (reviews/06_carmack_review.md:56). For NTuple callees
  this could compile a 10264-wire sub-circuit per call — expensive if
  invoked multiple times. Memoisation is out-of-scope for P6 but would
  land cleanly.
- Pointer-typed sret param has `i64 Tuple` pointer aliasing (see
  `%"box::Tuple"` in `/tmp/g_opt.ll:82`). The extractor currently names
  the sret param but doesn't treat it as an input — the name is used only
  inside `_collect_sret_writes` for equality comparison. Safe today,
  fragile if the naming changes.

---

## §13 — Honest uncertainties + open questions

### 13.1 Why does n=9 UInt64 produce `<4 x i64>` but n=3 UInt64 doesn't?

Reasonably clear from LLVM IR inspection: the linear_scan source has 4
consecutive `_ls_pick(i, target, k_u, s[2i+2])`-style assignments that
share the select predicate grouping `target == 0/1/2/3`. Slots 1,3,5,7
(keys) and slots 2,4,6,8 (values) each form a 4-way homogeneous select chain
that LLVM's SLP vectorizer pattern-matches. Slot 0 (count) uses a
different predicate; slots 5-8 (k3,v3,k4,v4) are... actually `/tmp/g_opt.ll`
shows only slots 1-4 get vectorized (one `<4 x i64>` store at offset 8),
with slots 5-8 being scalar. SLP's cost heuristic must be deciding the
remaining 4-slot window is not profitable.

**Open question:** would restructuring `linear_scan_pmap_set` defeat SLP
— e.g., reordering slots to break the consecutive-same-predicate pattern?
Worth investigating as a belt-and-suspenders measure, but not a proper
fix (other persistent impls will have their own SLP-friendly patterns).

### 13.2 Does any LLVM pass decompose `<N x iM>` stores?

I could not find one in my survey of canonical NPM pass names. The
`scalarizer` pass acts on vector ops, not stores. This may be resolvable by
WebSearch — flagging for online research.

### 13.3 What about `sret` with a struct type instead of `[N x iM]`?

Rejected at `src/ir_extract.jl:383-387`. The persistent impls all use
homogeneous NTuple state — `[N x i64]` — so the MVP scope is sufficient.
But if the future `hashcons=:feistel` path wants a mixed-width state
(e.g., `Tuple{UInt8, NTuple{8,UInt64}}`), this becomes a blocker.

### 13.4 Can `inst.callee`'s method table have zero methods?

If a user registers a callable object that isn't a Julia function
(unlikely, but `register_callee!` accepts `::Function`), `methods()`
returns empty. Fail-loud mitigation: `isempty(methods(...)) && error(...)`.

### 13.5 `compact_calls=true` and NTuple args — untested combination

Both branches of `lower_call!` (§2.2) use `callee_parsed.args[j][2]` and
`output_wires` identically. The math should carry through, but no test
exercises `compact_calls=true` with an NTuple-arg callee.

### 13.6 Does the fix preserve `test_sret.jl:116` gate-count baseline?

For the `swap2(a::Int8, b::Int8) = (b, a)` case:
- `n=2`, `elem_width=8`, total=16 bits
- Not sret (below ABI threshold on x86_64 SysV — 2×1 byte = 2 bytes,
  returned in registers)
- Hits the `LLVM.ArrayType` return path, not sret
- The vector-store-in-sret fix doesn't touch this path
- The `lower_call!` arg_types fix doesn't touch this path either (no
  IRCall in the swap2 pipeline — it's pure arithmetic)

Gate count = 82 should be preserved. **Not empirically verified in this
audit** — should be part of the RED→GREEN cycle for whoever implements.

### 13.7 Would using `@nospecialize` / `@noinline` on
`linear_scan_pmap_set` help?

Possibly changes the IR shape. But the current `register_callee!` mechanism
depends on Julia emitting a separate function (not inlining) so the LLVM
name matches `j_linear_scan_pmap_set_NN`. The actual `linear_scan_pmap_set`
is `@inline`-marked. For the IRCall mechanism to fire, we either:

- Remove `@inline` (would break the `_ls_demo` test, which currently relies
  on full inlining + no call).
- Use `@noinline` at the call site in the persistent-tree arm (which is
  harness-emitted IR, not user Julia code — so we control this).

When the `:persistent_tree` arm manually constructs the IRCall via
`lower_call!`, it doesn't go through Julia's @inline at all — it directly
calls `extract_parsed_ir(linear_scan_pmap_set, Tuple{...})` which forces
standalone compilation. So `@inline` on the source is irrelevant for the
dispatcher arm path; only matters for the inline-me path (`_ls_demo`).

### 13.8 Open: optimize=false + preprocess=true — side effects on other callees?

If we make `optimize=false preprocess=true` the recommended extraction for
NTuple-aggregate callees, does running SROA on every callee (including
scalar soft_mux) change anything? SROA on a function with no allocas is a
no-op; scalar callees have no allocas post-Julia-codegen. Should be safe
but worth a smoke test.

### 13.9 Open: how does Julia decide `optimize=true` vs. `@noinline` sret?

With `@noinline Bennett.linear_scan_pmap_set(s, k, v)`, Julia emits the
call as `call void @j_linear_scan_pmap_set_NN(ptr sret %sret_box, ptr
%state, i8, i8)`. The **caller** then has its own sret (`%sret_return`) and
copies `%sret_box` into it via memcpy. **Both caller and callee** have sret
— double sret chain. Not tested today; the dispatcher arm bypasses this by
constructing the IRCall directly.

---

## §14 — Appendix: files read, IR captured

### Files read (all absolute paths)

- `/home/tobiasosborne/Projects/Bennett.jl/src/ir_types.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/ir_extract.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/lower.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/Bennett.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/gates.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/simulator.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/bennett_transform.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/softmem.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/persistent/persistent.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/persistent/interface.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/persistent/linear_scan.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/persistent/harness.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/src/persistent/okasaki_rbt.jl` (header)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_persistent_interface.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_sret.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_tuple.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_extractvalue.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_ntuple_input.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_intrinsics.jl` (first 100 lines)
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_general_call.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_p5a_ll_ingest.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/test/test_ir_memory_types.jl`
- `/home/tobiasosborne/Projects/Bennett.jl/docs/design/p6_consensus.md`
- `/home/tobiasosborne/Projects/Bennett.jl/docs/design/sret_proposer_A.md` (header)

### IR artifacts captured

- `/tmp/g_opt.ll` — optimize=true IR (9684 bytes) showing `<4 x i64>` sret store
- `/tmp/g_noopt.ll` — optimize=false IR (10795 bytes) showing memcpy form
- `/tmp/g_noopt_sroa.ll` — optimize=false + SROA (7352 bytes) showing clean i64 stores
- `/tmp/g_opt_rerun.ll` — optimize=true + scalarizer+sroa+mem2reg+instcombine (9676 bytes) showing `<4 x i64>` persists
- `/tmp/g_scalarized.ll` — optimize=true + scalarizer only (9676 bytes)
- `/tmp/lsdemo.ll` — `_ls_demo` full compile (3925 bytes) showing full inlining, no sret, 6-line IR body
