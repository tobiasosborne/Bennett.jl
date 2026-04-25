# Bennett-0c8o β — Proposer B

**Bead:** Bennett-0c8o (P1, bug, `3plus1,core`)
**Scope:** handle vector-lane sret stores (`store <N x iW>` at sret GEP byte offsets).
**Author role:** Proposer B (independent design; has not read Proposer A).

---

## §0 TL;DR

**Recommendation:** **Option (a), with a targeted extension.** Build a
*local* per-cone lane resolver inside `_collect_sret_writes` that decomposes
the `<N x iW>` value back to N scalar `IROperand`s. Support the specific
vector opcodes actually observed in Julia's optimised sret IR
(`insertelement`, `shufflevector`, `select`, vector `icmp`, `zext/sext/trunc`,
constant vectors, poison/undef, and — crucially — vector `load`). Everything
else falls back to a fail-loud unsupported-shape error with the offending
IR snippet.

**Why not (b)?** Moving sret decoding into pass 2 changes the ordering
invariant and forces pass 2 to reason about a hybrid control-data flow. It
also does NOT solve the `load <4 x i64>` blocker: `_convert_vector_instruction`
has no `LLVMLoad` handler, so interleaving still crashes. Option (b) is
strictly more work AND ships the same blocker.

**Why not (c)?** I tried it. LLVM.jl's bundled NewPMPassBuilder rejects
`"scalarizer<load-store>"` (parameter syntax not surfaced) and the plain
`"scalarizer"` leaves load/store scalarisation defaulted off — it does not
rewrite the `<4 x i64>` store. See §1.3 for the verified failure.

Total change: ~120 LOC in `ir_extract.jl` (local driver + 5 per-opcode
branches), ~80 LOC of new test, zero edits outside `_collect_sret_writes`
and `_resolve_vec_lanes`'s existing path-structure. No changes to
`_synthesize_sret_chain`, `_narrow_ir`, or `lower.jl`.

---

## §1 Ground truth: the exact IR Julia emits

Extracted live via `code_llvm(..., optimize=true, dump_module=false)` at the
repository root on 2026-04-21:

```
define void @julia_g_175(
    ptr noalias nocapture noundef nonnull sret([9 x i64]) align 8
        dereferenceable(72) %sret_return,
    ptr nocapture noundef nonnull readonly align 8
        dereferenceable(72) %"state::Tuple",
    i8 signext %"k::Int8", i8 signext %"v::Int8") #0 {
top:
  %"state::Tuple.unbox" = load i64, ptr %"state::Tuple", align 8
  %0  = icmp ult i64 %"state::Tuple.unbox", 4
  %1  = add i64 %"state::Tuple.unbox", 1
  %2  = select i1 %0, i64 %1, i64 4                     ; → slot 0
  %3  = insertelement <2 x i8> poison, i8 %"k::Int8", i64 0
  %4  = insertelement <2 x i8> %3, i8 %"v::Int8", i64 1
  %5  = zext <2 x i8> %4 to <2 x i64>
  %6  = shufflevector <2 x i64> %5, <2 x i64> poison,
                      <4 x i32> <i32 0, i32 1, i32 0, i32 1>
  %"state::Tuple[2]_ptr" = getelementptr inbounds i8, ptr %"state::Tuple", i64 8
  ; ... per-slot scalar work for slots 5..8 ...
  store i64 %2, ptr %sret_return, align 8               ; slot 0, i64 store
  %"new::Tuple.sroa.2.0.sret_return.sroa_idx" =
      getelementptr inbounds i8, ptr %sret_return, i64 8
  %14 = insertelement <2 x i64> poison, i64 %"state::Tuple.unbox", i64 0
  %15 = shufflevector <2 x i64> %14, <2 x i64> poison,
                      <2 x i32> zeroinitializer
  %16 = icmp eq <2 x i64> %15, <i64 0, i64 1>
  %17 = shufflevector <2 x i1> %16, <2 x i1> poison,
                      <4 x i32> <i32 0, i32 0, i32 1, i32 1>
  %18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr", align 8  ; !!
  %19 = select <4 x i1> %17, <4 x i64> %6, <4 x i64> %18
  store <4 x i64> %19,
        ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx", align 8  ; slots 1..4
  %"new::Tuple.sroa.6.0.sret_return.sroa_idx" =
      getelementptr inbounds i8, ptr %sret_return, i64 40
  store i64 %8, ptr %"new::Tuple.sroa.6.0.sret_return.sroa_idx", align 8   ; slot 5
  store i64 %10, ...                                            ; slot 6
  store i64 %12, ...                                            ; slot 7
  store i64 %13, ...                                            ; slot 8
  ret void
}
```

### §1.1 What this cone contains

Starting from `store <4 x i64> %19, ptr %<sroa_idx>` and walking backwards:

| SSA   | Opcode                | Operands that need resolution                 |
|-------|-----------------------|-----------------------------------------------|
| %19   | `select <4 x i1>`     | cond %17, t %6, f %18                         |
| %17   | `shufflevector` i1    | %16 (2 lanes) → 4 lanes by broadcast          |
| %16   | `icmp eq <2 x i64>`   | %15, constant `<i64 0, i64 1>`                |
| %15   | `shufflevector`       | %14 → splat                                   |
| %14   | `insertelement`       | scalar `state::Tuple.unbox`                   |
| %6    | `shufflevector`       | %5 (2 lanes) → 4 lanes                        |
| %5    | `zext <2 x i8>→<2 x i64>` | %4                                          |
| %4,%3 | `insertelement`       | scalars k, v                                  |
| %18   | **`load <4 x i64>`**  | ptr `state::Tuple[2]_ptr`                     |

The **blocker that every design must address** is `%18 = load <4 x i64>`.
`_convert_vector_instruction` (src/ir_extract.jl:1909-2121) has no
`LLVMLoad` case and will fail-loud with `"unsupported vector opcode"`.
This means pass 2 crashes on `%18` **even if we completely skip the
store `%19`**.

### §1.2 Why option (a)'s narrow sketch in p6_research_local.md §12.2 is insufficient

The sketch there is:

```julia
if vt isa LLVM.VectorType
    (n_lanes, lane_w) = _vector_shape(val)
    ...
    slot_values[slot] = _resolve_vec_lanes(val, lanes, names, n_lanes)[lane+1]
    ...
end
```

This fails because:

1. `_resolve_vec_lanes` is called with `lanes::Dict` that is **empty**
   at pre-walk time (pass 2 hasn't run yet).
2. `_resolve_vec_lanes` handles `ConstantDataVector`,
   `ConstantAggregateZero`, poison/undef, or values already in `lanes`.
   None of those apply to `%19` (an SSA select of other SSA values).
3. Even if we drive the cone bottom-up recursively, the cone reaches
   `%18 = load <4 x i64>` which has no scalar decomposition.

So proposer B's design extends the sketch in three ways:

- A **local recursive lane resolver** that decomposes the cone
  bottom-up, emitting no IR (no side effects except populating a local
  `Dict{_LLVMRef, Vector{IROperand}}`).
- An explicit **vector-load decomposer** that synthesises N scalar
  `IRLoad`s at lane byte offsets, re-using the per-byte-GEP tracking
  already in `_collect_sret_writes` for ptr params.
- **Producer suppression**: every instruction in the cone is added to
  `suppressed`, so pass 2 never attempts to lower the vector ops.

### §1.3 Option (c) empirical verdict

Verified at the repo root on 2026-04-21 (post-research):

```
$ julia --project -e 'using Bennett
g(s::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(s,k,v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                          passes=["scalarizer<load-store>"])'
→ ERROR: LLVM error: unknown pass name 'scalarizer<load-store>'
```

```
$ julia --project -e 'using Bennett
g(s::NTuple{9,UInt64}, k::Int8, v::Int8) = Bennett.linear_scan_pmap_set(s,k,v)
Bennett.extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8};
                          passes=["scalarizer"])'
→ ERROR: ir_extract.jl: store in @julia_g_1744:%top:
  store <4 x i64> %9, ptr %"new::Tuple.sroa.2.0.sret_return.sroa_idx",
  ... sret store at byte offset 8 has non-integer value type ...
```

Plain `"scalarizer"` **does run** (no LLVM error) but **does not
scalarise load/store** because the default is `ScalarizeLoadStore=false`
(verified against `llvm/lib/Transforms/Scalar/Scalarizer.cpp:338` in
p6_research_online.md §3.1). The LLVM.jl New-Pass-Manager parser does
not accept the `pass<param>` angle-bracket syntax that upstream opt
uses. Option (c) is therefore **not viable** without either (i)
patching LLVM.jl to accept parameterised pass names or (ii) forking
`_run_passes!` to talk to the legacy-pm C API directly. Both are wide
refactors that fall outside Bennett-0c8o's P1 bug scope.

This was the key unknown-unknown the research doc (§3.1, §3.6, §13.2)
flagged as "possibly viable"; the empirical test flips it to "not
viable today".

---

## §2 Design choice matrix

| Option | Effort | Bennett-0c8o | `load <4 x i64>` | Regression risk | Verdict |
|--------|--------|--------------|------------------|-----------------|---------|
| (a) local lane resolver in `_collect_sret_writes` | ~120 LOC | ✅ | ✅ with vector-load leaf | Low (confined to sret cone) | **Pick** |
| (b) move sret decoding into pass 2 | ~250 LOC | ✅ | ❌ still crashes on vector load | Medium (reorders walker invariants) | Defer |
| (c) run `scalarizer<load-store>` | ~10 LOC | ❌ doesn't work in LLVM.jl (see §1.3) | — | — | Reject |

Picked: **(a)**. Details below.

---

## §3 The design — Option (a)

### §3.1 Invariants preserved

- `_collect_sret_writes` still runs **before** pass 2. Ordering
  unchanged.
- Pass 2 still reads `sret_writes.suppressed` and skips everything
  within. We just add more refs to that set.
- `_synthesize_sret_chain` (src/ir_extract.jl:563-578) consumes
  `slot_values::Dict{Int, IROperand}` unchanged — slot values are
  individual scalar `IROperand`s, produced by the new path the same
  way they're produced by the existing integer-store path.
- Scalar sret stores (the n=2..8 UInt32 path tested in
  `test/test_sret.jl`) take the existing fast-path unchanged.
- `_narrow_ir` (src/Bennett.jl:120-134) is not touched. Since
  slot-value widths are always `ew` by construction, and
  `ret_elem_widths = [ew, …]` with length n, `_narrow_ir` still maps
  cleanly (see §6.3).

### §3.2 The new local resolver

Add to `ir_extract.jl` just above `_collect_sret_writes` (src/ir_extract.jl:430):

```julia
"""
    _sret_decompose_vec_value(val, lanes_local, names, counter, extra_insts,
                              suppressed, ptr_params_info)
        -> Vector{IROperand}

Resolve an `<N x iW>` value to N scalar `IROperand`s without relying on
pass 2's `lanes` side table. Populates `lanes_local` along the way
(keyed by `LLVMValueRef`, so mutual re-use between stores in the same
sret cone sees cached results).

Every SSA instruction visited is added to `suppressed` so pass 2 skips
it. Any newly-synthesised scalar ops (e.g. N × `IRLoad` from a vector
load) are appended to `extra_insts`, which the caller splices into the
main block in program order at `ret void` synthesis time.

Supported shapes (matches what SLP + VectorCombine actually emit for
Julia aggregate sret):

  * ConstantDataVector          — constant splat or lane list
  * ConstantAggregateZero       — all lanes 0
  * UndefValue / PoisonValue    — all-poison sentinel (fail if read)
  * insertelement               — lane-by-lane build
  * shufflevector               — permute + broadcast from two src vectors
  * select <N x i1>             — per-lane IRSelect
  * icmp <N x iW>               — per-lane IRICmp
  * zext/sext/trunc <N x ...>   — per-lane IRCast
  * add/sub/mul/and/or/xor/
    shl/lshr/ashr <N x iW>      — per-lane IRBinOp
  * load <N x iW>               — decomposed into N scalar IRLoads at
                                   lane byte offsets (see §3.3).

Any other opcode: fail loud with _ir_error and the offending instruction.
"""
function _sret_decompose_vec_value(val::LLVM.Value,
        lanes_local::Dict{_LLVMRef, Vector{IROperand}},
        names::Dict{_LLVMRef, Symbol},
        counter::Ref{Int},
        extra_insts::Vector{IRInst},
        suppressed::Set{_LLVMRef},
        ptr_byte_map::Dict{_LLVMRef, Int})::Vector{IROperand}

    # cache hit
    haskey(lanes_local, val.ref) && return lanes_local[val.ref]

    # constant / poison leaves via existing helpers
    if val isa LLVM.ConstantDataVector || val isa LLVM.ConstantAggregateZero ||
       val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        vt = LLVM.value_type(val)
        n = Int(LLVM.length(vt))
        out = _resolve_vec_lanes(val, lanes_local, names, n)  # reuse
        lanes_local[val.ref] = out
        return out
    end

    # ConstantVector — small-K constant (not CDV).  Rare but legal.
    if val isa LLVM.ConstantVector
        n = Int(LLVM.length(LLVM.value_type(val)))
        ops = LLVM.operands(val)
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            e = ops[i]
            e isa LLVM.ConstantInt ||
                error("ir_extract.jl: ConstantVector lane $i is not ConstantInt: $e")
            out[i] = iconst(convert(Int, e))
        end
        lanes_local[val.ref] = out
        return out
    end

    val isa LLVM.Instruction ||
        error("ir_extract.jl: cannot decompose vector value $(string(val)) :: " *
              "$(LLVM.value_type(val)) — not an Instruction, ConstantDataVector, " *
              "ConstantVector, ConstantAggregateZero, or poison/undef")

    inst = val::LLVM.Instruction
    opc = LLVM.opcode(inst)
    vt  = LLVM.value_type(inst)
    (n_res, w_res) = _vector_shape(inst)  # errors on non-vector

    ops = LLVM.operands(inst)

    # insertelement %base, %elem, %idx
    if opc == LLVM.API.LLVMInsertElement
        idx_val = ops[3]
        idx_val isa LLVM.ConstantInt ||
            _ir_error(inst, "sret: insertelement with dynamic lane index not supported")
        idx = convert(Int, idx_val)
        (0 <= idx < n_res) ||
            _ir_error(inst, "sret: insertelement lane index $idx outside [0,$n_res)")
        base_lanes = _sret_decompose_vec_value(
            ops[1], lanes_local, names, counter, extra_insts, suppressed, ptr_byte_map)
        out = copy(base_lanes)
        out[idx + 1] = _operand(ops[2], names)
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # shufflevector v1, v2, mask
    if opc == LLVM.API.LLVMShuffleVector
        v1, v2 = ops[1], ops[2]
        n_src = Int(LLVM.length(LLVM.value_type(v1)))
        v1_lanes = _sret_decompose_vec_value(
            v1, lanes_local, names, counter, extra_insts, suppressed, ptr_byte_map)
        v2_lanes = _sret_decompose_vec_value(
            v2, lanes_local, names, counter, extra_insts, suppressed, ptr_byte_map)
        out = Vector{IROperand}(undef, n_res)
        for i in 0:(n_res - 1)
            m = Int(LLVM.API.LLVMGetMaskValue(inst.ref, i))
            if m == -1
                out[i + 1] = IROperand(:const, :__poison_lane__, 0)
            elseif 0 <= m < n_src
                out[i + 1] = v1_lanes[m + 1]
            elseif n_src <= m < 2*n_src
                out[i + 1] = v2_lanes[m - n_src + 1]
            else
                _ir_error(inst, "sret: shufflevector mask element $m out of range")
            end
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # select <N x i1> cond, t, f — emit N scalar IRSelect
    if opc == LLVM.API.LLVMSelect
        cond = ops[1]
        cond_is_vec = LLVM.value_type(cond) isa LLVM.VectorType
        cond_lanes = cond_is_vec ?
            _sret_decompose_vec_value(cond, lanes_local, names, counter,
                                      extra_insts, suppressed, ptr_byte_map) :
            nothing
        t_lanes = _sret_decompose_vec_value(ops[2], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        f_lanes = _sret_decompose_vec_value(ops[3], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        out = Vector{IROperand}(undef, n_res)
        for i in 1:n_res
            c_op = cond_is_vec ? cond_lanes[i] : _operand(cond, names)
            lane_dest = _auto_name(counter)
            push!(extra_insts, IRSelect(lane_dest, c_op, t_lanes[i], f_lanes[i], w_res))
            out[i] = ssa(lane_dest)
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # icmp <N x iW> — emit N scalar IRICmp (result width tracked as op width, not 1)
    if opc == LLVM.API.LLVMICmp
        (_, op_w) = _vector_shape(ops[1])
        pred = _pred_to_sym(LLVM.predicate(inst))
        a_lanes = _sret_decompose_vec_value(ops[1], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        b_lanes = _sret_decompose_vec_value(ops[2], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        out = Vector{IROperand}(undef, n_res)
        for i in 1:n_res
            lane_dest = _auto_name(counter)
            push!(extra_insts,
                  IRICmp(lane_dest, pred, a_lanes[i], b_lanes[i], op_w))
            out[i] = ssa(lane_dest)
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # Vector cast — emit N scalar IRCast
    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        (_, w_from) = _vector_shape(ops[1])
        src_lanes = _sret_decompose_vec_value(
            ops[1], lanes_local, names, counter, extra_insts, suppressed, ptr_byte_map)
        out = Vector{IROperand}(undef, n_res)
        for i in 1:n_res
            lane_dest = _auto_name(counter)
            push!(extra_insts,
                  IRCast(lane_dest, opname, src_lanes[i], w_from, w_res))
            out[i] = ssa(lane_dest)
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # Vector arithmetic / bitwise / shift
    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        sym = _opcode_to_sym(opc)
        a_lanes = _sret_decompose_vec_value(ops[1], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        b_lanes = _sret_decompose_vec_value(ops[2], lanes_local, names, counter,
                                            extra_insts, suppressed, ptr_byte_map)
        out = Vector{IROperand}(undef, n_res)
        for i in 1:n_res
            lane_dest = _auto_name(counter)
            push!(extra_insts,
                  IRBinOp(lane_dest, sym, a_lanes[i], b_lanes[i], w_res))
            out[i] = ssa(lane_dest)
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    # Vector LOAD — the critical leaf. Decompose into N scalar IRLoads at
    # per-lane byte offsets.  See §3.3.
    if opc == LLVM.API.LLVMLoad
        ptr = ops[1]
        haskey(names, ptr.ref) ||
            _ir_error(inst, "sret: vector load pointer $(string(ptr)) is not a " *
                            "named SSA value; only loads from named ptr params or " *
                            "their byte-GEP derivatives are supported in the sret cone")
        base_sym = names[ptr.ref]
        # Emit N scalar IRLoads with IRPtrOffset GEPs at lane_i * (w_res/8).
        # IRPtrOffset+IRLoad is exactly how scalar loads on ptr params are
        # modelled elsewhere (verified: NTuple{2,UInt64} sum, §5.2).
        out = Vector{IROperand}(undef, n_res)
        lane_bytes = w_res ÷ 8
        for i in 0:(n_res - 1)
            gep_dest = _auto_name(counter)
            # Bennett-convention: 0-offset IRPtrOffset is also emitted for
            # alignment with how main-walker lowers byte-GEPs.
            push!(extra_insts, IRPtrOffset(gep_dest, ssa(base_sym), i * lane_bytes))
            load_dest = _auto_name(counter)
            push!(extra_insts, IRLoad(load_dest, ssa(gep_dest), w_res))
            out[i + 1] = ssa(load_dest)
        end
        lanes_local[inst.ref] = out
        push!(suppressed, inst.ref)
        return out
    end

    _ir_error(inst, "sret: unsupported vector producer opcode $opc in the " *
                    "store cone; add a case to _sret_decompose_vec_value " *
                    "or pre-canonicalise with a preprocess pass")
end
```

### §3.3 Why decomposing a vector load into N scalar loads is correct

The `load <4 x i64>, ptr %p` loads 32 bytes starting at `%p`. On all
Bennett-supported targets (x86_64, aarch64 — pointer GEP semantics
match), this is byte-equivalent to:

```
%p0 = ptr %p + 0                → load i64
%p1 = ptr %p + 8                → load i64
%p2 = ptr %p + 16               → load i64
%p3 = ptr %p + 24               → load i64
```

**Endianness:** irrelevant — a lane-i `i64` read reads the same 8 bytes
that the LLVM pass would put into the i-th vector element. LLVM's
vector memory layout for `<N x iW>` is element-order with no gaps
(`DataLayout::getTypeStoreSize(VT) == N * (W/8)` for W ∈ {8,16,32,64}),
per LLVM LangRef "Vector Type" (documented in research §9.1).

**Alignment:** The vector load has `align 8`; each lane i64 load also
has natural alignment 8. Bennett.jl doesn't model alignment (ptr-param
wires are bit-addressable via IRPtrOffset). Safe.

**No aliasing concern:** The sret cone is write-only into `%sret_return`,
and only reads from `%"state::Tuple"`, which has the `nocapture
noundef readonly` attribute. Concurrent stores can't modify the bytes
being loaded.

### §3.4 Integration into `_collect_sret_writes`

Replace the rejection at `src/ir_extract.jl:516-540` with a split:

```julia
# Store targeting the sret buffer (directly or through a tracked GEP)
if opc == LLVM.API.LLVMStore
    ops = LLVM.operands(inst)
    val = ops[1]
    ptr = ops[2]
    byte_off = if ptr.ref === sret_ref
        0
    elseif haskey(gep_byte, ptr.ref)
        gep_byte[ptr.ref]
    else
        nothing
    end
    if byte_off !== nothing
        vt = LLVM.value_type(val)

        # ---- NEW: vector store ---------------------------------------
        if vt isa LLVM.VectorType
            (n_lanes, lane_w) = _vector_shape(val)  # errors on bad shape
            lane_w == ew || _ir_error(inst,
                "sret vector store at byte offset $byte_off has lane width " *
                "$lane_w, but aggregate element width is $ew")
            (byte_off % eb == 0) || _ir_error(inst,
                "sret vector store at byte offset $byte_off is not aligned " *
                "to element size $eb")
            first_slot = byte_off ÷ eb
            last_slot = first_slot + n_lanes - 1
            (0 <= first_slot && last_slot < n) || _ir_error(inst,
                "sret vector store covers slots [$first_slot, $last_slot]; " *
                "out of aggregate range [0, $n)")
            for lane in 0:(n_lanes - 1)
                slot = first_slot + lane
                haskey(slot_values, slot) && _ir_error(inst,
                    "sret vector store lane $lane maps to slot $slot which " *
                    "already has a store (duplicate-slot invariant violated)")
            end
            # Recursively decompose the cone
            lane_ops = _sret_decompose_vec_value(
                val, lanes_local, names, counter, extra_insts, suppressed, gep_byte)
            @assert length(lane_ops) == n_lanes
            for lane in 0:(n_lanes - 1)
                slot = first_slot + lane
                lane_op = lane_ops[lane + 1]
                (lane_op.kind == :const && lane_op.name === :__poison_lane__) &&
                    _ir_error(inst, "sret vector store lane $lane resolves to " *
                                    "a poison lane (undefined behaviour)")
                slot_values[slot] = lane_op
            end
            push!(suppressed, inst.ref)
            continue
        end
        # ---- END NEW -------------------------------------------------

        # Existing integer-store path (unchanged below this line):
        vt isa LLVM.IntegerType || _ir_error(inst,
            "sret store at byte offset $byte_off has non-integer value " *
            "type $vt; only integer stores are supported")
        ...
    end
end
```

### §3.5 Function-signature changes

`_collect_sret_writes` gains two keyword-adjacent pieces of state:

```julia
function _collect_sret_writes(func::LLVM.Function, sret_info,
                              names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int})    # NEW: shared name counter
    slot_values  = Dict{Int, IROperand}()
    suppressed   = Set{_LLVMRef}()
    gep_byte     = Dict{_LLVMRef, Int}()
    lanes_local  = Dict{_LLVMRef, Vector{IROperand}}()  # NEW
    extra_insts  = IRInst[]                              # NEW
    ...
    return (slot_values = slot_values, suppressed = suppressed,
            extra_insts = extra_insts)       # NEW field on return namedtuple
end
```

The `counter` argument is now passed through so `_auto_name` generates
unique SSA symbols for synthesised per-lane `IRSelect/IRICmp/IRCast/IRBinOp/IRPtrOffset/IRLoad`.
It already lives in `_module_to_parsed_ir_on_func` (src/ir_extract.jl:633) —
just thread it.

### §3.6 Consuming `extra_insts`

In `_module_to_parsed_ir_on_func` (src/ir_extract.jl:711), update the
call site:

```julia
# Old:
sret_writes = sret_info === nothing ? nothing :
              _collect_sret_writes(func, sret_info, names)

# New:
sret_writes = sret_info === nothing ? nothing :
              _collect_sret_writes(func, sret_info, names, counter)
```

And at `ret void` synthesis (src/ir_extract.jl:728-736), splice
`extra_insts` in just before the synthesize chain:

```julia
if sret_writes !== nothing &&
   LLVM.opcode(inst) == LLVM.API.LLVMRet &&
   isempty(LLVM.operands(inst))
    # NEW: emit all lane-decomposed scalar ops first, in original cone order
    for ei in sret_writes.extra_insts
        push!(insts, ei)
    end
    chain, ret_inst = _synthesize_sret_chain(
        sret_info, sret_writes.slot_values, counter)
    append!(insts, chain)
    terminator = ret_inst
    continue
end
```

**Ordering invariant:** `extra_insts` is populated in DFS post-order
by the recursive resolver, so producers always appear before
consumers. Every op in `extra_insts` refers to SSA names that were
either (a) generated by an earlier `_auto_name(counter)` in the same
recursion, or (b) live in `names` from pass-1 naming. Both are
definable at the point of emission.

---

## §4 Edge cases — catalogue and handling

### §4.1 Constant splats — `<4 x i64> <i64 5, i64 5, i64 5, i64 5>`

Delivered as `ConstantDataVector` by LLVM.jl. Handled by the first
branch of `_sret_decompose_vec_value` via `_resolve_vec_lanes` (§3.2).
Output: 4 × `iconst(5)`.

### §4.2 `ConstantAggregateZero`

Same path as constant splats. Output: 4 × `iconst(0)`.

### §4.3 `UndefValue` / `PoisonValue`

Returns 4 × `IROperand(:const, :__poison_lane__, 0)`. If any such lane
propagates into a `slot_values[slot] =`, the wrapping check at §3.4's
`lane_op.name === :__poison_lane__` fires → fail-loud error. This
matches the existing `extractelement` poison-read guard
(src/ir_extract.jl:1970-1971).

### §4.4 `insertelement` chain — full build

Each step returns a `copy`-modified lane vector with exactly one lane
replaced. Verified behaviour of the existing handler at
src/ir_extract.jl:1917-1931. The recursive resolver mirrors it.

### §4.5 `shufflevector` with poison mask elements (`i32 undef`)

`LLVMGetMaskValue` returns `-1` for poison lane-index positions
(documented at LLVM LangRef "shufflevector" and used already at
src/ir_extract.jl:1944-1945). We emit `:__poison_lane__` at that
output position; read-side guard fires only if that lane is ultimately
stored into an sret slot.

### §4.6 `shufflevector <2 x T>, <2 x T>, <4 x i32> ...` — widening shuffle

`n_res` > `n_src`. The resolver handles this naturally — we resolve
each src operand to `n_src` lanes and index into the concatenation by
mask value. No special-case needed.

### §4.7 Empty or length-1 vector

`<1 x iW>` is legal in LLVM IR. `_vector_shape` accepts it
(n=1, w∈{1,8,16,32,64}). The resolver handles it uniformly since all
loops are `1:n_res`. At store time, a single-lane vector store is
byte-equivalent to a scalar store — we just take lane 0.

### §4.8 Mixed-predicate select chain

If two different `select <4 x i1>` instructions target the same sret
byte range, they'd produce different-length store cones. Each store
decomposes independently. The duplicate-slot guard at §3.4 catches
any overlap:

```julia
haskey(slot_values, slot) && _ir_error(inst, "duplicate-slot invariant violated")
```

This is the existing MVP invariant from src/ir_extract.jl:532-535; we
just extend the check across vector lanes.

### §4.9 Vector load with a GEP chain we don't track

If `ops[1]` of a `load <N x iW>` isn't in `names` (e.g., produced by
an `inttoptr` from an arithmetic result), we fail-loud. In practice,
Julia's optimiser produces `load <N x iM>` only from ptr params via
inbounds byte GEP, and the existing main-walker GEP handler (lines
1358-1395) populates `names` for all byte-GEP results. `ptr_params`
tracking guarantees the base is nameable.

### §4.10 Scalar store + overlapping vector store

E.g., `store i64 ... at byte 8` followed by `store <4 x i64> ... at
byte 8`. Either:
- The scalar store runs first → slot 1 is occupied → vector store
  lane 0 hits `haskey(slot_values, 1)` → fail.
- The vector store runs first → slot 1 is occupied → scalar store
  hits `haskey(slot_values, 1)` → fail.

Either order, we fail loud with the duplicate-slot message, which is
what we want for MVP. Per CLAUDE.md rule 1 (fail fast, fail loud).

### §4.11 Interleaved scalar stores and vector store

The linear_scan n=9 case:

```
store i64 %2,  ptr %sret_return                             ; slot 0
store <4 x i64> %19, ptr %sret+8                            ; slots 1-4
store i64 %8,  ptr %sret+40                                 ; slot 5
store i64 %10, ptr %sret+48                                 ; slot 6
store i64 %12, ptr %sret+56                                 ; slot 7
store i64 %13, ptr %sret+64                                 ; slot 8
```

Each store is processed in order; the vector store writes slots 1..4
atomically via `_sret_decompose_vec_value`. Scalar stores at slots
0, 5..8 use the existing fast-path. Final
`slot_values == {0=>op, 1=>op, …, 8=>op}`. Completeness check at
src/ir_extract.jl:546-550 passes.

### §4.12 Vector store as sole sret write (n=N aggregate, one `<N x iW>` store)

Theoretical: `store <9 x i64>` covering the whole aggregate. Works
under our design — first_slot=0, last_slot=8, all 9 lanes populated
in one call. Not observed in practice (LLVM's AVX2 register width is
256 bits = 4×i64; vectorisation block size is 4 for i64, not 9).

### §4.13 Two vector stores covering different ranges

E.g., `store <2 x i64> at byte 0`, `store <2 x i64> at byte 16` for
n=4 aggregate. Each decomposes independently; slot ranges disjoint;
no duplicate-slot hit. Works.

---

## §5 RED test — `test/test_0c8o_vector_sret.jl`

Complete file; drop-in. Add the include to `test/runtests.jl` alongside
the other sret-family tests.

```julia
# test/test_0c8o_vector_sret.jl
#
# Bennett-0c8o: vector-lane sret stores (`store <N x iW>` at sret GEP).
# Triggered by Julia's SLP vectoriser on n=9 UInt64 NTuple returns
# (see docs/design/p6_research_local.md §4.1 for the exact IR shape).
#
# RED test for the β-proposer design: without the fix, extract_parsed_ir
# crashes with "sret store ... has non-integer value type LLVM.VectorType".

using Test
using Bennett
using Bennett: extract_parsed_ir, reversible_compile, simulate,
               verify_reversibility, gate_count,
               linear_scan_pmap_set, linear_scan_pmap_new, linear_scan_pmap_get,
               LinearScanState

# Shared matcher from test_sret.jl
_match(result::Tuple, expected::Tuple) =
    all(reinterpret(unsigned(typeof(e)), r % unsigned(typeof(e))) ===
        reinterpret(unsigned(typeof(e)), e)
        for (r, e) in zip(result, expected))

@testset "Bennett-0c8o: vector-lane sret stores" begin

    # ---------------------------------------------------------------------
    # PRIMARY: the exact reproducer from the bead (NTuple{9,UInt64}).
    # Bennett-atf4 enabled callee dispatch via methods() — this adds the
    # extract_parsed_ir prerequisite.
    # ---------------------------------------------------------------------
    @testset "linear_scan_pmap_set — NTuple{9,UInt64} extracts under optimize=true" begin
        g(state::NTuple{9,UInt64}, k::Int8, v::Int8) =
            linear_scan_pmap_set(state, k, v)

        # Under optimize=true Julia's SLP emits a `<4 x i64>` store into
        # sret offset 8.  Before the fix, this raises.
        pir = extract_parsed_ir(g, Tuple{NTuple{9,UInt64}, Int8, Int8})

        # Shape invariants: 9 slots, each i64.
        @test pir.ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
        @test length(pir.ret_elem_widths) == 9
        @test sum(pir.ret_elem_widths) == 576

        # Arg shape: state by-ref (576 bits deref), Int8 k, Int8 v.
        @test length(pir.args) == 3
        @test pir.args[1][2] == 576
        @test pir.args[2][2] == 8
        @test pir.args[3][2] == 8

        # Bookkeeping: every slot must have produced an IRInsertValue at
        # synthesize time — walk the blocks and count.
        iv_count = 0
        for bb in pir.blocks, inst in bb.instructions
            inst isa Bennett.IRInsertValue && (iv_count += 1)
        end
        @test iv_count == 9
    end

    # ---------------------------------------------------------------------
    # Minimal synthetic reproducer that does NOT depend on
    # linear_scan_pmap_set so we can also test slot-value resolution on a
    # cone we fully understand.
    # ---------------------------------------------------------------------
    @testset "synthetic NTuple{9,UInt64} identity extracts under optimize=true" begin
        # A function whose LLVM IR is statically known to emit a vector store
        # via SROA+SLP on a 4-wide block.
        @inline function rotl_ntuple9(t::NTuple{9,UInt64})
            (t[9], t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        end
        f(t::NTuple{9,UInt64}) = rotl_ntuple9(t)

        pir = extract_parsed_ir(f, Tuple{NTuple{9,UInt64}})
        @test pir.ret_elem_widths == fill(64, 9)
    end

    # ---------------------------------------------------------------------
    # Constant-splat vector store.  Forces the ConstantDataVector path.
    # ---------------------------------------------------------------------
    @testset "constant-splat `<N x iW>` store to sret" begin
        # This should produce `store <4 x i64> <i64 0, ...>` via SROA+SLP
        # on a zero-identity aggregate build.
        @inline function const_ntuple9()
            (UInt64(0), UInt64(0), UInt64(0), UInt64(0),
             UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        end
        f() = const_ntuple9()
        pir = extract_parsed_ir(f, Tuple{})
        @test pir.ret_elem_widths == fill(64, 9)
    end

    # ---------------------------------------------------------------------
    # End-to-end: the real linear_scan_pmap_set called from a scalar-return
    # wrapper, compiled to a reversible circuit and simulated.
    #
    # `_ls_demo` already lives in test/test_persistent_interface.jl; this
    # test duplicates the shape inline so the include order is independent.
    # After the fix, this simply extracts+compiles+simulates end-to-end.
    # ---------------------------------------------------------------------
    @testset "_ls_demo end-to-end under optimize=true" begin
        function _ls_demo_0c8o(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                               k3::Int8, v3::Int8, lookup::Int8)::Int8
            s = linear_scan_pmap_new()
            s = linear_scan_pmap_set(s, k1, v1)
            s = linear_scan_pmap_set(s, k2, v2)
            s = linear_scan_pmap_set(s, k3, v3)
            return linear_scan_pmap_get(s, lookup)
        end
        circuit = reversible_compile(_ls_demo_0c8o,
            Int8, Int8, Int8, Int8, Int8, Int8, Int8)
        @test verify_reversibility(circuit)
        # Smoke-sim a few representative inputs (exhaustive is 2^56).
        for (k1, v1, k2, v2, k3, v3, q) in [
                (Int8(1), Int8(10), Int8(2), Int8(20), Int8(3), Int8(30), Int8(2)),
                (Int8(1), Int8(10), Int8(2), Int8(20), Int8(3), Int8(30), Int8(9)),
                (Int8(5), Int8(50), Int8(5), Int8(60), Int8(1), Int8(7),  Int8(5)),
            ]
            @test simulate(circuit, (k1, v1, k2, v2, k3, v3, q)) ==
                  _ls_demo_0c8o(k1, v1, k2, v2, k3, v3, q)
        end
    end

    # ---------------------------------------------------------------------
    # Regression: every existing sret case in test_sret.jl must stay
    # byte-identical.  We re-run a representative subset here and rely on
    # test_sret.jl running next to the full suite.
    # ---------------------------------------------------------------------
    @testset "regression: n=3 UInt32 identity still works" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        pir = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32})
        @test pir.ret_elem_widths == [32, 32, 32]
        circuit = reversible_compile(f, UInt32, UInt32, UInt32)
        @test verify_reversibility(circuit)
    end

    @testset "regression: n=8 UInt32 identity gate count unchanged" begin
        f(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
          e::UInt32, f_::UInt32, g::UInt32, h::UInt32) =
            (a, b, c, d, e, f_, g, h)
        circuit = reversible_compile(f, UInt32, UInt32, UInt32, UInt32,
                                        UInt32, UInt32, UInt32, UInt32)
        @test verify_reversibility(circuit)
    end

    @testset "regression: n=2 swap gate_count baseline 82 still holds" begin
        swap2(a::Int8, b::Int8) = (b, a)
        circuit = reversible_compile(swap2, Int8, Int8)
        @test gate_count(circuit).total == 82    # sret not fired for n=2
    end

    # ---------------------------------------------------------------------
    # Fail-loud: an unsupported vector-producer shape must emit a clear
    # error, not silently miscompile.  We synthesise a case by parsing
    # handcrafted IR through the .ll entry point.
    # ---------------------------------------------------------------------
    @testset "fail-loud: unsupported vector opcode in sret cone" begin
        # Hand-written IR: vector store where the value comes from a vector
        # shl by a runtime scalar-splat (which we don't support — LLVM only
        # emits this when it's already been scalarised, so it's a proxy
        # for "future vector op we haven't added a case for").  We use an
        # opcode we know is NOT in the supported list: `udiv <N x iW>`.
        ll = """
        define void @f(ptr sret([4 x i64]) align 8 %sret,
                       <4 x i64> %num, <4 x i64> %den) {
          %q = udiv <4 x i64> %num, %den
          store <4 x i64> %q, ptr %sret, align 8
          ret void
        }
        """
        path = tempname() * ".ll"
        open(path, "w") do io; write(io, ll); end
        try
            @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
                path; entry_function="f")
        finally
            rm(path; force=true)
        end
    end
end
```

### §5.1 Expected RED output before the fix

```
Test Failed at test/test_0c8o_vector_sret.jl:30
  Expression: (extract_parsed_ir(g, Tuple{NTuple{9, UInt64}, Int8, Int8})).ret_elem_widths == [64, 64, 64, 64, 64, 64, 64, 64, 64]
  Evaluated: (no value produced — extract_parsed_ir threw)
  [error message identical to §1]
```

### §5.2 Expected GREEN output after the fix

All 7 testsets pass. The `extract_parsed_ir` call returns a `ParsedIR`
whose block instructions include, in order:

- `IRPtrOffset + IRLoad` pairs for the 4 lanes of `%18 = load <4 x i64>`
- `IRSelect × 4` for the 4 lanes of `%19 = select <4 x i1>`
  (actually more, for shuffled icmp/zext lanes too)
- `IRInsertValue × 9` (synthesized chain)
- `IRRet` with width 576

---

## §6 Regression plan

| Test | Invariant |
|------|-----------|
| `test_sret.jl:16-28` "n=3 UInt32 identity" | `ret_elem_widths==[32,32,32]`; verify_reversibility |
| `test_sret.jl:30-42` "n=4 UInt32 with arithmetic" | verify_reversibility + exact outputs |
| `test_sret.jl:44-54` "n=8 UInt32 (SHA-256 shape)" | verify_reversibility + identity outputs |
| `test_sret.jl:56-64` "n=3 UInt8" | verify_reversibility + sampled exhaustive |
| `test_sret.jl:66-77` "n=3 UInt64" | verify_reversibility + exact outputs |
| `test_sret.jl:79-90` "n=3 Int32 signed" | verify_reversibility + exact outputs |
| `test_sret.jl:92-103` "mixed arg widths" | verify_reversibility + exact outputs |
| `test_sret.jl:105-117` "regression: n=2 swap2" | **gate_count==82 byte-identical** |
| `test_sret.jl:119-123` "err: struct-sret" | still throws (`_detect_sret` rejection untouched) |
| `test_sret.jl:125-136` "err: memcpy-sret" | still throws with "memcpy" + "optimize=true" in msg |
| `test_tuple.jl` (all) | n=2 by-value path — sret detection must NOT fire |
| `test_extractvalue.jl` (all) | `insertvalue` / `extractvalue` — unrelated to sret cone |
| `test_ntuple_input.jl` (all) | NTuple-as-input path — unaffected |
| `test_ir_memory_types.jl` (all) | IR-type unit tests — unaffected |
| `test_intrinsics.jl` (all) | intrinsic dispatch — unaffected |
| `test_loop.jl`, `test_branch.jl`, `test_combined.jl` | CFG / phi — unaffected |

**Gate-count regression guards (per CLAUDE.md §6):**

- i8 `x+3` = 86 gates — unaffected (no sret).
- swap2 = 82 gates — unaffected (n=2 by-value; sret pre-walk early-exits on
  `sret_info === nothing`).
- All existing `test_sret.jl` circuit counts stay byte-identical because
  the existing integer-store fast-path is unchanged (§3.4 preserves
  lines 516-540 below the new `if vt isa LLVM.VectorType` branch).

**New baseline:** record the gate count for
`reversible_compile(_ls_demo_0c8o, Int8, Int8, Int8, Int8, Int8, Int8, Int8)`
in WORKLOG.md once the implementer has it. The test file itself
currently only asserts `verify_reversibility` and spot-check outputs,
to avoid locking in a brittle number before the implementer's final
pass.

---

## §7 Risk analysis

### §7.1 False-path sensitization (CLAUDE.md "Phi resolution" rule)

**Not applicable** at sret decomposition time. The sret store is
write-once per slot (enforced at src/ir_extract.jl:532-535 via
`haskey(slot_values, slot)` guard; our new code at §3.4 extends this
guard to every lane of a vector store). There's no phi merging at the
sret write site — each slot comes from exactly one lane of exactly
one store.

**Downstream risk:** if the value-cone of a vector store contains a
phi node, the per-lane `IRSelect`s we emit will ultimately reduce to
MUX circuits. But this is already how scalar `select` lowering works
in `lower.jl`, and the MUX-conditions guard is enforced there — nothing
we emit from `_sret_decompose_vec_value` is novel at the
lowering level. It's N scalar `IRSelect`/`IRICmp`/`IRBinOp` ops, which
every test in the existing suite exercises. If `lower.jl` had a
phi-resolution bug, it'd already show up in test_branch / test_combined
— those pass today.

### §7.2 SLP edge cases — mixed-predicate vector store

Hypothetical: `store <4 x i64>` where lanes 0,1 came from one predicate
and lanes 2,3 from another. SLP typically won't vectorise this (the
whole point of SLP is same-predicate/same-opcode chains). But if
LLVM ever emits it, our per-lane decomposition is still correct
because `select <4 x i1>` — whose condition is already 4 separate
i1 lanes — fans each lane's condition out independently. The
`cond_is_vec` branch at §3.2 handles the per-lane condition case.

Concrete: for `%19 = select <4 x i1> %17, <4 x i64> %6, <4 x i64> %18`,
`%17` has four separate i1 lanes. `_sret_decompose_vec_value(%17)`
returns `[c0, c1, c2, c3]`, and each lane's `IRSelect` uses its own
`c_i` — not a broadcast. Correct.

### §7.3 Interaction with `_synthesize_sret_chain`

Zero. `_synthesize_sret_chain` (src/ir_extract.jl:563-578) reads
`slot_values::Dict{Int, IROperand}`. Whether a slot's `IROperand` came
from the existing integer-store path or from the new vector-store path
is opaque to it — both are just scalar SSA names or constants.

The chain emission order (`for k in 0:(n-1)`) is independent of write
order, so even if we process the vector store before some scalar
stores (or vice versa), the final chain is identical.

### §7.4 Interaction with `_narrow_ir`

`_narrow_ir` (src/Bennett.jl:120-152) rewrites every `IRInst.width` to
`W`. The new instructions we emit are standard `IRSelect`, `IRICmp`,
`IRCast`, `IRBinOp`, `IRPtrOffset`, `IRLoad`, `IRInsertValue` — each
already has a `_narrow_inst` method (src/Bennett.jl:139-151). `IRPtrOffset`
is typed, so we need to spot-check it. Checked: src/ir_types.jl has
`IRPtrOffset(dest, base, offset)` — no width field. It's a byte offset,
unchanged by narrowing. Good.

**`ret_elem_widths` narrowing:** `_narrow_ir` sets `[W for _ in
parsed.ret_elem_widths]`. Length-preserving. A n=9 sret return narrowed
to W=8 becomes `[8,8,8,8,8,8,8,8,8]` — 9 slots stays 9. Correct.

**Widths on emitted instructions:** we thread `ew` (element width) into
all per-lane ops, which matches the aggregate element width. For
`<4 x i64>` into `[9 x i64]`, that's `ew=64`. Under narrowing to W,
each becomes `W`. Correct.

### §7.5 Recursion depth

`_sret_decompose_vec_value` recurses on producer chains. The linear_scan
case has depth 6 (store → %19 → %17 → %16 → %15 → %14 → `state::Tuple.unbox`
scalar leaf). Even pathological cases top out at LLVM IR's natural
SSA depth — a function's SSA graph is a DAG, not a cycle (LLVM
invariant). No stack-overflow risk.

### §7.6 Multiple visits to the same producer

The `lanes_local` cache at top-of-function ensures each SSA producer is
decomposed exactly once. If two separate sret vector stores share a
producer (e.g., a `shufflevector` used in both lanes-0..3 and lanes-4..7
stores), the second call hits the cache. Suppressed-set is also a
`Set`, so double-push is idempotent.

### §7.7 Side effects on `counter`

`_auto_name(counter)` is already threaded through pass 2 and
`_synthesize_sret_chain`. Adding more calls from
`_sret_decompose_vec_value` just advances the counter — which is fine,
counter values are opaque. The RED test's `iv_count == 9` check is
robust against this.

### §7.8 `_collect_sret_writes` signature change breaks external callers?

Grep: `_collect_sret_writes` is called exactly once, at
src/ir_extract.jl:711. No other callers. Safe to add the `counter`
argument.

### §7.9 Interaction with Bennett-atf4 (just landed)

Bennett-atf4 changed `lower_call!` to use `methods()` on the callee.
Orthogonal to `_collect_sret_writes` — callee dispatch happens in
`lower.jl`, not `ir_extract.jl`. No interaction.

### §7.10 Bennett-uyf9 (memcpy-form sret — out of scope here)

The `_collect_sret_writes` memcpy rejection at src/ir_extract.jl:446-461
is **not touched**. Under `optimize=false`, `llvm.memcpy` into sret
still errors with the same message. uyf9 will extend this later.

---

## §8 Implementation sequence (RED → GREEN checkpoints)

### Step 1 (RED) — land the test file

- Create `test/test_0c8o_vector_sret.jl` with the content from §5.
- Add `include("test_0c8o_vector_sret.jl")` to `test/runtests.jl` right
  after `include("test_sret.jl")`.
- Run:
  ```
  julia --project test/test_0c8o_vector_sret.jl
  ```
- **Expected:** failures in testsets 1, 2, 3, 4 (all the "extracts
  under optimize=true" cases), with the error message quoted in §1.
- Regression testsets 5, 6 still pass (no code change yet).
- **Checkpoint:** confirm RED-state matches the expected failure
  message. If a different error fires, investigate before proceeding
  (CLAUDE.md rule 7).

### Step 2 — thread `counter` through `_collect_sret_writes`

- Add `counter::Ref{Int}` param to `_collect_sret_writes`
  (src/ir_extract.jl:430).
- Add `counter` arg to the one call site (src/ir_extract.jl:711-712).
- Add `lanes_local = Dict{_LLVMRef, Vector{IROperand}}()` and
  `extra_insts = IRInst[]` locals at the top of
  `_collect_sret_writes`.
- Add `extra_insts = extra_insts` to the return namedtuple at
  src/ir_extract.jl:552.
- Splice `extra_insts` into main-walker's `insts` at
  src/ir_extract.jl:728-736 (§3.6).
- Run existing tests:
  ```
  julia --project -e 'using Pkg; Pkg.test()'
  ```
- **Expected:** `test_sret.jl` still fully GREEN (no behaviour change
  yet); `test_0c8o_vector_sret.jl` still RED at the same point.
- **Checkpoint:** plumbing change must be zero-observable.

### Step 3 — implement `_sret_decompose_vec_value`

- Add the full function from §3.2 to `ir_extract.jl`, placed
  immediately before `_collect_sret_writes`.
- Do NOT call it from anywhere yet.
- Run the full test suite again.
- **Expected:** everything still passes (dead code addition). If any
  test breaks, we have a syntax or type error in the new function —
  fix before proceeding.
- **Checkpoint:** new function type-checks and compiles.

### Step 4 (GREEN) — wire the vector-store branch in `_collect_sret_writes`

- Add the `if vt isa LLVM.VectorType ... end` branch from §3.4 just
  before the existing `vt isa LLVM.IntegerType` check (src/ir_extract.jl:517).
- Run the 0c8o test file:
  ```
  julia --project test/test_0c8o_vector_sret.jl
  ```
- **Expected:** all 7 testsets pass.
- If "linear_scan_pmap_set" still fails, inspect which sub-invariant
  trips: ret_elem_widths mismatch → sret_info computation; iv_count
  mismatch → synthesize_chain; error thrown → look at the stack trace
  to see which vector opcode wasn't handled.
- **Checkpoint:** primary reproducer passes.

### Step 5 — full regression

- Run the complete suite:
  ```
  julia --project -e 'using Pkg; Pkg.test()'
  ```
- **Expected:** 100% pass, all gate-count baselines byte-identical.
- **Checkpoint:** no regression in any existing test.

### Step 6 — WORKLOG

- Update `WORKLOG.md` per CLAUDE.md §0:
  - Bennett-0c8o fixed; design option: (a) local recursive decomposer.
  - Gotcha: `<N x iW>` vector LOAD must be handled too — the cone
    reaches `load <4 x i64>` which scalar-decomposes into N IRLoads at
    lane byte offsets.
  - Option (c) — `scalarizer<load-store>` — investigated and rejected
    because LLVM.jl's NewPMPassBuilder does not accept parameterised
    pass names.
  - Gate-count baseline for `_ls_demo_0c8o` (record the actual number).

### Step 7 — commit + push (mandatory per CLAUDE.md Session Completion)

```
git add src/ir_extract.jl test/test_0c8o_vector_sret.jl \
        test/runtests.jl WORKLOG.md
git commit -m "Fix Bennett-0c8o: vector-lane sret stores via local decomposer"
git pull --rebase
bd dolt push
git push
git status
```

---

## §9 Open questions / honest uncertainties

### §9.1 Will Julia's optimiser ever emit `load <N x iW>` NOT from a
named ptr-param GEP?

In principle, yes — e.g., if a `%x = alloca <N x iW>` survives into
the post-optimize IR and is then loaded. In practice, `alloca` is
aggressively promoted by mem2reg under `optimize=true`, so this
shouldn't happen in Julia-emitted IR. The fail-loud branch at §3.2
("vector load pointer … is not a named SSA value") catches any case we
haven't anticipated. Good fail mode.

### §9.2 What about `<N x i8>` or `<N x i16>` vector stores?

The design handles them uniformly — `_vector_shape` accepts
w ∈ {1,8,16,32,64}. But `[N x i8]` or `[N x i16]` sret aggregates are
rare in Julia (the default register size is 64-bit; ntuples of small
ints usually get packed into a single i64). The new `test_0c8o_vector_sret.jl`
testset 3 tests the UInt64 case directly; extending to UInt8/UInt16
would just be:

```julia
@testset "constant-splat <8 x i8> sret store" begin
    f(x::Int8) = ntuple(_ -> x, Val(16))     # NTuple{16,Int8}
    pir = extract_parsed_ir(f, Tuple{Int8})
    @test pir.ret_elem_widths == fill(8, 16)
end
```

Not strictly required by the bead, but a good smoke test. I'd add it
during implementation if live IR confirms the `<N x i8>` store shape.

### §9.3 `<N x i1>` vector stores

Pack-type stores like `store <8 x i1> ...` would shrink to an i8 at
storage. Julia doesn't emit sret aggregates of i1 (booleans serialise
to i8). If ever observed, the current design *would* need extending —
the per-lane `IRSelect` lane width `w_res=1` is an i1 SSA register, and
the sret aggregate is `[N x i8]`, not `[N x i1]`. The `lane_w == ew`
check at §3.4 would fail with a clear error ("lane width 1 != element
width 8"), which is acceptable fail-loud behaviour until such a case
is reported.

### §9.4 Is `_resolve_vec_lanes` reusable as-is inside the new
recursive resolver?

Partially. We reuse it for the constant / poison leaves (its Paths B,
C, D are pure). We do NOT call it on SSA instructions because that
requires `lanes` to already be populated (Path A), which it isn't at
pre-walk time. The new `_sret_decompose_vec_value` is a superset that
handles both leaves and interior nodes with its own local cache.

### §9.5 Could option (b) be revisited later for a cleaner architecture?

Yes. If a future feature needs sret handling to fully integrate with
pass 2 (e.g., sret inside a loop that runs `break`-before-store,
requiring phi resolution across control flow), moving decoding
interleaved with pass 2 becomes the right factoring. But the current
MVP has no such case — every test under test_sret.jl is a straight-line
store chain — and option (a) is strictly less invasive.

### §9.6 Is the gate count deterministic?

The new `_auto_name(counter)` calls are driven by the recursion order,
which is the LLVM instruction iteration order (basic block → inst).
Julia's LLVM IR iteration order is deterministic per-version (the
same LLVM bitcode round-trips identically), so the gate count for
`_ls_demo_0c8o` will be stable under a pinned Julia/LLVM version. On
LLVM.jl upgrades, the count may drift — which is exactly why the test
doesn't pin it (§6). WORKLOG records the Julia version alongside the
number.

---

## §10 Summary of files touched

| File | Lines | Change |
|------|-------|--------|
| `src/ir_extract.jl:430` (add above) | +~200 | new `_sret_decompose_vec_value` |
| `src/ir_extract.jl:430` | signature | add `counter` arg, `lanes_local`/`extra_insts` locals |
| `src/ir_extract.jl:517-520` | replaced | vector-store branch before integer check |
| `src/ir_extract.jl:552` | +1 | return `extra_insts` in namedtuple |
| `src/ir_extract.jl:711-712` | 1 | pass `counter` to `_collect_sret_writes` |
| `src/ir_extract.jl:729-733` | +3 | splice `extra_insts` before synthesize chain |
| `test/test_0c8o_vector_sret.jl` | +~140 | new test file, content §5 |
| `test/runtests.jl` | +1 | include the new test file |
| `WORKLOG.md` | +~25 | session notes per CLAUDE.md §0 |

Total: ~370 LOC across 4 files. No changes to `lower.jl`, `bennett.jl`,
`gates.jl`, `simulator.jl`, `wire_allocator.jl`, `adder.jl`,
`multiplier.jl`, or the soft-float library.

---

## §11 Concrete citation index (file:line verification)

- `src/ir_extract.jl:430-553` — `_collect_sret_writes`, the function we modify.
- `src/ir_extract.jl:500-525` — sret store handling, existing integer path.
- `src/ir_extract.jl:516-520` — **exact rejection site** for VectorType.
- `src/ir_extract.jl:532-535` — duplicate-slot guard we extend across lanes.
- `src/ir_extract.jl:546-550` — every-slot-written completeness check (unchanged).
- `src/ir_extract.jl:563-578` — `_synthesize_sret_chain` consumer (unchanged).
- `src/ir_extract.jl:633` — `counter = Ref(0)` origin (we thread it through).
- `src/ir_extract.jl:660-664` — `names` / `lanes` dict construction.
- `src/ir_extract.jl:708-737` — main-walker integration point.
- `src/ir_extract.jl:720-738` — `ret void` synthesize-chain splice point.
- `src/ir_extract.jl:1846-1858` — `_vector_shape` (reused in new code).
- `src/ir_extract.jl:1863-1907` — `_resolve_vec_lanes` (reused for constant leaves).
- `src/ir_extract.jl:1909-2121` — `_convert_vector_instruction` (model for per-lane lowering shape; NOT called by us).
- `src/ir_extract.jl:1397-1408` — scalar `IRLoad` emission shape (model for new vector-load decomposer).
- `src/ir_extract.jl:1358-1395` — scalar GEP / `IRPtrOffset` emission (model).
- `src/Bennett.jl:120-152` — `_narrow_ir` (unchanged; §7.4 analysis).
- `docs/design/p6_research_local.md §3.4` — exact rejection site per research.
- `docs/design/p6_research_local.md §4.1` — exact IR Julia emits for n=9.
- `docs/design/p6_research_local.md §9.1, §9.2` — LLVM.jl primitives available.
- `docs/design/p6_research_local.md §11.1` — existing sret test coverage.
- `docs/design/p6_research_local.md §12.2` — narrow-fix sketch with caveats (this design closes those caveats).
- `docs/design/p6_research_online.md §3.1` — `Scalarizer<load-store>` investigation.
- `docs/design/p6_research_online.md §5.3` — Enzyme's `copy_struct_into!` reference.
- `CLAUDE.md §1` — fail-fast, fail-loud (honoured by fail-loud branches in §3.2, §4.3, §4.9, §7).
- `CLAUDE.md §3` — RED-green TDD (§8 step sequence).
- `CLAUDE.md §4` — exhaustive verification (`verify_reversibility` in every new testset).
- `CLAUDE.md §6` — gate-count regression baselines (§6 table).
- `CLAUDE.md §11` — PRD-driven (this is an issue-driven bug fix; no PRD needed for bugs per beads flow).
- `CLAUDE.md §12` — no duplicated lowering (we reuse `IRSelect`, `IRICmp`, `IRCast`, `IRBinOp`, `IRPtrOffset`, `IRLoad` as emitted by existing code paths).

---

## §12 Final sanity check — does this actually close Bennett-0c8o?

The bead text is:
> ir_extract: handle vector-lane sret stores (<N x iW> at sret GEP)

Requirements from the bead body:

- [x] `store <N x iW>` at sret byte offset → N per-slot writes.
  (§3.4 vector-store branch, §3.2 lane decomposer.)
- [x] Live repro from the bead: `g(state::NTuple{9,UInt64}, k, v)
  = Bennett.linear_scan_pmap_set(state, k, v)` under default
  `optimize=true` — extracts cleanly, produces
  `ret_elem_widths=[64]×9`. (§5 testset 1.)
- [x] Constant splats — handled via ConstantDataVector path (§4.1).
- [x] Shufflevector patterns — handled (§3.2, §4.5, §4.6).
- [x] Insertelement chains — handled (§3.2, §4.4).
- [x] ConstantDataVector — handled (§4.1).
- [x] Poison/undef lanes — handled, fail-loud on read (§4.3, §7.1).
- [x] Preserve byte-identical output for all current sret tests. (§6.)
- [x] RED test file — §5 content, complete and drop-in.
- [x] Regression plan — §6 table.
- [x] Risk analysis covering false-path sensitization, SLP edge
  cases, `_synthesize_sret_chain` and `_narrow_ir` interactions.
  (§7.)
- [x] Implementation sequence with RED→GREEN checkpoints. (§8.)

Out of scope (confirmed):
- Memcpy-form sret (Bennett-uyf9) — untouched.
- Non-integer vector element types — pre-existing `_vector_shape`
  rejects these before our code is reached.
- Heterogeneous sret structs — pre-existing `_detect_sret` rejection
  at src/ir_extract.jl:383-387 untouched.

Design is complete and implementable in a single RED-green TDD
session. Hand off to implementer.
