# cc0.7 Consensus — Vector SSA scalarisation in `ir_extract.jl`

**Bead**: Bennett-cc0.7 — extend `ir_extract.jl` to handle LLVM vector ops
(`insertelement`, `extractelement`, `shufflevector`, and vector variants of
`add`/`sub`/`mul`/`and`/`or`/`xor`/`shl`/`lshr`/`ashr`/`icmp`/`select`/`sext`/`zext`/`trunc`/`bitcast`)
so `optimize=true` no longer crashes on SLP-vectorised IR.

**RED target**: `test/test_cc07_repro.jl` using fixture
`benchmark/cc07_repro_n16.jl::ls_demo_16`. Empirically confirmed 2026-04-20
that extraction crashes at `insertelement <8 x i8> poison, i8 %seed, i64 0`
(see `/tmp/cc07_n16_ir.ll`).

**Proposers**: `docs/design/cc07_proposer_A.md` (1,235 lines),
`docs/design/cc07_proposer_B.md` (1,055 lines). Both converged on the same
high-level shape.

---

## Convergence

Both proposers independently chose **scalar lane-expansion at extraction time**:

- Every `<N x iM>` vector SSA is modelled as a list of `N` per-lane `IROperand`s
  stored in a new side table keyed on `LLVM.Value.ref`.
- `insertelement` / `shufflevector` are **pure SSA plumbing** — mutate the
  side table, emit no IR instruction (return `nothing` from the handler).
- Vector `add`/`icmp`/`select`/`cast` are desugared into `N` scalar `IRBinOp` /
  `IRICmp` / `IRSelect` / `IRCast` (one per lane).
- **Zero touches to `lower.jl`, `bennett.jl`, `ir_types.jl`, `simulator.jl`.**
- Constant vectors (`<i8 16, i8 18, ...>`) are constant-folded at extraction
  into per-lane `iconst`s; `poison`/`undef` lanes map to a sentinel that
  crashes fail-loud if ever read.

This matches the bead's suggestion ("walk the vector operand as if it were a
tuple — each element has a definite source") and CLAUDE.md §12 (no duplicated
lowering) since every scalar gate path already exists.

## Divergence (synthesised choices)

### Choice 1 — Side-table type

| Proposer | Representation |
|---|---|
| A | `Dict{_LLVMRef, Vector{Union{Symbol, IROperand}}}` (mixed) |
| **B (chosen)** | `Dict{_LLVMRef, Vector{IROperand}}` (uniform) |

**Winner: B.** Uniform `IROperand` avoids Union dispatch on every lane read and
matches how `_operand` already returns values throughout the extractor.
Concretely: `ssa(sym)` vs `iconst(k)` are both `IROperand`, and constant-lane
resolution doesn't need a special branch at use sites.

### Choice 2 — Pass-1 vs pass-2 lane-table population

| Proposer | Timing |
|---|---|
| A | Pre-allocate per-lane Symbols in an extended pass 1 |
| **B (chosen)** | Populate during pass 2 in source order |

**Winner: B.** B's rationale is correct: pure-aliasing vector results
(`insertelement`, `shufflevector`) don't need new Symbols — their lanes alias
existing SSA. Pre-allocating in pass 1 creates dead `__v$k` names that never
appear in any emitted `IRInst`. Pass-2 late-binding populates the table during
handler dispatch; `_resolve_vec_lanes` asserts the producer ran before any
consumer (guaranteed because LLVM SSA within a block is topologically ordered).

### Choice 3 — Shuffle-mask accessor

B cites `LLVM.API.LLVMGetShuffleVectorMaskElement` (post-LLVM-11 metadata
accessor). A cites `LLVM.API.LLVMGetNumMaskElements` + `LLVMGetMaskValue`.

**Winner: B's name, verified at implementation time.** The implementer must
verify the exact symbol — per the feedback memory ("always extract and inspect
actual references before coding"). If the LLVM.jl version in use exposes it
under a different name, substitute at implementation time; don't trust this
doc over `grep LLVMGetShuffle ~/.julia/packages/LLVM/`.

### Choice 4 — `extractelement` gate model (the load-bearing uncertainty)

**Both proposers cited the `freeze` handler** (`ir_extract.jl:1141–1146`) as
the zero-gate precedent for rename-via-add-zero. **Empirical check
2026-04-20 falsified this**:

```julia
f(x::Int8) = x + Int8(0)   # produces IRBinOp(:add, x, iconst(0), 8)
reversible_compile(f, Int8) |> gate_count   # => 10 gates (2 NOT + 8 CNOT)
```

So `IRBinOp(:add, lane, 0, w)` emits roughly `W + 2` gates, not zero.

**Consensus decision: accept the known non-zero cost for MVP; defer
optimization.**

Rationale:
- For `ls_demo_16`: 8 extractelements × ~10 gates = 80 extra gates; total
  circuit is on the order of 10k+ gates (persistent-DS sweep data). <1%
  impact.
- The cleaner "true rename" approach (mutate `names[extract_inst.ref] = lane.ssa_symbol`
  when the lane is `ssa`, plus `value_aliases::Dict{_LLVMRef, IROperand}` for
  constant lanes read through `_operand`) is a strictly additive optimization
  that can land as a follow-up bead once the correctness floor is in.
- The bigger payoff is unlocking `optimize=true` (3–50× reduction from sroa /
  mem2reg / instcombine / simplifycfg running), which swamps the 80-gate tax.

**Implementer must**:
1. Implement `extractelement` constant-idx path as `IRBinOp(:add, lane_op, iconst(0), w)`
   (consistent with freeze precedent; correctness-obvious; empirical cost
   ~W+2 gates per extract).
2. Add an explicit comment citing this consensus doc: "known non-zero cost;
   follow-up optimization tracked elsewhere."
3. Measure post-fix gate count on `ls_demo_16` and log the delta vs
   `optimize=false` baseline (the sweep file has numbers at N=16:
   optimize=false emitted 22,902 gates).

### Choice 5 — Dispatch gate location

Both converged on a single guard at the top of `_convert_instruction`:

```julia
is_vec_result   = LLVM.value_type(inst) isa LLVM.VectorType
any_vec_operand = any(LLVM.value_type(o) isa LLVM.VectorType
                      for o in LLVM.operands(inst))
if is_vec_result || any_vec_operand
    return _convert_vector_instruction(inst, names, lanes, counter)
end
# … existing scalar handlers unchanged below …
```

This is the zero-churn property: existing scalar paths are byte-identical.

---

## Chosen design (the contract for the implementer)

### §1 New side table

Add to `_module_to_parsed_ir` beside `names`:

```julia
lanes = Dict{_LLVMRef, Vector{IROperand}}()
```

Thread `lanes` as the fourth positional argument to `_convert_instruction`
(and any helper that dispatches vector handlers). All existing scalar handlers
are unchanged (they never read or write `lanes`).

### §2 New helpers

```julia
# Returns (n_lanes, elem_width) if `val` has type <N x iM> for M ∈ {1,8,16,32,64};
# nothing for non-vector values. Errors on non-integer element types or widths
# outside the supported set.
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    et isa LLVM.IntegerType ||
        error("vector with non-integer element type $et is not supported; " *
              "got vector type $vt (Bennett-cc0.7 MVP scope).")
    w = LLVM.width(et)
    w ∈ (1, 8, 16, 32, 64) ||
        error("vector element width $w is not supported; expected 1/8/16/32/64. " *
              "Got vector type $vt.")
    return (Int(LLVM.length(vt)), Int(w))
end

# Decode a value's N lanes into IROperands. Handles already-populated SSA
# vectors (via `lanes`), ConstantDataVector, ConstantAggregateZero,
# UndefValue/PoisonValue, and errors fail-loud on anything else.
function _resolve_vec_lanes(val::LLVM.Value,
                             lanes::Dict{_LLVMRef, Vector{IROperand}},
                             names::Dict{_LLVMRef, Symbol},
                             n_expected::Int)::Vector{IROperand}
    # Path A: previously-processed SSA vector → read from `lanes`.
    if haskey(lanes, val.ref)
        got = lanes[val.ref]
        length(got) == n_expected ||
            error("vector lane-count mismatch on $(string(val)): expected " *
                  "$n_expected, got $(length(got))")
        return got
    end
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType ||
        error("_resolve_vec_lanes called on non-vector value: $(string(val))")
    got_n = Int(LLVM.length(vt))
    got_n == n_expected ||
        error("vector lane-count mismatch: expected $n_expected, got $got_n")
    # Path B: constant-vector literal.
    if val isa LLVM.ConstantDataVector
        out = Vector{IROperand}(undef, got_n)
        for i in 0:(got_n - 1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(val.ref, i)
            elt = LLVM.Value(elt_ref)
            elt isa LLVM.ConstantInt ||
                error("vector constant element at lane $i is not ConstantInt: $(string(elt))")
            out[i + 1] = iconst(convert(Int, elt))
        end
        return out
    end
    # Path C: zeroinitializer → all-zero.
    if val isa LLVM.ConstantAggregateZero
        return [iconst(0) for _ in 1:got_n]
    end
    # Path D: poison / undef → sentinel lanes. Reading these in a consumer is UB.
    if val isa LLVM.UndefValue || val isa LLVM.PoisonValue
        return [IROperand(:const, :__poison_lane__, 0) for _ in 1:got_n]
    end
    error("cannot resolve vector lanes for $(string(val)) :: $vt — not an " *
          "SSA vector, ConstantDataVector, ConstantAggregateZero, or poison/undef. " *
          "This is a Bennett-cc0.7 scope boundary; file a follow-up if needed.")
end
```

### §3 Dispatcher modification

At the top of `_convert_instruction` (line ~659, after `dest = names[inst.ref]`):

```julia
is_vec_result   = LLVM.value_type(inst) isa LLVM.VectorType
any_vec_operand = any(LLVM.value_type(o) isa LLVM.VectorType
                      for o in LLVM.operands(inst))
if is_vec_result || any_vec_operand
    return _convert_vector_instruction(inst, names, lanes, counter)
end
```

### §4 New `_convert_vector_instruction` function

Handles the six opcode categories. Signature:

```julia
function _convert_vector_instruction(inst::LLVM.Instruction,
                                     names::Dict{_LLVMRef, Symbol},
                                     lanes::Dict{_LLVMRef, Vector{IROperand}},
                                     counter::Ref{Int})::Union{Nothing, Vector{IRInst}, IRInst}
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

    # --- Pure SSA plumbing: emit no IR, mutate `lanes` ---

    if opc == LLVM.API.LLVMInsertElement
        ops = LLVM.operands(inst)
        base_vec = ops[1]; elem = ops[2]; idx_val = ops[3]
        idx_val isa LLVM.ConstantInt ||
            error("insertelement with dynamic lane index not supported: $(string(inst))")
        idx = convert(Int, idx_val)
        n = _vector_shape(inst)[1]
        (0 <= idx < n) ||
            error("insertelement lane index $idx outside [0,$n): $(string(inst))")
        base_lanes = _resolve_vec_lanes(base_vec, lanes, names, n)
        new_lanes = copy(base_lanes)
        # Scalar elem: use _operand (works for both ConstantInt and SSA).
        new_lanes[idx + 1] = _operand(elem, names)
        lanes[inst.ref] = new_lanes
        return nothing
    end

    if opc == LLVM.API.LLVMShuffleVector
        ops = LLVM.operands(inst)
        v1 = ops[1]; v2 = ops[2]
        n_src = _vector_shape(v1)[1]
        n_result = _vector_shape(inst)[1]
        v1_lanes = _resolve_vec_lanes(v1, lanes, names, n_src)
        v2_lanes = _resolve_vec_lanes(v2, lanes, names, n_src)
        out = Vector{IROperand}(undef, n_result)
        for i in 0:(n_result - 1)
            # IMPORTANT: verify the exact LLVM.jl accessor at impl time.
            # B cites LLVM.API.LLVMGetShuffleVectorMaskElement.
            # A cites LLVM.API.LLVMGetMaskValue + LLVMGetNumMaskElements.
            # grep: ~/.julia/packages/LLVM/*/lib/*/libLLVM.jl
            m = Int(LLVM.API.LLVMGetShuffleVectorMaskElement(inst.ref, i))
            if m == -1               # -1 encodes poison/undef in shuffle masks
                out[i + 1] = IROperand(:const, :__poison_lane__, 0)
            elseif 0 <= m < n_src
                out[i + 1] = v1_lanes[m + 1]
            elseif n_src <= m < 2 * n_src
                out[i + 1] = v2_lanes[m - n_src + 1]
            else
                error("shufflevector mask element $m out of range [0, $(2*n_src))")
            end
        end
        lanes[inst.ref] = out
        return nothing
    end

    # --- extractelement: lane rename via IRBinOp(:add, lane, 0, w) ---
    # See consensus doc §Choice 4: ~W+2 gates per extract, acceptable MVP cost.

    if opc == LLVM.API.LLVMExtractElement
        ops = LLVM.operands(inst)
        vec = ops[1]; idx_val = ops[2]
        n = _vector_shape(vec)[1]
        vec_lanes = _resolve_vec_lanes(vec, lanes, names, n)
        idx_val isa LLVM.ConstantInt ||
            error("extractelement with dynamic lane index not supported: $(string(inst))")
        idx = convert(Int, idx_val)
        (0 <= idx < n) ||
            error("extractelement lane index $idx outside [0,$n)")
        lane_op = vec_lanes[idx + 1]
        (lane_op.kind == :const && lane_op.name === :__poison_lane__) &&
            error("extractelement reads poison lane — undefined behaviour")
        w = _iwidth(inst)
        return IRBinOp(dest, :add, lane_op, iconst(0), w)
    end

    # --- Vector arithmetic: N scalar IRBinOps ---

    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        ops = LLVM.operands(inst)
        (n, w) = _vector_shape(inst)
        a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        sym = _opcode_to_sym(opc)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRBinOp(lane_dest, sym, a_lanes[i], b_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    if opc == LLVM.API.LLVMICmp
        ops = LLVM.operands(inst)
        # Result is <N x i1>; operand width is the element width of the operand vector.
        (n, _) = _vector_shape(inst)
        (_, op_w) = _vector_shape(ops[1])
        pred = _pred_to_sym(LLVM.predicate(inst))
        a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRICmp(lane_dest, pred, a_lanes[i], b_lanes[i], op_w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        (n, w) = _vector_shape(inst)
        cond = ops[1]
        cond_vt = LLVM.value_type(cond)
        cond_is_vec = cond_vt isa LLVM.VectorType
        cond_lanes = cond_is_vec ? _resolve_vec_lanes(cond, lanes, names, n) : nothing
        t_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        f_lanes = _resolve_vec_lanes(ops[3], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            c_op = cond_is_vec ? cond_lanes[i] : _operand(cond, names)
            lane_dest = _auto_name(counter)
            push!(insts, IRSelect(lane_dest, c_op, t_lanes[i], f_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        ops = LLVM.operands(inst)
        (n, w_to) = _vector_shape(inst)
        (n_src, w_from) = _vector_shape(ops[1])
        n_src == n || error("vector cast lane-count mismatch: $n_src vs $n")
        src_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            lane_dest = _auto_name(counter)
            push!(insts, IRCast(lane_dest, opname, src_lanes[i], w_from, w_to))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    if opc == LLVM.API.LLVMBitCast
        # Same-shape vector→vector bitcast = identity (alias).
        (n, w_to) = _vector_shape(inst)
        (n_src, w_from) = _vector_shape(LLVM.operands(inst)[1])
        (n_src == n && w_from == w_to) ||
            error("vector bitcast shape-change (lane/width) not supported: " *
                  "<$n_src x i$w_from> → <$n x i$w_to>. File a follow-up bead.")
        src_lanes = _resolve_vec_lanes(LLVM.operands(inst)[1], lanes, names, n)
        lanes[inst.ref] = copy(src_lanes)
        return nothing
    end

    error("Unsupported vector opcode $opc in instruction: $(string(inst))")
end
```

### §5 Out-of-scope (fail-loud)

- Vector floating-point ops (`FAdd`/`FSub`/`FMul`/`FDiv`/`FRem`) — soft-float
  dispatch assumed per-scalar; file follow-up if observed.
- Vector `load`/`store`/`alloca` — memory model unclear; none in the RED fixture.
- Vector `phi`/`ret` — none in the RED fixture; add if observed.
- Vector `UDiv`/`SDiv`/`URem`/`SRem` — permitted by LangRef but not exercised.
  Add if observed.
- Vector-to-scalar bitcasts (`<8 x i8>` → `i64`) — lane packing requires
  shift-and-or tree; defer.
- Dynamic `insertelement` / `extractelement` lane index — MUX tree expansion;
  rare in optimize=true plain Julia.
- Scalable vectors (`<vscale x N x iM>`) — ARM SVE / RISC-V V; fail loud.

### §6 Test coverage

- **RED gate**: `test/test_cc07_repro.jl` (already written, uses
  `ls_demo_16`). Must pass with `optimize=true` post-fix.
- **New file**: `test/test_vector_ir.jl` with three focused micro-tests:
  1. Tuple-of-adds splat+extract (insertelement + shufflevector + vector add + extractelement)
  2. Tuple-of-icmps (vector icmp producing `<N x i1>` + extractelements)
  3. Constant-vector binop (ConstantDataVector path in `_resolve_vec_lanes`)
- Each micro-test: `reversible_compile`, `verify_reversibility`, `simulate`
  against oracle on ≥4 sample inputs.
- Regression: run the full suite — NO gate-count regression on any function
  that LLVM did not auto-vectorise. Implementer must spot-check a handful of
  existing tests' gate counts pre/post fix and confirm byte-identical.

### §7 Interaction with `lower.jl` / other files

**Zero changes required** outside `ir_extract.jl`. The emitted IR is
indistinguishable from what an unvectorised `optimize=true` build would have
produced. If the implementer finds they need to touch `lower.jl`, stop and
escalate — that's a sign the design is wrong.

### §8 Gate-count prediction

For `ls_demo_16`:
- Baseline (`optimize=false`): 22,902 gates / 5,250 Toffoli (sweep data).
- Post-fix (`optimize=true`): expected **much lower**, 3–50× smaller per the
  bead note (sroa/mem2reg/instcombine/simplifycfg all run). Actual number to
  be measured and recorded in WORKLOG.md.
- Tax from extractelement-as-add-0: 8 extracts × ~10 gates = **80 gates** —
  negligible vs total.

### §9 Uncertainty acknowledgments

Three items from the proposers that must be verified at implementation time:

1. **`LLVM.API.LLVMGetShuffleVectorMaskElement` exists in the installed
   LLVM.jl version.** The implementer must `grep ~/.julia/packages/LLVM/`
   before using. If missing, check `LLVM.API.LLVMGetMaskValue` +
   `LLVM.API.LLVMGetNumMaskElements` (Proposer A's alternative).

2. **`IRBinOp(:add, x, iconst(0), w)` gate cost at width 1.** Empirically
   ~W+2 at i8. At i1 likely ~3 gates (1 CNOT + ancilla management). Irrelevant
   to correctness; measure post-fix.

3. **Julia parameter Symbols with colons/Unicode** (e.g. `Symbol("seed::Int8")`)
   round-trip correctly through the lane table. They already do through `names`,
   so this should be fine, but add a spot-check in the micro-tests.

---

## Implementer brief

- Single implementer (not a subagent) — the orchestrator (Claude, opus) is
  the implementer here per CLAUDE.md §2 (subagents draft, orchestrator
  implements for core changes).
- Target: `src/ir_extract.jl`. Target LOC: 200–300 added, zero removed.
- RED→GREEN workflow: run `julia --project=. test/test_cc07_repro.jl` after
  each handler added, watch the error message change. Write the micro-tests
  (§6) first if it accelerates.
- Full-suite regression: `julia --project=. -e 'using Pkg; Pkg.test()'` must
  pass before commit.
- Gate-count spot-check: pick 3 existing tests and confirm their gate count
  is unchanged (CLAUDE.md §6). Log the N=16 post-fix number to WORKLOG.md.
- Commit message: "Bennett-cc0.7: ir_extract handles SLP-vectorised IR
  (insertelement/extractelement/shufflevector + vector arithmetic)".
  Include the N=16 before/after gate counts.
