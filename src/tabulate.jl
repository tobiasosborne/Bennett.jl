# ---- Tabulate strategy: classical eval → QROM lookup ----
#
# For pure functions at small total input bit width, expression-graph
# compilation holds every SSA intermediate live simultaneously, producing
# O(n_ssa) wires even for W as small as 2 (e.g. x^2+3x+1 at W=2 → 43 wires).
# We bypass the whole lowering by evaluating f classically on all 2^W
# inputs, packing the results into a compile-time table, and emitting the
# transformation (x, 0^W_out) → (x, f(x)) via the existing Babbush-Gidney
# QROM (src/qrom.jl).
#
# Cost: 2(L-1) Toffoli (self-reversing, no Bennett wrap) + O(L·W_out) CNOT,
# L = 2^sum(input_widths). Complexity independent of expression depth —
# depends only on input-domain size.

"""
    _tabulate_input_widths(arg_types, bit_width) -> Vector{Int}

Per-argument bit widths. `bit_width=0` means use each type's natural width
(`sizeof(T)*8`). `bit_width > 0` overrides all widths (matches `_narrow_ir`).
"""
function _tabulate_input_widths(arg_types::Type{<:Tuple}, bit_width::Int)
    widths = Int[]
    for T in arg_types.parameters
        w = bit_width > 0 ? bit_width : sizeof(T) * 8
        push!(widths, w)
    end
    return widths
end

"""
    _tabulate_narrows(arg_types, bit_width) -> Bool

Does the compile ask for `_narrow_ir` semantics? (Bennett-iwj6 / F2)

True for ANY explicit `bit_width > 0` — including `bit_width` equal to the
arguments' natural width. `bit_width=W` asks the expression path for W-bit
two's-complement modular semantics (`_narrow_ir`, Bennett-mrhg), so a function
that widens internally (`Int16(x)*Int16(x) > 200` on an `Int8` argument) is a
different function at `bit_width=8` than at natural width: the table matched
native Julia while `strategy=:expression` differed on 191/256 inputs. Only
`bit_width=0` leaves the function the table evaluates.
"""
function _tabulate_narrows(arg_types::Type{<:Tuple}, bit_width::Int)
    return bit_width > 0
end

"""
    _tabulate_applicable(arg_types, bit_width) -> (Bool, String)

Predicate for whether the tabulate path can handle this compile. Returns
`(applicable, reason)`. Non-applicable reasons are short messages for the
explicit-`:tabulate` error path.

Bennett-iwj6 / F2 added the narrowing arm. The table is built by evaluating
`f` — the ORIGINAL, natural-width Julia function — on `0:2^W-1` and masking
each result. `strategy=:expression` instead does W-bit modular arithmetic:
the sign bit sits at W-1 and every intermediate wraps mod 2^W, so a branch on
a sign or a shift after an overflowing multiply sees different values. That
is not a decoding bug, it is a different function, and a classical evaluator
cannot recover it (re-evaluating an Int8 body in 4 bits IS a compiler).
Narrowed compiles therefore must not be tabulated: `:auto` falls through to
expression lowering, explicit `:tabulate` raises.
"""
function _tabulate_applicable(arg_types::Type{<:Tuple}, bit_width::Int)
    isempty(arg_types.parameters) && return (false, "no arguments")
    for T in arg_types.parameters
        T <: Integer || return (false, "non-integer arg type $T (got $(arg_types.parameters))")
    end
    if _tabulate_narrows(arg_types, bit_width)
        natural = join([sizeof(T) * 8 for T in arg_types.parameters], ", ")
        return (false,
            "bit_width=$bit_width requests narrowed semantics for $(arg_types.parameters) (natural width(s): " *
            "$natural bits) and the QROM table evaluates f at its natural width, " *
            "so it cannot reproduce W-bit modular arithmetic — the sign bit at " *
            "bit W-1 and intermediate overflow mod 2^W before a comparison or a " *
            "shift. Use strategy=:expression, or :auto, which falls through to it " *
            "(Bennett-iwj6)")
    end
    widths = _tabulate_input_widths(arg_types, bit_width)
    total = sum(widths)
    # Hard cap: 2^16 = 65536 entries. Beyond that the table itself is larger
    # than the IR-lowered circuit for any realistic function.
    total <= 16 || return (false, "total input width $total exceeds tabulate cap (16)")
    return (true, "")
end

"""
    _tabulate_out_width(f, arg_types, bit_width) -> (Int, String)

Output width of the QROM table, or `(0, reason)` when `f` has no table layout.
(Bennett-iwj6 / F3.)

`out_width` used to be the FIRST ARGUMENT's width, which truncated a widening
return: `f(x::Int8) = Int16(x)*Int16(x)` gave an 8-bit output (-112 at
`x=20`) where `strategy=:expression` gives 400 in 16 bits. The width now
comes from the function itself:

  * `bit_width > 0` — never reaches here: `_tabulate_applicable` refuses
    every explicit `bit_width` (see `_tabulate_narrows`).
  * `bit_width == 0` (no narrowing) — the answer is `8*sizeof(R)` for the
    single concrete fixed-width Integer return type `R` that
    `Base.return_types` infers, which is the width the expression path reads
    off the LLVM `ret`.

A return type that is not one of those (a tuple, a Float64, a non-concrete
inference result) is refused rather than guessed at.
"""
function _tabulate_out_width(f, arg_types::Type{<:Tuple}, bit_width::Int)
    rts = try
        Base.return_types(f, arg_types)
    catch e
        return (0, "return type of $f on $arg_types could not be inferred ($e) (Bennett-iwj6)")
    end
    length(rts) == 1 || return (0,
        "expected exactly one inferred return type for $f on $arg_types, got $rts (Bennett-iwj6)")
    R = rts[1]
    isconcretetype(R) || return (0, "$f returns the non-concrete type $R on $arg_types (Bennett-iwj6)")
    # `_SUPPORTED_SCALAR_ARGS` (src/Bennett.jl) is the fixed-width whitelist
    # `reversible_compile` already applies to arguments; the QROM table holds
    # at most 64 output bits, so the return must be one of those integers.
    (R <: Integer && R in _SUPPORTED_SCALAR_ARGS) || return (0,
        "$f returns $R on $arg_types; the QROM table needs a single " *
        "fixed-width scalar Integer return, one of " *
        "$([T for T in _SUPPORTED_SCALAR_ARGS if T <: Integer]) (Bennett-iwj6)")
    # `_tabulate_applicable` has already refused every `bit_width > 0`
    # (see `_tabulate_narrows`), so the width is always the return type's.
    return (8 * sizeof(R), "")
end

"""
    _tabulate_auto_picks(parsed, arg_types, bit_width) -> Bool

Cost-model dispatch: does `:auto` pick tabulate for this compile?

Two-factor heuristic:
  1. **Size**: total input bit width ≤ 4 (table ≤ 16 entries). QROM cost grows
     as 2(2^W_in - 1) Toffoli; beyond W=4 the expression path nearly always
     catches up.
  2. **Complexity**: the IR contains at least one O(W²)-lowered op
     (`mul`, `udiv`, `sdiv`, `urem`, `srem`). Pure add/sub/shift/bitwise
     functions lower to O(W) gates via ripple — cheaper than any QROM.

Both must hold, which is what kept `x+1` on the (much cheaper) expression path
at every width while routing the tabulate-shaped `x^2+3x+1` to a QROM.

Bennett-iwj6 / F2: `_tabulate_applicable` now refuses a narrowed compile, so
factor 1 can only be met by a natural-width argument. Every scalar type
`reversible_compile` supports is ≥ 8 bits wide, so today this predicate
routes nothing and the `:auto` redirect in `reversible_compile` is inert; it
stays wired (and stays correct) for when a narrow-enough argument type
appears.
"""
function _tabulate_auto_picks(parsed::ParsedIR, arg_types::Type{<:Tuple}, bit_width::Int)
    ok, _ = _tabulate_applicable(arg_types, bit_width)
    ok || return false
    widths = _tabulate_input_widths(arg_types, bit_width)
    sum(widths) <= 4 || return false
    return _has_expensive_op(parsed)
end

"""Does this parsed IR contain an op whose expression-path lowering is O(W²) or worse?"""
function _has_expensive_op(parsed::ParsedIR)
    for block in parsed.blocks
        for inst in block.instructions
            if inst isa IRBinOp && inst.op in (:mul, :udiv, :sdiv, :urem, :srem)
                return true
            end
        end
    end
    return false
end

"""
Reinterpret a UInt64 bit pattern as type T (Integer), placing the low
`width` bits of `raw` into T's bit pattern. T gets the full signed/unsigned
interpretation of its own width; we only care that the low `width` bits
match `raw`. For W < sizeof(T)*8 the high bits are zero (idx is in the
nonnegative range 0..2^W-1 by construction).
"""
function _raw_bits_to_type(raw::UInt64, ::Type{T}) where {T<:Integer}
    if T === Int8 || T === UInt8
        return reinterpret(T, UInt8(raw & 0xff))
    elseif T === Int16 || T === UInt16
        return reinterpret(T, UInt16(raw & 0xffff))
    elseif T === Int32 || T === UInt32
        return reinterpret(T, UInt32(raw & 0xffffffff))
    elseif T === Int64 || T === UInt64
        return reinterpret(T, raw)
    elseif T === Bool
        return (raw & 0x1) != 0
    else
        # Fallback: try T(x) for unknown integer types (BigInt etc.)
        return T(raw)
    end
end

"""Reinterpret any Integer result into UInt64 bits (low bits preserved)."""
function _result_to_uint64(y::Integer)
    if y isa Bool
        return UInt64(y)
    elseif y isa Int8
        return UInt64(reinterpret(UInt8, y))
    elseif y isa Int16
        return UInt64(reinterpret(UInt16, y))
    elseif y isa Int32
        return UInt64(reinterpret(UInt32, y))
    elseif y isa Int64
        return reinterpret(UInt64, y)
    elseif y isa Unsigned
        return UInt64(y)
    else
        return UInt64(y & typemax(UInt64))
    end
end

"""
    _tabulate_build_table(f, arg_types, input_widths, out_width) -> Vector{UInt64}

Enumerate every input tuple in [0, 2^w_k) per arg, evaluate `f`, and pack
the result into `low(out_width)` of a UInt64. Returns a vector of length
`2^sum(input_widths)`.

The idx layout matches the simulator: input k occupies bits
`[sum(W_1..W_{k-1}), sum(W_1..W_k))` of the flat index, LSB-first within
each arg.
"""
function _tabulate_build_table(f, arg_types::Type{<:Tuple},
                               input_widths::Vector{Int}, out_width::Int)
    L = 1 << sum(input_widths)
    table = Vector{UInt64}(undef, L)
    mask_out = out_width == 64 ? typemax(UInt64) : (UInt64(1) << out_width) - UInt64(1)
    arg_T = arg_types.parameters

    for raw_idx in 0:(L - 1)
        args = _unpack_args(UInt64(raw_idx), input_widths, arg_T)
        # Bennett-vtv9: a table needs f's value on EVERY input.
        y = try
            f(args...)
        catch e
            throw(ArgumentError(
                "reversible_compile: strategy=:tabulate not applicable — $f " *
                "throws for input $args ($(sprint(showerror, e))); a table " *
                "needs a value for every input (Bennett-vtv9)"))
        end
        y isa Integer || error("tabulate: f returned $(typeof(y)); only Integer " *
                               "returns are supported for tabulate strategy")
        table[raw_idx + 1] = _result_to_uint64(y) & mask_out
    end
    return table
end

"""Split a packed index into per-arg values, LSB-first.

Bennett-b2fs / U148: returns a `Tuple` (heterogeneously typed,
stack-allocated) instead of the previous `Vector{Any}` (per-row
heap allocation + boxed elements). `_tabulate_build_table` runs
this once per table row and `2^total_in` rows can reach 16M+ on
24-bit input spaces; the Vector{Any} form was 32+ bytes of
garbage per call.
"""
function _unpack_args(raw::UInt64, input_widths::Vector{Int}, arg_T)
    n = length(input_widths)
    return ntuple(n) do k
        # Shift past the first (k-1) args to reach this arg's window.
        prefix_w = 0
        @inbounds for j in 1:(k - 1)
            prefix_w += input_widths[j]
        end
        @inbounds w = input_widths[k]
        m = (UInt64(1) << w) - UInt64(1)
        v = (raw >> prefix_w) & m
        @inbounds _raw_bits_to_type(v, arg_T[k])
    end
end

"""
    lower_tabulate(f, arg_types, input_widths; out_width,
                   auto_self_reversing=true) -> LoweringResult

Build a `LoweringResult` that computes `(x, 0^W_out) → (x, f(x))` via QROM.
Emits a single `emit_qrom!` over a compile-time table built by evaluating
`f` on every input. Marks the result `self_reversing=true` (when
`auto_self_reversing=true`, the default) so `bennett()` skips the
copy+uncompute wrap — QROM is already self-clean.

# Bennett-h0ai (producer-tag)

The emitted `LoweringResult` also carries a single `GateGroup` named
`:__tabulate_qrom` over the entire QROM gate block, with
`is_self_reversing=true`. This is the second known producer-tag emit
site (alongside the qcla_tree mul dispatch in `src/lowering/arith.jl`),
and makes the contract explicit and inferrable by `_infer_self_reversing`
if a future caller routes tabulate through `lower(parsed)` as a
subroutine. The tag's `result_wires` are exactly `lr.output_wires`
(no truncation, no post-processing), satisfying the producer-tag
invariant documented in `src/lowering/types.jl:7-26`.

# Kill-switch

Setting `auto_self_reversing=false` suppresses the LR-level
`self_reversing` flag (constructed `false` instead of `true`). The
producer-tag on the GateGroup remains regardless — only the top-level
LR flag is affected. This mirrors the kill-switch semantics threaded
through `lower(parsed)` and `reversible_compile`, so the Bennett wrap
(forward + copy-out + reverse) is engaged end-to-end for benchmarking
and regression bisects.
"""
function lower_tabulate(f, arg_types::Type{<:Tuple},
                        input_widths::Vector{Int}; out_width::Int,
                        auto_self_reversing::Bool=true)
    1 <= out_width <= 64 ||
        throw(ArgumentError("tabulate: out_width must be in 1..64, got $out_width"))

    total_in = sum(input_widths)
    L = 1 << total_in

    table = _tabulate_build_table(f, arg_types, input_widths, out_width)

    wa = WireAllocator()
    gates = ReversibleGate[]

    # Allocate input wires, flat layout matching the simulator's expectation.
    input_wires = allocate!(wa, total_in)
    wire_start = first(input_wires)  # mirror lower_block_insts! convention

    # QROM requires power-of-two L; by construction L = 2^total_in is one.
    # idx_wires are the input_wires in-order (LSB-first within each arg,
    # args concatenated — matches simulator).
    output_wires = emit_qrom!(gates, wa, table, input_wires, out_width)

    # Bennett-h0ai: emit a single producer-tagged GateGroup spanning the
    # entire QROM block. Degenerate empty-table case yields no group.
    gate_groups = if length(gates) > 0
        group = GateGroup(
            :__tabulate_qrom,           # ssa_name (fresh prefix — does not collide
                                        # with __pred_/__ret_/__branch_ boilerplate)
            1,                          # gate_start (1-based, inclusive)
            length(gates),              # gate_end
            copy(output_wires),         # result_wires (copy to avoid aliasing LR.output_wires)
            Symbol[],                   # input_ssa_vars (tabulate has no SSA inputs)
            wire_start,                 # wire_start (mirror lower_block_insts! convention)
            wa.next_wire - 1,           # wire_end (mirror driver.jl:386)
            Int[],                      # cleanup_wires (QROM is self-clean; nothing to replay-free)
            true,                       # is_self_reversing — the producer-tag
        )
        GateGroup[group]
    else
        GateGroup[]
    end

    return LoweringResult(gates, wire_count(wa), input_wires, output_wires,
                          copy(input_widths), [out_width],
                          gate_groups, auto_self_reversing)
end

"""
    _tabulate_impurity(f, arg_types) -> String

Bennett-vtv9: `""` when `f` on `arg_types` is certified a pure function of
its arguments, else the reason it is not. A table is `f` evaluated at compile
time, so any external state `f` reads is frozen into it (a global
`Ref` read gave circuit 4, native 10 after the `Ref` changed), and any
external effect happens at compile time instead of at run time. The callable's
OWN state is handled by `_callable_state_bytes` (Bennett-o9sv / 2op8 / sfq8);
this covers state reached through globals and impure calls.

The certificate is Julia's effect analysis (`Base.infer_effects`):

  * `effect_free` — no store to global state, no impure or foreign call
    (`rand()`, `time_ns()`, I/O, `ccall`);
  * `consistent` (same result for egal arguments), OR `inaccessiblememonly`
    (touches no externally reachable mutable memory). The second arm admits
    a pure function whose only inconsistency is memory it allocates itself (a
    local `Vector` is not `consistent` because fresh memory starts undefined);
    a global `Ref` / `Vector` / `Dict` / mutable struct or a non-const global
    variable fails both arms.

When the effects fail, `f` is still certified if `strategy=:expression`
compiles it (see the comment in the body) — the analysis is conservative and
cannot see through e.g. `reinterpret` of a primitive type.

Uncertified (accepted by the `inaccessiblememonly` arm): results that depend
on locally allocated memory read before it is written, or on a local object's
identity (`objectid`). Refused although pure: code neither the effect
analysis nor the expression path can see through (e.g. one that formats a
`String`).
"""
function _tabulate_impurity(f, arg_types::Type{<:Tuple})
    C = Base.Compiler
    eff = try
        Base.infer_effects(f, arg_types)
    catch e
        return "the effects of $f on $arg_types could not be inferred " *
               "($(sprint(showerror, e))), so it is not certified free of " *
               "external state (Bennett-vtv9)"
    end
    classes = String[]
    C.is_effect_free(eff) || push!(classes,
        "has a side effect or calls an impure function (a store to global " *
        "state, rand(), time(), I/O, a foreign call)")
    (C.is_consistent(eff) || C.is_inaccessiblememonly(eff)) || push!(classes,
        "reads mutable or non-constant global state (a global Ref / Vector / " *
        "Dict / mutable struct, or a non-const global variable)")
    isempty(classes) && return ""
    # Second certificate: the compiler's own expression path. It models every
    # value f computes from its IR and refuses a load from / store to Julia
    # global memory and any call it cannot resolve, so if it compiles f, f is
    # a function of its arguments (and its bound callable state) as far as
    # this compiler can tell — no less sound than `strategy=:expression`.
    # Needed for pure code effect analysis cannot see through: `reinterpret`
    # of a primitive type goes through a memcpy foreigncall (every effect
    # tainted) that LLVM optimises away (Bennett-sfq8 P24 / P40 callables).
    expr_err = try
        reversible_compile(f, arg_types; strategy=:expression)
        nothing
    catch e
        e isa InterruptException && rethrow()
        e
    end
    expr_err === nothing && return ""
    return "$f on $arg_types " * join(classes, " and ") * " (Julia effects: " *
           "$eff), and strategy=:expression does not certify it either (" *
           first(split(sprint(showerror, expr_err), '\n')) * "). A table " *
           "evaluates f once at compile time, so that state would be frozen " *
           "into the circuit; pass the state as an explicit argument " *
           "(Bennett-vtv9)"
end

"""
    _tabulate_circuit(f, arg_types, bit_width, auto_self_reversing)
        -> (LoweringResult, String) | (nothing, String)

The ONE tabulate decision, shared by both exits in `reversible_compile`
(explicit `strategy=:tabulate` and the `:auto` cost-model redirect).
Returns `(lr, "")` when the compile may be tabulated, else
`(nothing, reason)` — the caller turns that into an `ArgumentError`
(explicit) or falls through to expression lowering (`:auto`).

Before Bennett-iwj6 each exit recomputed `out_width` from the first
argument and neither consulted the other's eligibility rules, so the two
could disagree about what a table means.
"""
function _tabulate_circuit(f, arg_types::Type{<:Tuple}, bit_width::Int,
                            auto_self_reversing::Bool)
    ok, reason = _tabulate_applicable(arg_types, bit_width)
    ok || return (nothing, reason)
    impure = _tabulate_impurity(f, arg_types)
    isempty(impure) || return (nothing, impure)
    out_width, why = _tabulate_out_width(f, arg_types, bit_width)
    out_width > 0 || return (nothing, why)
    widths = _tabulate_input_widths(arg_types, bit_width)
    lr = lower_tabulate(f, arg_types, widths; out_width, auto_self_reversing)
    return (lr, "")
end
