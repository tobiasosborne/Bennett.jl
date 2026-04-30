# ---- binary-op dispatch ----

"""
    _pick_add_strategy(user_choice, W, op2_dead, liveness_enabled) -> Symbol

Resolve an `add=:auto|:ripple|:cuccaro|:qcla` user choice into one of the
three concrete strategies. Explicit choices bypass the heuristic.

Bennett-spa8 / U27: `:auto` always returns `:ripple`. The pre-U27
default preferred Cuccaro on an op2-dead path, but Cuccaro's one-wire
in-place saving is immediately erased by Bennett's copy-out pass,
while shipping a strictly worse Toffoli-depth (the Cuccaro MAJ/UMA
chain serialises every Toffoli). On `(x,y)->x+y` at W=32:
  cuccaro: 410 total / T-depth 124
  ripple : 346 total / T-depth 62
`op2_dead` / `liveness_enabled` are retained in the signature for
backward compatibility with callers that still thread them.
"""
function _pick_add_strategy(user_choice::Symbol, W::Int, op2_dead::Bool, liveness_enabled::Bool)
    user_choice === :ripple  && return :ripple
    user_choice === :cuccaro && return :cuccaro
    user_choice === :qcla    && return :qcla
    user_choice === :auto || error("_pick_add_strategy: unknown choice :$user_choice")
    return :ripple
end

"""
    _pick_mul_strategy(user_choice, W; target=:gate_count) -> Symbol

Resolve `mul=:auto|:shift_add|:qcla_tree` into a concrete strategy.
Explicit choices bypass the heuristic entirely.

For `:auto`:
- `target=:gate_count` (default): shift-and-add. Wins on total Toffoli
  count and wire budget at every supported width.
- `target=:depth`: `qcla_tree` (Sun-Borissov 2023). O(log² n) Toffoli
  depth vs shift-and-add's O(n); depth drops ~3-6× at W=32/64.
  Costs ~5× more total Toffoli and ~2.5× more wires.

Bennett-4fri / U30: the `target` arm closes the "qcla_tree is never
picked by :auto" gap.

Bennett-tbm6 (2026-04-27): `:karatsuba` removed. The implementation
was vestigial at every supported width (W ≤ 64) — see src/multiplier.jl:35
for the empirical sweep showing 1.91-3.49× WORSE Toffoli count than
schoolbook at every measured W. The asymptotic crossover sits past W=128,
beyond what `ir_extract` lowers today.
"""
function _pick_mul_strategy(user_choice::Symbol, W::Int;
                            target::Symbol=:gate_count)
    user_choice === :shift_add && return :shift_add
    user_choice === :qcla_tree && return :qcla_tree
    user_choice === :auto || error("_pick_mul_strategy: unknown choice :$user_choice (supported: :auto, :shift_add, :qcla_tree)")
    target === :depth && return :qcla_tree
    return :shift_add
end

# ==== Bennett-5qrn / U57: trivial-identity peepholes ====
#
# Detect `x + 0`, `x * 1`, `x | 0`, `x & 0`, `x & all-ones`, `x | all-ones`,
# `x ⊕ 0`, `x ⊕ all-ones`, `x - 0`, `x * 0` (and the symmetric forms for
# commutative ops) at the dispatcher BEFORE `resolve!` materialises a
# constant-zero/one operand into ancilla wires. Without the peephole the
# identity `x * Int8(1)` lowers to 692 gates (full schoolbook multiply with
# fold_constants=false); with it the multiply collapses to W CNOTs (one
# per output bit). Per the U57 review, this saves 20-40% on the persistent-
# DS sweep where `optimize=false` is mandatory and LLVM's own constant
# folding never fires.
#
# Detection is purely syntactic on `IROperand` — we never inspect runtime
# wire state — so the peephole cannot misfire on data-dependent operands
# inside `lower_mul_wide!` / Karatsuba / etc. (those leaf-level adders are
# called directly with wire vectors, never through `lower_binop!`).
#
# Soft-float safety: `soft_fadd(0.0, x)` is NOT a no-op in IEEE 754, but
# this peephole only fires on integer binops INSIDE the soft-float bodies
# (e.g. mantissa + Int64(0)), where the identity is true bitwise. The
# soft_fadd call itself goes through `lower_call!`, not here.

@inline _wmask(W::Int)::UInt64 =
    W >= 64 ? typemax(UInt64) : (UInt64(1) << W) - UInt64(1)

@inline function _const_value_mod(op::IROperand, W::Int)
    op.kind === :const || return nothing
    return (reinterpret(UInt64, Int64(op.value))) & _wmask(W)
end

function _emit_copy_out!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                          src::Vector{Int}, W::Int)
    r = allocate!(wa, W)
    for i in 1:W
        push!(gates, CNOTGate(src[i], r[i]))
    end
    return r
end

function _identity_emit_for_const(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                    vw::Dict{Symbol,Vector{Int}}, op::Symbol,
                                    ssa_op::IROperand, k::UInt64, W::Int)
    mask = _wmask(W)

    # Zero-out cases — never read the SSA operand.
    if (op === :mul && k == 0) || (op === :and && k == 0)
        return allocate!(wa, W)
    end

    # `x | all-ones` — all-ones result, never read x.
    if op === :or && k == mask
        r = allocate!(wa, W)
        for i in 1:W
            push!(gates, NOTGate(r[i]))
        end
        return r
    end

    # Remaining cases need x. Bail if the other operand isn't an SSA name
    # (both-const case is rare and falls through to the heavy path / fold).
    ssa_op.kind === :ssa || return nothing

    if (op === :add  && k == 0) ||
       (op === :sub  && k == 0) ||
       (op === :or   && k == 0) ||
       (op === :xor  && k == 0) ||
       (op === :mul  && k == 1) ||
       (op === :and  && k == mask)
        a = resolve!(gates, wa, vw, ssa_op, W)
        return _emit_copy_out!(gates, wa, a, W)
    end

    if op === :xor && k == mask
        a = resolve!(gates, wa, vw, ssa_op, W)
        r = _emit_copy_out!(gates, wa, a, W)
        for i in 1:W
            push!(gates, NOTGate(r[i]))
        end
        return r
    end

    return nothing
end

function _try_identity_peephole!(gates::Vector{ReversibleGate}, wa::WireAllocator,
                                   vw::Dict{Symbol,Vector{Int}}, inst::IRBinOp)
    op = inst.op
    op in (:add, :sub, :mul, :and, :or, :xor) || return nothing
    W = inst.width
    cv1 = _const_value_mod(inst.op1, W)
    cv2 = _const_value_mod(inst.op2, W)

    # Skip both-const — `_fold_constants` handles it post-hoc, and this avoids
    # any commutative-swap accounting when neither operand needs an SSA read.
    cv1 !== nothing && cv2 !== nothing && return nothing

    commutes = op in (:add, :mul, :and, :or, :xor)
    ssa_op, k = if commutes && cv1 !== nothing
        inst.op2, cv1
    elseif cv2 !== nothing
        inst.op1, cv2
    else
        return nothing
    end

    return _identity_emit_for_const(gates, wa, vw, op, ssa_op, k, W)
end

function lower_binop!(gates, wa, vw, inst::IRBinOp;
                      ssa_liveness::Dict{Symbol,Int}=Dict{Symbol,Int}(),
                      inst_idx::Int=0,
                      add::Symbol=:auto, mul::Symbol=:auto)
    # Bennett-5qrn / U57: trivial-identity peephole. Short-circuits before
    # `resolve!` so neither the constant operand nor the heavy adder/multiplier
    # allocates ancilla wires. See helper docs above.
    let res = _try_identity_peephole!(gates, wa, vw, inst)
        if res !== nothing
            vw[inst.dest] = res
            return
        end
    end

    a = resolve!(gates, wa, vw, inst.op1, inst.width)
    W = inst.width

    result = if inst.op in (:shl, :lshr, :ashr)
        if inst.op2.kind == :const
            k = inst.op2.value
            if inst.op == :shl;   lower_shl!(gates, wa, a, k, W)
            elseif inst.op == :lshr; lower_lshr!(gates, wa, a, k, W)
            else                      lower_ashr!(gates, wa, a, k, W)
            end
        else
            b = resolve!(gates, wa, vw, inst.op2, inst.width)
            if inst.op == :shl;   lower_var_shl!(gates, wa, a, b, W)
            elseif inst.op == :lshr; lower_var_lshr!(gates, wa, a, b, W)
            else                      lower_var_ashr!(gates, wa, a, b, W)
            end
        end
    else
        b = resolve!(gates, wa, vw, inst.op2, inst.width)
        # Use Cuccaro in-place adder when op2 is dead after this instruction.
        # Constants are always safe (their wires are freshly allocated by resolve!).
        # SSA vars are safe when this is their last use (liveness[name] <= inst_idx).
        op2_dead = inst.op2.kind == :const ||
                   (inst.op2.kind == :ssa && get(ssa_liveness, inst.op2.name, 0) <= inst_idx)
        if inst.op == :add
            strat = _pick_add_strategy(add, W, op2_dead, !isempty(ssa_liveness))
            if strat == :cuccaro
                lower_add_cuccaro!(gates, wa, a, b, W)
            elseif strat == :qcla
                lower_add_qcla!(gates, wa, a, b, W)[1:W]   # drop carry-out
            else
                lower_add!(gates, wa, a, b, W)
            end
        elseif inst.op == :sub; lower_sub!(gates, wa, a, b, W)
        elseif inst.op == :mul
            mstrat = _pick_mul_strategy(mul, W)
            if mstrat == :qcla_tree
                lower_mul_qcla_tree!(gates, wa, a, b, W)[1:W]   # mod 2^W
            else
                lower_mul!(gates, wa, a, b, W)
            end
        elseif inst.op == :and; lower_and!(gates, wa, a, b, W)
        elseif inst.op == :or;  lower_or!(gates, wa, a, b, W)
        elseif inst.op == :xor; lower_xor!(gates, wa, a, b, W)
        elseif inst.op in (:udiv, :urem, :sdiv, :srem)
            lower_divrem!(gates, wa, vw, inst, a, b, W)
        else error("lower_binop!: unknown binop :$(inst.op) (supported: $_IR_BINOP_OPS)")
        end
    end

    vw[inst.dest] = result
end

# ---- bitwise ----

function lower_and!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W; push!(g, ToffoliGate(a[i], b[i], r[i])); end
    return r
end

function lower_or!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], r[i]))
        push!(g, CNOTGate(b[i], r[i]))
        push!(g, ToffoliGate(a[i], b[i], r[i]))
    end
    return r
end

function lower_xor!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], r[i]))
        push!(g, CNOTGate(b[i], r[i]))
    end
    return r
end

# ---- shifts (constant amount only) ----

# Bennett-zmw3 / U111: constant-shift bounds for `lower_shl!` / `lower_lshr!`
# / `lower_ashr!`. LLVM defines `shl/lshr/ashr` with `k >= W` as poison, but
# Julia's `<<`/`>>` wrappers always emit a guarded select so frontends never
# emit a bare shift with `k >= W`. We accept `k == W` (returns zero for
# shl/lshr; sign-extension for ashr) and `0 <= k < W` (the normal range).
# Negative `k` would silently iterate over invalid wire indices; reject loud.
@inline _check_const_shift(k::Int, W::Int) = (0 <= k <= W) || error(
    "lower_shl!/lshr!/ashr!: constant shift k=$k out of [0, W] for W=$W " *
    "(Bennett-zmw3 / U111)")

function lower_shl!(g, wa, a, k, W)
    _check_const_shift(k, W)
    r = allocate!(wa, W)
    # k == W: empty loop → returns the freshly-allocated all-zero vector.
    # That matches Julia's `<< W` (saturates to zero).
    for i in (k + 1):W; push!(g, CNOTGate(a[i - k], r[i])); end
    return r
end

function lower_lshr!(g, wa, a, k, W)
    _check_const_shift(k, W)
    r = allocate!(wa, W)
    # k == W: empty loop → all-zero result (matches Julia `>>> W`).
    for i in 1:(W - k); push!(g, CNOTGate(a[i + k], r[i])); end
    return r
end

function lower_ashr!(g, wa, a, k, W)
    _check_const_shift(k, W)
    r = allocate!(wa, W)
    # k == W: first loop empty, second loop fills every bit with the sign
    # bit a[W] (sign-extension to all-ones for negative inputs, all-zero for
    # non-negative). Matches Julia `>> W` for arithmetic shift.
    for i in 1:(W - k); push!(g, CNOTGate(a[i + k], r[i])); end
    for i in (W - k + 1):W; push!(g, CNOTGate(a[W], r[i])); end
    return r
end

# ---- variable-amount shifts (barrel shifter) ----
#
# Bennett-zmw3 / U111: variable-shift semantics. The `_shift_stages` helper
# bounds the number of MUX stages at `min(b_len, ceil(log2(W)))`, so the
# barrel shifter only consumes bits 0..ceil(log2(W))-1 of the shift amount.
# Effectively the shift amount is taken mod (next power of two ≥ W). For
# W = 8 this gives shift mod 8 (matches x86/ARM hardware shift semantics).
#
# Julia's `<<` / `>>` wrappers add a guarded select that zeroes the result
# when the shift amount is ≥ width — that select is part of the IR our
# compiler sees (Julia's lowering adds it), so Julia frontends always get
# Julia-saturate semantics. RAW LLVM input (e.g. from a future C/Rust
# frontend without that wrapper) gets the mod-W semantics described above
# instead of poison or zero. Future bead may add a `saturate=true` kwarg.

_shift_stages(W, b_len) = min(b_len, W <= 1 ? 0 : ceil(Int, log2(W)))

function lower_var_lshr!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i + s
            src <= W && push!(g, CNOTGate(result[src], shifted[i]))
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

function lower_var_shl!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i - s
            src >= 1 && push!(g, CNOTGate(result[src], shifted[i]))
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

function lower_var_ashr!(g, wa, a, b, W)
    result = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(a[i], result[i])); end
    for k in 0:_shift_stages(W, length(b))-1
        s = 1 << k
        s >= W && break
        shifted = allocate!(wa, W)
        for i in 1:W
            src = i + s
            if src <= W
                push!(g, CNOTGate(result[src], shifted[i]))
            else
                push!(g, CNOTGate(result[W], shifted[i]))
            end
        end
        result = lower_mux!(g, wa, [b[k+1]], shifted, result, W)
    end
    return result
end

# ---- comparison (icmp) ----

function lower_icmp!(gates, wa, vw, inst::IRICmp)
    a = resolve!(gates, wa, vw, inst.op1, inst.width)
    b = resolve!(gates, wa, vw, inst.op2, inst.width)
    W = inst.width; p = inst.predicate

    result = if p == :eq;  lower_eq!(gates, wa, a, b, W)
    elseif p == :ne;       lower_not1!(gates, wa, lower_eq!(gates, wa, a, b, W))
    elseif p == :ult;      lower_ult!(gates, wa, a, b, W)
    elseif p == :ugt;      lower_ult!(gates, wa, b, a, W)
    elseif p == :ule;      lower_not1!(gates, wa, lower_ult!(gates, wa, b, a, W))
    elseif p == :uge;      lower_not1!(gates, wa, lower_ult!(gates, wa, a, b, W))
    elseif p == :slt;      lower_slt!(gates, wa, a, b, W)
    elseif p == :sgt;      lower_slt!(gates, wa, b, a, W)
    elseif p == :sle;      lower_not1!(gates, wa, lower_slt!(gates, wa, b, a, W))
    elseif p == :sge;      lower_not1!(gates, wa, lower_slt!(gates, wa, a, b, W))
    else error("lower_icmp!: unknown predicate :$p (supported: $_IR_ICMP_PREDS)")
    end
    vw[inst.dest] = result
end

function lower_eq!(g, wa, a, b, W)
    diff = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], diff[i]))
        push!(g, CNOTGate(b[i], diff[i]))
    end
    if W == 1
        r = allocate!(wa, 1)
        push!(g, CNOTGate(diff[1], r[1])); push!(g, NOTGate(r[1]))
        return r
    end
    or = allocate!(wa, W - 1)
    push!(g, CNOTGate(diff[1], or[1]))
    push!(g, CNOTGate(diff[2], or[1]))
    push!(g, ToffoliGate(diff[1], diff[2], or[1]))
    for k in 2:(W - 1)
        push!(g, CNOTGate(or[k - 1], or[k]))
        push!(g, CNOTGate(diff[k + 1], or[k]))
        push!(g, ToffoliGate(or[k - 1], diff[k + 1], or[k]))
    end
    r = allocate!(wa, 1)
    push!(g, CNOTGate(or[W - 1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

function lower_ult!(g, wa, a, b, W)
    nb = allocate!(wa, W)
    for i in 1:W; push!(g, CNOTGate(b[i], nb[i])); push!(g, NOTGate(nb[i])); end
    carry = allocate!(wa, W + 1)
    push!(g, NOTGate(carry[1]))
    axnb = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], axnb[i])); push!(g, CNOTGate(nb[i], axnb[i]))
        push!(g, ToffoliGate(a[i], nb[i], carry[i + 1]))
        push!(g, ToffoliGate(axnb[i], carry[i], carry[i + 1]))
    end
    r = allocate!(wa, 1)
    push!(g, CNOTGate(carry[W + 1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

function lower_slt!(g, wa, a, b, W)
    af = allocate!(wa, W); bf = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(a[i], af[i])); push!(g, CNOTGate(b[i], bf[i]))
    end
    push!(g, NOTGate(af[W])); push!(g, NOTGate(bf[W]))
    return lower_ult!(g, wa, af, bf, W)
end

function lower_not1!(g, wa, w::Vector{Int})
    r = allocate!(wa, 1)
    push!(g, CNOTGate(w[1], r[1])); push!(g, NOTGate(r[1]))
    return r
end

# ---- select (mux) ----

function lower_select!(gates, wa, vw, inst::IRSelect; ctx::Union{Nothing,LoweringCtx}=nothing)
    # Bennett-cc0 M2b: pointer-typed select (width=0 sentinel). Metadata-only
    # routing: merge origins from both sides, guarded by cond / NOT(cond).
    if inst.width == 0
        ctx === nothing &&
            error("lower_select!: ptr-select %$(inst.dest) requires ctx for ptr_provenance threading")
        inst.op1.kind == :ssa ||
            error("lower_select!: ptr-select %$(inst.dest) true-side is non-SSA ($(inst.op1))")
        inst.op2.kind == :ssa ||
            error("lower_select!: ptr-select %$(inst.dest) false-side is non-SSA ($(inst.op2))")
        haskey(ctx.ptr_provenance, inst.op1.name) ||
            error("lower_select!: ptr-select %$(inst.dest) true-side %$(inst.op1.name) has no provenance")
        haskey(ctx.ptr_provenance, inst.op2.name) ||
            error("lower_select!: ptr-select %$(inst.dest) false-side %$(inst.op2.name) has no provenance")

        cond = resolve!(gates, wa, vw, inst.cond, 1)
        not_cond = _not_wire!(gates, wa, cond)

        merged = PtrOrigin[]
        for o in ctx.ptr_provenance[inst.op1.name]
            combined = _and_wire!(gates, wa, [o.predicate_wire], cond)
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
        end
        for o in ctx.ptr_provenance[inst.op2.name]
            combined = _and_wire!(gates, wa, [o.predicate_wire], not_cond)
            push!(merged, PtrOrigin(o.alloca_dest, o.idx_op, combined[1]))
        end
        length(merged) <= 8 ||
            error("lower_select!: ptr-select %$(inst.dest) fan-out $(length(merged)) > 8 " *
                  "exceeds M2b budget; file a bd issue")
        ctx.ptr_provenance[inst.dest] = merged
        return  # no vw[inst.dest] — pointers don't materialize as wires
    end

    cond = resolve!(gates, wa, vw, inst.cond, 1)
    tv   = resolve!(gates, wa, vw, inst.op1, inst.width)
    fv   = resolve!(gates, wa, vw, inst.op2, inst.width)
    vw[inst.dest] = lower_mux!(gates, wa, cond, tv, fv, inst.width)
end

function lower_mux!(g, wa, cond, tv, fv, W)
    r    = allocate!(wa, W)
    diff = allocate!(wa, W)
    for i in 1:W
        push!(g, CNOTGate(fv[i], r[i]))
        push!(g, CNOTGate(tv[i], diff[i]))
        push!(g, CNOTGate(fv[i], diff[i]))
        push!(g, ToffoliGate(cond[1], diff[i], r[i]))
    end
    return r
end

# ---- casts (sext, zext, trunc) ----

function lower_cast!(gates, wa, vw, inst::IRCast)
    src = resolve!(gates, wa, vw, inst.operand, inst.from_width)
    F = inst.from_width
    T = inst.to_width
    r = allocate!(wa, T)

    if inst.op == :zext
        for i in 1:F; push!(gates, CNOTGate(src[i], r[i])); end
    elseif inst.op == :sext
        for i in 1:F; push!(gates, CNOTGate(src[i], r[i])); end
        for i in F+1:T; push!(gates, CNOTGate(src[F], r[i])); end
    elseif inst.op == :trunc
        # Bennett-gboa / U139 wire-state contract:
        #   - r[1:T] ← src[1:T] (CNOT-copy of the low T bits).
        #   - src[T+1..F] are NOT touched: they remain at their SSA-input
        #     values for the rest of the gate sequence. This is intentional
        #     — `src` is a pure SSA read, not consumed. Bennett's outer
        #     reverse pass uncomputes whatever produced src in the first
        #     place; the high bits never need explicit zeroing here.
        #   - r is freshly allocated (zero-initialised), so the result wires
        #     don't have a "dirty" issue.
        # If a future liveness pass wants to free src mid-circuit, it must
        # first uncompute src's full F-bit producer — NOT just bits 1..T.
        # Pinned by `test/test_gboa_dirty_bit_hygiene.jl`.
        for i in 1:T; push!(gates, CNOTGate(src[i], r[i])); end
    else
        error("lower_cast!: unknown cast op :$(inst.op) (supported: $_IR_CAST_OPS)")
    end

    vw[inst.dest] = r
end

