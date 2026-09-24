# ---- Bennett-cc0.7 helpers ----

# Safe vector-type probe. LLVM.value_type errors on unsupported value kinds
# (e.g. LLVMGlobalAlias, see cc0.3). Call-instruction callees hit this path,
# so the dispatcher uses the safe variant. An operand that isn't a plain
# LLVM value is definitely not a vector — treat the exception as "no".
function _safe_is_vector_type(val)::Bool
    try
        return LLVM.value_type(val) isa LLVM.VectorType
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

# Check whether any operand of `inst` is vector-typed. LLVM.jl raises from
# within `iterate(LLVM.operands(...))` when the operand's value kind is
# unsupported (e.g. LLVMGlobalAlias callees on call instructions — cc0.3).
# Fall back to an index-based scan using the raw C API on iteration failure.
function _any_vector_operand(inst::LLVM.Instruction)::Bool
    try
        return any(_safe_is_vector_type(o) for o in LLVM.operands(inst))
    catch e
        e isa InterruptException && rethrow()
        # Iteration failed partway through. Scan by raw index via the C API,
        # skipping operands that LLVM.jl cannot materialise.
        n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
        for i in 0:(n - 1)
            ref = LLVM.API.LLVMGetOperand(inst.ref, i)
            try
                if _safe_is_vector_type(LLVM.Value(ref))
                    return true
                end
            catch e2
                e2 isa InterruptException && rethrow()
                continue
            end
        end
        return false
    end
end

# Returns (n_lanes, elem_width) for <N x iM> or <N x float-like>;
# `nothing` for non-vectors. Float lanes are treated as bit-pattern lanes.
function _vector_shape(val)::Union{Nothing, Tuple{Int, Int}}
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return nothing
    et = LLVM.eltype(vt)
    w = if et isa LLVM.IntegerType
        Int(LLVM.width(et))
    elseif et isa LLVM.FloatingPointType
        Int(_type_width(et))
    else
        error("ir_extract.jl: vector with unsupported element type $et; " *
              "got vector type $vt (Bennett-cc0.7 / Bennett-ao66)")
    end
    w ∈ (1, 8, 16, 32, 64) ||
        error("ir_extract.jl: vector element width $w is not supported; " *
              "expected 1/8/16/32/64. Got vector type $vt")
    return (Int(LLVM.length(vt)), w)
end

struct _VectorLaneValue
    op::IROperand
    width::Int
end

_iwidth(val::_VectorLaneValue) = val.width
_operand(val::_VectorLaneValue, names::Dict{_LLVMRef, Symbol}) = val.op

function _vector_call_callee_name(inst::LLVM.Instruction, ops)
    isempty(ops) && return ""
    try
        return String(LLVM.name(ops[end]))
    catch e
        e isa InterruptException && rethrow()
        return ""
    end
end

function _vector_element_is_float(val)::Bool
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType || return false
    return LLVM.eltype(vt) isa LLVM.FloatingPointType
end

function _const_bool_arg(v::_VectorLaneValue)::Union{Nothing, Bool}
    v.width == 1 || return nothing
    v.op isa ConstOperand || return nothing
    v.op.value == 0 && return false
    v.op.value in (1, -1) && return true
    return nothing
end

function _validate_vector_intrinsic_lane(cname::AbstractString,
                                         inst::LLVM.Instruction,
                                         lane_ops::Vector{_VectorLaneValue})
    # Scalar min/max handlers currently use integer compares. Allowing their
    # vector float forms would silently compare f64 bit patterns.
    # Trailing-`.` discipline (worklog 063/064): match the full intrinsic
    # family name so siblings (e.g. `llvm.minimumnum.*`) cannot be swallowed.
    if (startswith(cname, "llvm.minnum.") || startswith(cname, "llvm.minimum.") ||
        startswith(cname, "llvm.maxnum.") || startswith(cname, "llvm.maximum.")) &&
       _vector_element_is_float(inst)
        _ir_error(inst,
            "vector intrinsic $cname on floating-point lanes is not supported; " *
            "scalar handler uses integer comparisons, so Bennett rejects this " *
            "to avoid bit-pattern min/max miscompile")
    end

    # These LLVM intrinsics produce poison on specific inputs when the immarg
    # is true. Bennett cannot prove those path conditions lane-locally here.
    if startswith(cname, "llvm.abs.") || startswith(cname, "llvm.ctlz.") ||
       startswith(cname, "llvm.cttz.")
        length(lane_ops) >= 2 ||
            _ir_error(inst, "vector intrinsic $cname missing poison immarg")
        flag = _const_bool_arg(lane_ops[2])
        flag === nothing &&
            _ir_error(inst,
                "vector intrinsic $cname poison immarg must be constant i1")
        flag == false ||
            _ir_error(inst,
                "vector intrinsic $cname with poison-on-overflow/zero immarg=true " *
                "is not supported; Bennett rejects poison-producing forms")
    end
end

# ---- Bennett-t9rh: poison / undef lanes ----
#
# The SLP and loop vectorisers routinely build vectors some of whose lanes are
# `poison` and never observed — e.g. SLP's horizontal-add idiom
#
#     %shift = shufflevector <2 x i64> %v, <2 x i64> poison, <2 x i32> <i32 1, i32 poison>
#     %sum   = add <2 x i64> %v, %shift          ; lane 1 = %v[1] + poison
#     %r     = extractelement <2 x i64> %sum, i64 0
#
# Bennett has no DCE, so emitting a scalar op for the dead lane (with a
# `POISON_LANE` operand) used to crash in `resolve!`. Semantics we rely on
# (LLVM 18 LangRef, "Poison Values" + the per-instruction sections):
#
#   * "Most instructions return 'poison' when one of their arguments is
#     'poison'. A notable exception is the select instruction."  Vector
#     binops / icmp / casts / select act element by element, so a lane-wise
#     op with a poison operand lane yields a poison result lane. We emit NO
#     IR for it — an unobserved poison lane costs zero gates, and every
#     pipeline step before us only refined the deterministic Julia source.
#   * "It is correct to replace a poison value with an undef value or any
#     value of the type." Hence `select c, poison, X -> X` per lane (the same
#     fold InstSimplify::simplifySelectInst does, release/18.x) — a pure
#     alias, no gates. A poison CONDITION lane makes the result lane poison.
#   * Lane-wise LLVM intrinsics propagate only when on
#     `_POISON_PROPAGATING_INTRINSICS` (the ones LLVM's own ValueTracking
#     `propagatesPoison` lists); any other intrinsic reading a poison lane
#     still fails loud — marking a lane poison too eagerly would be UNSOUND
#     in combination with the select refinement.
#   * `undef` is NOT poison ("or i8 undef, 255 ; always 255"), and
#     InstSimplify folds `select ?, undef, X` only when X is provably not
#     poison. Undef lanes therefore get their own sentinel (`UNDEF_LANE`) that
#     flows through pure lane plumbing (insertelement base, shufflevector,
#     same-shape bitcast) but fails loud at ANY computing use (U80 policy).
#
# Observation points still fail loud, at extraction, with context: an
# extractelement of a poison lane (it yields a scalar `poison`, which Bennett
# cannot represent as circuit bits), a reduction over one, a `<N x i1>` -> iN
# bitcast over one. `resolve!`'s catch-all stays as the backstop (e.g. a poison
# lane stored into an sret slot via `PendingVecLane`).

# LLVM intrinsic families (trailing `.` discipline) whose result lane is
# poison when any operand lane is poison — LLVM ValueTracking
# `propagatesPoison` (release/18.x). Conservative on purpose: omission only
# costs a loud error, inclusion of a non-propagating intrinsic would be a
# miscompile under the select refinement.
const _POISON_PROPAGATING_INTRINSICS = (
    "llvm.ctpop.", "llvm.ctlz.", "llvm.cttz.", "llvm.abs.",
    "llvm.smax.", "llvm.smin.", "llvm.umax.", "llvm.umin.",
    "llvm.bitreverse.", "llvm.bswap.",
)

@inline _is_poison_lane(op) = op === POISON_LANE
@inline _is_undef_lane(op) = op === UNDEF_LANE

# Fail loud if a computing lane-wise op reads an `undef` lane (see header).
function _reject_undef_lanes(inst::LLVM.Instruction, what::AbstractString,
                             i::Int, ops...)
    for (j, op) in enumerate(ops)
        _is_undef_lane(op) && _ir_error(inst,
            "$what reads an `undef` vector lane (lane $(i - 1), operand $j); " *
            "undef is not poison (LLVM LangRef: `or i8 undef, 255` is always 255), " *
            "so Bennett cannot propagate it and rejects it to fail fast " *
            "(CLAUDE.md §1; Bennett-bjdg / U80, Bennett-t9rh)")
    end
    return nothing
end

# Decode a value's N lanes into IROperands. Handles already-populated SSA
# vectors (via `lanes`), ConstantDataVector, ConstantAggregateZero, and
# PoisonValue / UndefValue (`POISON_LANE` / `UNDEF_LANE` sentinel lanes:
# poison lanes propagate through lane-wise ops and fail loud when OBSERVED;
# undef lanes fail loud at any computing use — Bennett-t9rh header above).
function _resolve_vec_lanes(val::LLVM.Value,
                            lanes::Dict{_LLVMRef, Vector{IROperand}},
                            names::Dict{_LLVMRef, Symbol},
                            n_expected::Int)::Vector{IROperand}
    # Path A: previously-processed SSA vector → read from `lanes`.
    if haskey(lanes, val.ref)
        got = lanes[val.ref]
        length(got) == n_expected ||
            throw(DimensionMismatch("ir_extract.jl: vector lane-count mismatch on $(string(val)): " *
                  "expected $n_expected, got $(length(got))"))
        return got
    end
    vt = LLVM.value_type(val)
    vt isa LLVM.VectorType ||
        throw(AssertionError("ir_extract.jl: _resolve_vec_lanes on non-vector: " *
              "$(string(val)) :: $vt"))
    got_n = Int(LLVM.length(vt))
    got_n == n_expected ||
        throw(DimensionMismatch("ir_extract.jl: vector lane-count mismatch: expected $n_expected, " *
              "got $got_n on $(string(val))"))
    # Path B: ConstantDataVector.
    if val isa LLVM.ConstantDataVector
        out = Vector{IROperand}(undef, got_n)
        for i in 0:(got_n - 1)
            elt_ref = LLVM.API.LLVMGetElementAsConstant(val.ref, i)
            elt = LLVM.Value(elt_ref)
            elt isa LLVM.ConstantInt ||
                error("ir_extract.jl: vector constant element at lane $i is " *
                      "not ConstantInt: $(string(elt))")
            out[i + 1] = iconst(_const_int_as_int(elt))
        end
        return out
    end
    # Path C: zeroinitializer.
    if val isa LLVM.ConstantAggregateZero
        return [iconst(0) for _ in 1:got_n]
    end
    # Path D: poison / undef — sentinel lanes (LLVM.jl: PoisonValue is a
    # sibling of UndefValue, not a subtype). See the Bennett-t9rh header.
    if val isa LLVM.PoisonValue
        return [POISON_LANE for _ in 1:got_n]
    end
    if val isa LLVM.UndefValue
        return [UNDEF_LANE for _ in 1:got_n]
    end
    error("ir_extract.jl: cannot resolve vector lanes for $(string(val)) :: " *
          "$vt — not an SSA vector, ConstantDataVector, ConstantAggregateZero, " *
          "or poison/undef")
end

# Bennett-pg5: native dispatch for the 9 LLVM integer vector-reduction
# intrinsics (`llvm.vector.reduce.{add,mul,and,or,xor,smax,smin,umax,umin}.*`).
# These take ONE vector operand and return a SCALAR equal to
# `lane[0] OP lane[1] OP ... OP lane[N-1]`. The lowering emits a left-to-right
# linear fold chain over the resolved lanes. The last op writes `dest`; all
# intermediate accumulators get auto-named SSA temporaries.
#
# Bennett-lx5h: float-vector reductions extend the same dispatch. The 8 float
# intrinsics fold via `IRCall` over the matching `soft_*` primitive
# (`soft_fadd`, `soft_fmul`, `soft_fmin`, `soft_fmax`, `soft_fminimum`,
# `soft_fmaximum`, `soft_minimumnum`, `soft_maximumnum`). Two structural
# differences vs the integer arms:
#   1. `fadd` / `fmul` carry a SCALAR START value as the first call arg
#      (operand layout `[start, vector, callee]` rather than `[vector, callee]`).
#      The result is `start OP lane[0] OP lane[1] OP ... OP lane[N-1]`; the
#      fold initial accumulator is `start` (not `lane[0]`), and the loop folds
#      ALL N lanes. For fadd the identity start is `-0.0`; for fmul it is `+1.0`.
#   2. min/max-family reductions are 1-operand `[vector, callee]` like the
#      integer arms; the fold starts from `lane[0]` and folds N-1 times.
# Strict left-to-right fold per CLAUDE.md §13 (bit-exactness over performance —
# the LLVM `reassoc` flag is INTENTIONALLY IGNORED). f32 vector forms are
# rejected per §13 / Bennett-3rph.
#
# Returns the IRInst chain on a hit, or `nothing` if `cname` is not a
# vector-reduction intrinsic (caller falls through to the per-lane
# scalarisation path).
function _handle_vector_reduction(cname::AbstractString,
                                  inst::LLVM.Instruction,
                                  names::Dict{_LLVMRef, Symbol},
                                  lanes::Dict{_LLVMRef, Vector{IROperand}},
                                  counter::Ref{Int},
                                  dest::Symbol)
    startswith(cname, "llvm.vector.reduce.") || return nothing

    # Trailing-`.` discipline on each op token (Bennett-kh6n). The op name
    # sits between two `.` so prefix-collision risk is minimal, but the
    # disciplined match is cheap insurance against future LLVM additions
    # (e.g. a hypothetical `llvm.vector.reduce.added.*`).
    #
    # `op_dispatch` encoding:
    #   (:binop, sym)        → integer binop fold (add/mul/and/or/xor)
    #   (:cmp,   pred)       → integer min/max fold via IRICmp + IRSelect
    #   (:fcall, soft_fn)    → float fold via IRCall over the soft_* primitive
    # Bennett-lx5h: longest-first ordering matters for `fminimumnum.` /
    # `fmaximumnum.` — they MUST come before `fminimum.` / `fmaximum.`
    # because the trailing `.` after the long name is part of the literal,
    # not the discipline guard. Without longest-first, `fminimumnum.v4f64`
    # would match `fminimum.` (no — the trailing dot rules that out: the
    # next char after `fminimum` would be `n`, not `.`). Belt-and-braces:
    # check the longer prefix first anyway, mirroring Bennett-p19b.
    op_dispatch = nothing
    if startswith(cname, "llvm.vector.reduce.add.")
        op_dispatch = (:binop, :add)
    elseif startswith(cname, "llvm.vector.reduce.mul.")
        op_dispatch = (:binop, :mul)
    elseif startswith(cname, "llvm.vector.reduce.and.")
        op_dispatch = (:binop, :and)
    elseif startswith(cname, "llvm.vector.reduce.or.")
        op_dispatch = (:binop, :or)
    elseif startswith(cname, "llvm.vector.reduce.xor.")
        op_dispatch = (:binop, :xor)
    elseif startswith(cname, "llvm.vector.reduce.smax.")
        op_dispatch = (:cmp, :sge)
    elseif startswith(cname, "llvm.vector.reduce.smin.")
        op_dispatch = (:cmp, :sle)
    elseif startswith(cname, "llvm.vector.reduce.umax.")
        op_dispatch = (:cmp, :uge)
    elseif startswith(cname, "llvm.vector.reduce.umin.")
        op_dispatch = (:cmp, :ule)
    elseif startswith(cname, "llvm.vector.reduce.fadd.")
        op_dispatch = (:fcall, soft_fadd)
    elseif startswith(cname, "llvm.vector.reduce.fmul.")
        op_dispatch = (:fcall, soft_fmul)
    elseif startswith(cname, "llvm.vector.reduce.fminimumnum.")
        op_dispatch = (:fcall, soft_minimumnum)
    elseif startswith(cname, "llvm.vector.reduce.fmaximumnum.")
        op_dispatch = (:fcall, soft_maximumnum)
    elseif startswith(cname, "llvm.vector.reduce.fminimum.")
        op_dispatch = (:fcall, soft_fminimum)
    elseif startswith(cname, "llvm.vector.reduce.fmaximum.")
        op_dispatch = (:fcall, soft_fmaximum)
    elseif startswith(cname, "llvm.vector.reduce.fmin.")
        op_dispatch = (:fcall, soft_fmin)
    elseif startswith(cname, "llvm.vector.reduce.fmax.")
        op_dispatch = (:fcall, soft_fmax)
    else
        # Unrecognised reduction op token. Fail loud rather than fall through.
        _ir_error(inst,
            "vector reduction $cname is not supported; Bennett-pg5 covers " *
            "the 9 integer reductions (add/mul/and/or/xor/smax/smin/umax/umin); " *
            "Bennett-lx5h covers the 8 float reductions (fadd/fmul/fmin/fmax/" *
            "fminimum/fmaximum/fminimumnum/fmaximumnum)")
    end

    (kind, opv) = op_dispatch
    is_float = (kind == :fcall)
    is_fadd_or_fmul = is_float && (opv === soft_fadd || opv === soft_fmul)

    ops = LLVM.operands(inst)

    # Operand layout dispatch:
    #   - integer reductions and float min/max-family: [vector, callee]
    #     → length(ops) == 2; vec_idx = 1; no start operand.
    #   - float fadd/fmul: [start, vector, callee]
    #     → length(ops) == 3; vec_idx = 2; ops[1] is the scalar start value.
    expected_n = is_fadd_or_fmul ? 3 : 2
    length(ops) == expected_n ||
        _ir_error(inst,
            "vector reduction $cname expected $(expected_n - 1) operand(s) " *
            "before callee (got $(length(ops) - 1))")

    vec_idx = is_fadd_or_fmul ? 2 : 1
    vec = ops[vec_idx]
    _safe_is_vector_type(vec) ||
        _ir_error(inst,
            "vector reduction $cname operand is not a vector " *
            "(got $(LLVM.value_type(vec)))")

    # Lane-element-type validation. Integer reductions reject float lanes
    # (would silently sum f64 bit patterns). Float reductions reject f32
    # lanes per CLAUDE.md §13 / Bennett-3rph.
    if is_float
        _vector_element_is_float(vec) ||
            _ir_error(inst,
                "vector reduction $cname expected float-element operand " *
                "(got $(LLVM.value_type(vec))); Bennett-lx5h covers " *
                "float reductions only — integer reductions are tracked " *
                "in Bennett-pg5")
        # Width must be 64 (f64). f32 vectors silently double-round through
        # the soft_fpext → f64 → soft_fptrunc routing per Bennett-3rph; the
        # bit-exactness contract (§13) only applies to f64.
        (_, lane_w) = _vector_shape(vec)
        lane_w == 64 ||
            _ir_error(inst,
                "vector reduction $cname: only f64 vector lanes supported " *
                "(got width=$lane_w); native f32 paths are not bit-exact " *
                "(CLAUDE.md §13 / Bennett-3rph). (Bennett-lx5h)")
        if is_fadd_or_fmul
            # Start arg must be a SCALAR f64. Reject vector start (LLVM langref
            # mandates scalar) and reject f32-typed start (same §13 contract).
            start_val = ops[1]
            _safe_is_vector_type(start_val) &&
                _ir_error(inst,
                    "vector reduction $cname start value must be scalar " *
                    "(got vector $(LLVM.value_type(start_val)))")
            start_w = Int(_type_width(LLVM.value_type(start_val)))
            start_w == 64 ||
                _ir_error(inst,
                    "vector reduction $cname start value width=$start_w; " *
                    "only f64 supported (CLAUDE.md §13)")
        end
    else
        _vector_element_is_float(vec) &&
            _ir_error(inst,
                "vector reduction $cname has float-element operand; " *
                "Bennett-pg5 covers integer reductions only. " *
                "Float reductions are tracked in Bennett-lx5h (P3)")
    end

    (n, w) = _vector_shape(vec)
    n >= 1 ||
        _ir_error(inst,
            "vector reduction $cname has empty vector operand " *
            "(N=$n; LLVM langref says <0 x iN> is poison)")

    vec_lanes = _resolve_vec_lanes(vec, lanes, names, n)
    for (i, op) in enumerate(vec_lanes)
        # Observation point (Bennett-t9rh): a reduction reads every lane.
        _is_poison_lane(op) &&
            _ir_error(inst,
                "vector reduction $cname reads poison lane at index $(i - 1); " *
                "its scalar result would be poison, which Bennett cannot " *
                "represent (Bennett-t9rh)")
        _reject_undef_lanes(inst, "vector reduction $cname", i, op)
    end

    insts = IRInst[]

    # ---- Float fadd/fmul with scalar START value ----
    # Fold layout: acc = start; for i in 1:n: acc = OP(acc, lane[i]).
    # All N lanes participate; the LAST fold step writes `dest`. For N=1
    # there's exactly one fold step (start, lane[0]) → dest.
    if is_fadd_or_fmul
        acc = _operand(ops[1], names)
        for i in 1:n
            is_last = (i == n)
            step_dest = is_last ? dest : _auto_name(counter)
            push!(insts, IRCall(step_dest, opv,
                                IROperand[acc, vec_lanes[i]], [w, w], w))
            acc = ssa(step_dest)
        end
        return insts
    end

    # N=1 trivial case (integer + float min/max-family): result is just lane[0].
    # For integers, emit a rename via add-zero (mirrors the extractelement
    # rename pattern, vectors.jl line ~241). For float min/max, the same
    # add-zero rename would be incorrect (would route f64 bit-pattern through
    # the integer adder), so route through the matching soft_* primitive
    # paired with itself (idempotent: soft_fmin(x,x) = x for non-NaN; for NaN
    # both single-input forms canonicalise to qNaN, which matches the LLVM
    # langref one-lane semantics for single-NaN-operand reductions).
    if n == 1
        if is_float
            push!(insts, IRCall(dest, opv,
                                IROperand[vec_lanes[1], vec_lanes[1]], [w, w], w))
        else
            push!(insts, IRBinOp(dest, :add, vec_lanes[1], iconst(0), w))
        end
        return insts
    end

    # N≥2: linear left-to-right fold chain.
    #   acc = lane[0]
    #   for i in 1:n-1:
    #     acc = OP(acc, lane[i])
    # The last fold step writes `dest`; all intermediates get auto-names.
    acc = vec_lanes[1]
    for i in 2:n
        is_last = (i == n)
        step_dest = is_last ? dest : _auto_name(counter)
        if kind == :binop
            push!(insts, IRBinOp(step_dest, opv, acc, vec_lanes[i], w))
            acc = ssa(step_dest)
        elseif kind == :cmp  # integer min/max: IRICmp + IRSelect
            cmp_dest = _auto_name(counter)
            push!(insts, IRICmp(cmp_dest, opv, acc, vec_lanes[i], w))
            push!(insts, IRSelect(step_dest, ssa(cmp_dest), acc, vec_lanes[i], w))
            acc = ssa(step_dest)
        else  # :fcall — float min/max-family: IRCall over soft_* primitive
            push!(insts, IRCall(step_dest, opv,
                                IROperand[acc, vec_lanes[i]], [w, w], w))
            acc = ssa(step_dest)
        end
    end
    return insts
end

function _convert_vector_instruction(inst::LLVM.Instruction,
                                     names::Dict{_LLVMRef, Symbol},
                                     lanes::Dict{_LLVMRef, Vector{IROperand}},
                                     counter::Ref{Int})
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

    # insertelement — pure SSA plumbing, emit no IR.
    if opc == LLVM.API.LLVMInsertElement
        ops = LLVM.operands(inst)
        base_vec = ops[1]; elem = ops[2]; idx_val = ops[3]
        idx_val isa LLVM.ConstantInt ||
            _ir_error(inst, "insertelement with dynamic lane index not supported")
        idx = _const_int_as_int(idx_val)
        n = _vector_shape(inst)[1]
        (0 <= idx < n) ||
            _ir_error(inst, "insertelement lane index $idx outside [0,$n)")
        base_lanes = _resolve_vec_lanes(base_vec, lanes, names, n)
        new_lanes = copy(base_lanes)
        new_lanes[idx + 1] = _operand(elem, names)
        lanes[inst.ref] = new_lanes
        return nothing
    end

    # shufflevector — pure SSA plumbing.
    if opc == LLVM.API.LLVMShuffleVector
        ops = LLVM.operands(inst)
        v1 = ops[1]; v2 = ops[2]
        n_src = _vector_shape(v1)[1]
        n_result = Int(LLVM.API.LLVMGetNumMaskElements(inst.ref))
        v1_lanes = _resolve_vec_lanes(v1, lanes, names, n_src)
        v2_lanes = _resolve_vec_lanes(v2, lanes, names, n_src)
        out = Vector{IROperand}(undef, n_result)
        for i in 0:(n_result - 1)
            m = Int(LLVM.API.LLVMGetMaskValue(inst.ref, i))
            if m == -1                       # poison mask element
                out[i + 1] = POISON_LANE
            elseif 0 <= m < n_src
                out[i + 1] = v1_lanes[m + 1]
            elseif n_src <= m < 2 * n_src
                out[i + 1] = v2_lanes[m - n_src + 1]
            else
                _ir_error(inst, "shufflevector mask element $m out of range [0, $(2*n_src))")
            end
        end
        lanes[inst.ref] = out
        return nothing
    end

    # extractelement — rename via add-zero (see consensus §Choice 4).
    if opc == LLVM.API.LLVMExtractElement
        ops = LLVM.operands(inst)
        vec = ops[1]; idx_val = ops[2]
        n = _vector_shape(vec)[1]
        vec_lanes = _resolve_vec_lanes(vec, lanes, names, n)
        idx_val isa LLVM.ConstantInt ||
            _ir_error(inst, "extractelement with dynamic lane index not supported")
        idx = _const_int_as_int(idx_val)
        (0 <= idx < n) ||
            _ir_error(inst, "extractelement lane index $idx outside [0,$n)")
        lane_op = vec_lanes[idx + 1]
        # Observation point (Bennett-t9rh). Not UB per LangRef: it yields a
        # scalar `poison`, which Bennett cannot represent as circuit bits.
        _is_poison_lane(lane_op) &&
            _ir_error(inst, "extractelement reads poison lane $idx — per LLVM " *
                            "LangRef this yields a scalar `poison` value, which " *
                            "Bennett cannot represent as circuit bits; the lane " *
                            "was poison in the source IR or became poison through " *
                            "lane-wise propagation (Bennett-t9rh)")
        _reject_undef_lanes(inst, "extractelement", idx + 1, lane_op)
        w = Int(_type_width(LLVM.value_type(inst)))
        return IRBinOp(dest, :add, lane_op, iconst(0), w)
    end

    # Vector arithmetic / bitwise / shift — N scalar IRBinOps.
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
            # Bennett-t9rh: poison in -> poison out, no IR (LangRef).
            if _is_poison_lane(a_lanes[i]) || _is_poison_lane(b_lanes[i])
                out[i] = POISON_LANE
                continue
            end
            _reject_undef_lanes(inst, "vector $sym", i, a_lanes[i], b_lanes[i])
            lane_dest = _auto_name(counter)
            push!(insts, IRBinOp(lane_dest, sym, a_lanes[i], b_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector icmp — N scalar IRICmps producing <N x i1>.
    if opc == LLVM.API.LLVMICmp
        ops = LLVM.operands(inst)
        (n, _) = _vector_shape(inst)
        (_, op_w) = _vector_shape(ops[1])
        pred = _pred_to_sym(LLVM.predicate(inst))
        a_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        b_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            # Bennett-t9rh: poison in -> poison out, no IR (LangRef).
            if _is_poison_lane(a_lanes[i]) || _is_poison_lane(b_lanes[i])
                out[i] = POISON_LANE
                continue
            end
            _reject_undef_lanes(inst, "vector icmp", i, a_lanes[i], b_lanes[i])
            lane_dest = _auto_name(counter)
            push!(insts, IRICmp(lane_dest, pred, a_lanes[i], b_lanes[i], op_w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector select — N scalar IRSelects. Condition may be scalar i1 (broadcast)
    # or <N x i1> (per-lane).
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        (n, w) = _vector_shape(inst)
        cond = ops[1]
        cond_is_vec = LLVM.value_type(cond) isa LLVM.VectorType
        cond_lanes = cond_is_vec ? _resolve_vec_lanes(cond, lanes, names, n) : nothing
        t_lanes = _resolve_vec_lanes(ops[2], lanes, names, n)
        f_lanes = _resolve_vec_lanes(ops[3], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            c_op = cond_is_vec ? cond_lanes[i] : _operand(cond, names)
            # Bennett-t9rh (LangRef "Poison Values" / InstSimplify):
            #   select poison, ?, ?    -> poison
            #   select ?, poison, X    -> X      (pure alias, no gates)
            #   select ?, X, poison    -> X
            # Only for POISON lanes — for undef the fold needs X provably
            # not poison, so undef lanes fail loud below.
            t_op = t_lanes[i]; f_op = f_lanes[i]
            if _is_poison_lane(c_op) || (_is_poison_lane(t_op) && _is_poison_lane(f_op))
                out[i] = POISON_LANE
                continue
            elseif _is_poison_lane(t_op)
                out[i] = f_op
                continue
            elseif _is_poison_lane(f_op)
                out[i] = t_op
                continue
            end
            _reject_undef_lanes(inst, "vector select", i, c_op, t_op, f_op)
            lane_dest = _auto_name(counter)
            push!(insts, IRSelect(lane_dest, c_op, t_lanes[i], f_lanes[i], w))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector casts — N scalar IRCasts.
    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        ops = LLVM.operands(inst)
        (n, w_to) = _vector_shape(inst)
        (n_src, w_from) = _vector_shape(ops[1])
        n_src == n || _ir_error(inst, "vector cast lane-count mismatch: $n_src vs $n")
        src_lanes = _resolve_vec_lanes(ops[1], lanes, names, n)
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            # Bennett-t9rh: poison in -> poison out, no IR (LangRef).
            if _is_poison_lane(src_lanes[i])
                out[i] = POISON_LANE
                continue
            end
            _reject_undef_lanes(inst, "vector $opname", i, src_lanes[i])
            lane_dest = _auto_name(counter)
            push!(insts, IRCast(lane_dest, opname, src_lanes[i], w_from, w_to))
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector LLVM intrinsics - scalarise lane-wise and route each lane through
    # the scalar intrinsic dispatcher. This keeps the large intrinsic table in
    # one place while ensuring no vector IR reaches lower.jl.
    if opc == LLVM.API.LLVMCall
        ops = LLVM.operands(inst)
        cname = _vector_call_callee_name(inst, ops)
        startswith(cname, "llvm.") ||
            _ir_error(inst, "unsupported vector call '$cname' (only LLVM intrinsics are scalarised)")

        # Bennett-pg5: integer vector-reduction intrinsics. These have a
        # SCALAR result type but a VECTOR operand, so they hit the vector
        # dispatch path (via `_any_vector_operand`) yet `_vector_shape(inst)`
        # returns `nothing` (scalar return). Handle them BEFORE the shape
        # check so the catch-all reject only fires for genuinely-unsupported
        # vector intrinsics with scalar returns. Trailing-`.` discipline on
        # every op token (per Bennett-kh6n).
        reduction = _handle_vector_reduction(cname, inst, names, lanes, counter, dest)
        reduction === nothing || return reduction

        shape = _vector_shape(inst)
        shape === nothing &&
            _ir_error(inst, "vector intrinsic $cname has scalar return type; " *
                            "Bennett-pg5 covers integer vector.reduce.{add,mul,and,or,xor," *
                            "smax,smin,umax,umin}; float reductions are tracked in " *
                            "Bennett-lx5h (P3)")
        (n, ret_w) = shape

        arg_lanes = Vector{Vector{_VectorLaneValue}}()
        for arg in ops[1:(length(ops) - 1)]
            arg_shape = _vector_shape(arg)
            if arg_shape === nothing
                arg_op = _operand(arg, names)
                arg_w = _iwidth(arg)
                push!(arg_lanes, [_VectorLaneValue(arg_op, arg_w) for _ in 1:n])
            else
                (arg_n, arg_w) = arg_shape
                arg_n == n ||
                    _ir_error(inst,
                        "vector intrinsic $cname lane-count mismatch: " *
                        "return has $n lanes, operand has $arg_n lanes")
                resolved = _resolve_vec_lanes(arg, lanes, names, n)
                push!(arg_lanes, [_VectorLaneValue(op, arg_w) for op in resolved])
            end
        end

        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        propagates = any(p -> startswith(cname, p), _POISON_PROPAGATING_INTRINSICS)
        for i in 1:n
            lane_ops = [arg[i] for arg in arg_lanes]
            # Shape / immarg validation first: it rejects unsupported forms
            # regardless of lane contents.
            _validate_vector_intrinsic_lane(cname, inst, lane_ops)
            # Bennett-t9rh: poison in -> poison out, no IR, for intrinsics
            # known to propagate poison; any other intrinsic stays loud.
            if any(lv -> _is_poison_lane(lv.op), lane_ops)
                propagates || _ir_error(inst,
                    "vector intrinsic $cname reads poison lane $(i - 1); it is not " *
                    "on Bennett's list of poison-propagating intrinsics " *
                    "(`_POISON_PROPAGATING_INTRINSICS`), so the result lane " *
                    "cannot be proven poison (Bennett-t9rh)")
                out[i] = POISON_LANE
                continue
            end
            _reject_undef_lanes(inst, "vector intrinsic $cname", i,
                                (lv.op for lv in lane_ops)...)
            lane_dest = _auto_name(counter)
            handled = _handle_intrinsic(cname, inst, names, counter, lane_dest, lane_ops)
            handled === nothing &&
                _ir_error(inst,
                    "vector intrinsic $cname has no scalar intrinsic handler " *
                    "for lane width $ret_w")
            if handled isa Vector
                append!(insts, handled)
            else
                push!(insts, handled)
            end
            out[i] = ssa(lane_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    # Vector bitcast — two supported shapes:
    #   (a) vector → same-shape vector: identity alias.
    #   (b) <N x i1> → scalar iN: bit-position pack (lane i → bit i). Common
    #       after a vector icmp that LLVM wants to reduce to a single mask byte.
    if opc == LLVM.API.LLVMBitCast
        src = LLVM.operands(inst)[1]
        src_shape = _vector_shape(src)
        dst_shape = _vector_shape(inst)
        if src_shape !== nothing && dst_shape !== nothing
            (n, w_to) = dst_shape
            (n_src, w_from) = src_shape
            (n_src == n && w_from == w_to) ||
                _ir_error(inst,
                    "vector bitcast with lane/width shape change not supported: " *
                    "<$n_src x i$w_from> → <$n x i$w_to>")
            src_lanes = _resolve_vec_lanes(src, lanes, names, n)
            lanes[inst.ref] = copy(src_lanes)
            return nothing
        end
        if src_shape !== nothing && dst_shape === nothing
            # vector → scalar: must be <N x i1> → iN (bit-pack).
            (n_src, w_from) = src_shape
            dst_vt = LLVM.value_type(inst)
            dst_vt isa LLVM.IntegerType ||
                _ir_error(inst, "vector→scalar bitcast to non-integer type $dst_vt")
            w_to = Int(LLVM.width(dst_vt))
            (w_from == 1 && w_to == n_src) ||
                _ir_error(inst,
                    "vector→scalar bitcast only supported for <N x i1> → iN " *
                    "(got <$n_src x i$w_from> → i$w_to)")
            src_lanes = _resolve_vec_lanes(src, lanes, names, n_src)
            # Build: result = OR_k (zext(lane_k, n_src) << k)
            insts = IRInst[]
            shifted = IROperand[]
            for k in 0:(n_src - 1)
                lane = src_lanes[k + 1]
                # Observation point (Bennett-t9rh): every lane lands in the iN.
                _is_poison_lane(lane) &&
                    _ir_error(inst, "vector→scalar bitcast reads poison lane at " *
                                    "index $k; the packed scalar would be poison, " *
                                    "which Bennett cannot represent (Bennett-t9rh)")
                _reject_undef_lanes(inst, "vector→scalar bitcast", k + 1, lane)
                zext_dest = _auto_name(counter)
                push!(insts, IRCast(zext_dest, :zext, lane, 1, n_src))
                if k == 0
                    push!(shifted, ssa(zext_dest))
                else
                    shl_dest = _auto_name(counter)
                    push!(insts, IRBinOp(shl_dest, :shl, ssa(zext_dest), iconst(k), n_src))
                    push!(shifted, ssa(shl_dest))
                end
            end
            acc = shifted[1]
            for i in 2:length(shifted)
                or_dest = (i == length(shifted)) ? dest : _auto_name(counter)
                push!(insts, IRBinOp(or_dest, :or, acc, shifted[i], n_src))
                acc = ssa(or_dest)
            end
            if length(shifted) == 1
                # Single-lane corner: copy via add-0.
                push!(insts, IRBinOp(dest, :add, shifted[1], iconst(0), n_src))
            end
            return insts
        end
        _ir_error(inst, "unsupported bitcast shape for cc0.7")
    end

    # Bennett-0c8o: vector load — decompose `%v = load <N x iW>, ptr %p` into
    # N scalar `IRPtrOffset` + `IRLoad` pairs at lane byte offsets, and record
    # per-lane IROperands in `lanes[inst.ref]`. Uses only primitives already
    # handled by lower.jl.
    if opc == LLVM.API.LLVMLoad
        shape = _vector_shape(inst)
        shape === nothing &&
            _ir_error(inst, "vector load return type is not a vector")
        n, w = shape
        ptr = LLVM.operands(inst)[1]
        eb = w ÷ 8
        insts = IRInst[]
        out = Vector{IROperand}(undef, n)
        for i in 1:n
            gep_dest = _auto_name(counter)
            load_dest = _auto_name(counter)
            push!(insts, IRPtrOffset(gep_dest, _operand(ptr, names), (i - 1) * eb, w))
            push!(insts, IRLoad(load_dest, ssa(gep_dest), w))
            out[i] = ssa(load_dest)
        end
        lanes[inst.ref] = out
        return insts
    end

    _ir_error(inst, "unsupported vector opcode $opc")
end
