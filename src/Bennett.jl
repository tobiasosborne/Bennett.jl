module Bennett

include("ir_types.jl")
include("ir_extract.jl")
# Bennett-cs2f / U42: src/ir_parser.jl deleted 2026-04-25 — the regex
# IR parser was dead legacy and violated CLAUDE.md §5 (LLVM IR is not
# stable).  The C-API walker in ir_extract.jl is the source of truth.
include("gates.jl")
include("wire_allocator.jl")
include("adder.jl")
include("qcla.jl")
include("multiplier.jl")
# Bennett-9c4o / U89: deps that lower.jl forward-references load BEFORE
# lower.jl so the file is standalone-loadable. softfloat precedes softmem
# (uses soft_fadd); fast_copy/partial_products/parallel_adder_tree precede
# mul_qcla_tree.
include("divider.jl")
include("softfloat/softfloat.jl")
# Bennett-iwv5 / U90: softfloat primitives live in submodule SoftFloatLib
# so internal helpers (~75) and bit-pattern constants stay module-private.
# `using` re-exposes the 32 public soft_* names at Bennett scope so the
# downstream files (softmem, callees, lowering/*, persistent) keep their
# unqualified `soft_fadd(...)` references.
using .SoftFloatLib
include("softmem.jl")
include("qrom.jl")
include("shadow_memory.jl")
include("fast_copy.jl")
include("partial_products.jl")
include("parallel_adder_tree.jl")
include("mul_qcla_tree.jl")
include("lower.jl")
include("bennett_transform.jl")
include("simulator.jl")
include("diagnostics.jl")
include("controlled.jl")
include("compose.jl")
include("dep_dag.jl")
# Bennett-zpj7 / U160 (2026-04-30): five pebbling/eager strategy files
# colocated into src/pebble/ to surface them as a coherent group. Filenames
# preserved (no rename) — git blame and external doc refs survive intact.
include("pebble/pebbling.jl")
include("pebble/eager.jl")
include("pebble/value_eager.jl")
include("pebble/pebbled_groups.jl")
# Bennett-u2yp / U149 (2026-05-01): src/pebble/sat_pebbling.jl + PicoSAT
# dep dropped — 211 LOC unwired into any strategy dispatcher and the
# replacement-with-modern-solver task lives in Bennett-fg2 (P2). Re-
# introduce here when fg2 lands a Kissat/CaDiCaL backend.
# Bennett-i2ca / U55 (2026-05-01): unify the 5 *_bennett aliases under
# `bennett(lr; strategy=...)` via `abstract type BennettStrategy`. Loaded
# AFTER bennett_transform.jl + every pebble/*.jl so the dispatch methods
# can reach the renamed `_*_impl` bodies.
include("bennett_strategies.jl")
include("tabulate.jl")
include("memssa.jl")
include("feistel.jl")
include("persistent/persistent.jl")
# Bennett-iwv5 / U90: persistent-DS public surface (PersistentMapImpl,
# verify_pmap_*, LINEAR_SCAN_IMPL, soft_feistel*) re-exposed at Bennett
# scope; internal helpers (_LS_STATE_LEN, _FEISTEL_HALF_W, …) stay module-
# private.
using .Persistent

export reversible_compile, simulate, simulate!, diagnose_nonzero, extract_ir, extract_parsed_ir, register_callee!
# Bennett-u71l / U161: bundled options struct; single source of defaults.
export CompileOptions
export extract_parsed_ir_from_ll, extract_parsed_ir_from_bc
export PersistentMapImpl, AbstractPersistentMap, verify_pmap_correctness, verify_pmap_persistence_invariant, pmap_demo_oracle, LINEAR_SCAN_IMPL
# Bennett-uoem / U54: OKASAKI_IMPL + Okasaki API relocated to
# src/persistent/research/okasaki_rbt.jl (2026-04-25).
# Bennett-uoem / U54: CF_IMPL + cf_pmap_*/cf_reroot relocated to
# src/persistent/research/cf_semi_persistent.jl (2026-04-25).
# Bennett-uoem / U54: HAMT_IMPL + hamt_pmap_*/soft_popcount32 relocated to
# src/persistent/research/{hamt,popcount}.jl (2026-04-25).
# Bennett-uoem / U54: soft_jenkins96 + soft_jenkins_int8 relocated to
# src/persistent/research/hashcons_jenkins.jl (2026-04-25).
export soft_feistel32, soft_feistel_int8
export soft_fadd, soft_fsub, soft_fmul, soft_fma, soft_fdiv, soft_fsqrt, soft_fneg, soft_fcmp_olt, soft_fcmp_oeq, soft_fcmp_ole, soft_fcmp_une, soft_fptosi, soft_fptoui, soft_sitofp, soft_fpext, soft_fptrunc, soft_exp, soft_exp2, soft_exp_fast, soft_exp2_fast, soft_exp_julia, soft_exp2_julia, soft_log, soft_log2, soft_log10, soft_pow, soft_powi, soft_pow_julia, soft_sin, soft_cos, soft_tan
export ReversibleCircuit, ControlledCircuit, controlled, compose
# Bennett-qcse / U51: gate primitives documented public in docs/src/api.md
# (lines 188/192/196/211) — exporting so the documented constructors and
# type-pattern-matches resolve without `Bennett.` prefix.
export NOTGate, CNOTGate, ToffoliGate, ReversibleGate
# Bennett-qcse / U51: ParsedIR is the return type of `extract_parsed_ir`
# (REPL-visible), LoweringResult the return type of `lower` and input to
# `bennett` (referenced in docs/src/api.md:139, 211).  Exporting both.
export ParsedIR, LoweringResult
# Bennett-v958 / U68: IROperand is now an abstract type with concrete
# subtypes. Existing helpers `ssa(name)` / `iconst(value)` still construct
# the right leaf type. The OPAQUE_PTR_SENTINEL singleton is exported for
# backward compat (Bennett-ibz5 / U96 test depends on it).
export IROperand, SSAOperand, ConstOperand, OpaquePtrSentinel,
       PoisonLaneSentinel, ZeroAggSentinel, PendingVecLane,
       OPAQUE_PTR_SENTINEL, POISON_LANE, ZERO_AGG, ssa, iconst
export gate_count, ancilla_count, constant_wire_count, depth, t_count, t_depth, toffoli_depth, peak_live_wires, print_circuit, verify_reversibility
export pebbled_bennett, eager_bennett, value_eager_bennett, pebbled_group_bennett, checkpoint_bennett
# Bennett-i2ca / U55: strategy types for `bennett(lr; strategy=...)`.
export BennettStrategy, DefaultStrategy, EagerStrategy, ValueEagerStrategy,
       CheckpointStrategy, PebbledStrategy, PebbledGroupStrategy

reversible_compile(f, types::Type...; kw...) = reversible_compile(f, Tuple{types...}; kw...)

# Bennett-k0bg / U25: shared validation for the Julia-function entry points.
const _SUPPORTED_SCALAR_ARGS = (Int8, Int16, Int32, Int64,
                                UInt8, UInt16, UInt32, UInt64,
                                Float64, Bool)

"""
    CompileOptions(; optimize=true, max_loop_iterations=0,
                     compact_calls=false, bit_width=0,
                     add=:auto, mul=:auto, strategy=:auto,
                     fold_constants=true, target=:gate_count)

Bundle of all optional configuration accepted by `reversible_compile`.
Single source-of-truth for the defaults — each `reversible_compile`
overload's kwarg defaults are sourced from `CompileOptions()`.

Per-overload applicability (Bennett-u71l / U161):
- **Tuple overload** (`reversible_compile(f, arg_types::Type{<:Tuple})`)
  uses every field.
- **ParsedIR overload** (`reversible_compile(parsed::ParsedIR)`) uses
  `max_loop_iterations`, `compact_calls`, `add`, `mul`, `fold_constants`,
  `target`. Setting `optimize`, `bit_width`, or `strategy` to a non-
  default value on this path raises `ArgumentError`.
- **Float64 overload** (`reversible_compile(f, ::Type{Float64}, …)`) uses
  every field except `bit_width` (Float64 is fixed-width 64); non-default
  `bit_width` raises `ArgumentError`.

# Examples
```julia
opts = CompileOptions(add=:cuccaro, fold_constants=false)
c = reversible_compile(x -> x + Int8(1), Tuple{Int8}, opts)
```
"""
Base.@kwdef struct CompileOptions
    optimize::Bool = true
    max_loop_iterations::Int = 0
    compact_calls::Bool = false
    bit_width::Int = 0
    add::Symbol = :auto
    mul::Symbol = :auto
    strategy::Symbol = :auto
    fold_constants::Bool = true
    target::Symbol = :gate_count
end

const _DEFAULT_COMPILE_OPTIONS = CompileOptions()

# Bennett-xlsz / U29: unified kwargs validation across all three
# `reversible_compile` overloads. A raw `MethodError` on a typo or on
# a cross-overload kwarg (e.g. `bit_width` sent to the Float64 path)
# used to dump LLVM-backed lookup spew; now each overload enumerates
# the kwargs it accepts and raises a scoped `ArgumentError` pointing
# the user at the valid set.
function _reject_unknown_kwargs(overload::String, supported::Tuple,
                                 rejected_cross::Tuple, passed::Base.Pairs)
    unknown = Symbol[]
    cross   = Symbol[]
    for (k, _) in passed
        k in supported && continue
        if k in rejected_cross
            push!(cross, k)
        else
            push!(unknown, k)
        end
    end
    isempty(unknown) && isempty(cross) && return nothing
    msgs = String[]
    if !isempty(unknown)
        push!(msgs, "unknown kwarg(s) $unknown")
    end
    if !isempty(cross)
        push!(msgs, "kwarg(s) $cross not supported on this overload (see docstring)")
    end
    throw(ArgumentError(
        "reversible_compile ($overload): " * join(msgs, "; ") *
        ". Supported kwargs here: $(collect(supported))."))
end

"Check whether `T` is an argument type supported by `reversible_compile`."
@inline function _is_supported_arg_type(T::Type)
    T in _SUPPORTED_SCALAR_ARGS && return true
    # Flat NTuple whose element type is a supported scalar (common sret
    # pattern for aggregate returns; Bennett-0c8o).
    if T <: Tuple && isconcretetype(T)
        params = T.parameters
        # NTuple{N, Elt} expands to (Elt, Elt, ...) — every param equal and supported.
        !isempty(params) || return false
        all(p -> p in _SUPPORTED_SCALAR_ARGS, params) || return false
        return true
    end
    return false
end

"""
    reversible_compile(f, arg_types::Type{<:Tuple}) -> ReversibleCircuit
    reversible_compile(f, types::Type...; kw...) -> ReversibleCircuit

Compile a plain Julia function into a reversible circuit via LLVM IR.
Uses LLVM.jl to walk the IR as typed objects (no regex parsing).

# Example

```jldoctest; setup = :(using Bennett)
julia> c = reversible_compile(x -> x + Int8(1), Int8);

julia> simulate(c, Int8(5))
6

julia> gate_count(c)
(total = 58, NOT = 6, CNOT = 40, Toffoli = 12)

julia> verify_reversibility(c)
true
```
"""
const _TUPLE_OVERLOAD_KWARGS = (:optimize, :max_loop_iterations,
                               :compact_calls, :bit_width, :add, :mul,
                               :strategy, :fold_constants, :target)

function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=_DEFAULT_COMPILE_OPTIONS.optimize,
                            max_loop_iterations::Int=_DEFAULT_COMPILE_OPTIONS.max_loop_iterations,
                            compact_calls::Bool=_DEFAULT_COMPILE_OPTIONS.compact_calls,
                            bit_width::Int=_DEFAULT_COMPILE_OPTIONS.bit_width,
                            add::Symbol=_DEFAULT_COMPILE_OPTIONS.add,
                            mul::Symbol=_DEFAULT_COMPILE_OPTIONS.mul,
                            strategy::Symbol=_DEFAULT_COMPILE_OPTIONS.strategy,
                            fold_constants::Bool=_DEFAULT_COMPILE_OPTIONS.fold_constants,
                            target::Symbol=_DEFAULT_COMPILE_OPTIONS.target,
                            kwargs...)
    _reject_unknown_kwargs("Tuple overload", _TUPLE_OVERLOAD_KWARGS,
                           (), kwargs)
    # Bennett-k0bg / U25: up-front kwarg + type validation.
    # `bit_width == 0` means "infer from arg_types"; otherwise the width
    # must be in [1, 64] (powers-of-2 are the common case but narrow
    # widths like 2 and 4 are exercised by test_narrow.jl).
    (bit_width == 0 || 1 <= bit_width <= 64) || throw(ArgumentError(
        "reversible_compile: bit_width must be 0 (infer) or in [1, 64] — " *
        "got $bit_width"))
    max_loop_iterations >= 0 || throw(ArgumentError(
        "reversible_compile: max_loop_iterations must be >= 0, got " *
        "$max_loop_iterations"))
    for (i, T) in enumerate(arg_types.parameters)
        _is_supported_arg_type(T) || throw(ArgumentError(
            "reversible_compile: arg_types[$i] = $T is not supported; " *
            "expected one of $(_SUPPORTED_SCALAR_ARGS) or an NTuple of " *
            "those"))
    end

    # Bennett-4bcp / U102: NTuple{N,T} IS Tuple{T,T,...,T}, so passing
    # `reversible_compile(f, NTuple{2,Int8})` dispatches here with
    # arg_types = Tuple{Int8,Int8} (the 2-arg interpretation). If the
    # user's function actually takes a single NTuple-typed argument,
    # there's no method match and code_llvm later throws an opaque
    # "no unique matching method" error. Detect both cases up-front
    # and emit an actionable error pointing at the wrap fix.
    if !hasmethod(f, arg_types)
        wrapped = Tuple{arg_types}
        if hasmethod(f, wrapped)
            throw(ArgumentError(
                "reversible_compile: $f has no method for arg_types=$arg_types " *
                "(interpreted as $(length(arg_types.parameters)) separate args), " *
                "but does match $wrapped (a single tuple-typed arg). " *
                "If your function takes a single NTuple/Tuple argument, " *
                "wrap arg_types as `Tuple{$arg_types}`. " *
                "(Bennett-4bcp / U102: NTuple-as-arg-type ambiguity.)"))
        else
            throw(ArgumentError(
                "reversible_compile: $f has no method for arg_types=$arg_types. " *
                "Check the function signature matches the requested types."))
        end
    end

    strategy in (:auto, :tabulate, :expression) ||
        throw(ArgumentError("reversible_compile: unknown strategy :$strategy; " *
              "supported: :auto, :tabulate, :expression"))

    # Explicit tabulate: evaluate f classically on all 2^W inputs and emit as
    # a QROM lookup. Skip IR extraction entirely.
    if strategy === :tabulate
        ok, reason = _tabulate_applicable(arg_types, bit_width)
        ok || throw(ArgumentError(
            "reversible_compile: strategy=:tabulate not applicable — $reason"))
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    # Expression path (also base for :auto). Extract IR once; the cost model
    # inspects it to decide whether to redirect to tabulate.
    parsed = extract_parsed_ir(f, arg_types; optimize)

    if strategy === :auto && _tabulate_auto_picks(parsed, arg_types, bit_width)
        widths = _tabulate_input_widths(arg_types, bit_width)
        out_width = bit_width > 0 ? bit_width : sizeof(arg_types.parameters[1]) * 8
        lr = lower_tabulate(f, arg_types, widths; out_width)
        return bennett(lr)
    end

    if bit_width > 0
        parsed = _narrow_ir(parsed, bit_width)
    end
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               fold_constants, target)
    return bennett(lr)
end

const _PARSED_OVERLOAD_KWARGS = (:max_loop_iterations, :compact_calls,
                                :add, :mul, :fold_constants, :target)
# Kwargs that only make sense on the Julia-function entry path (they
# configure IR extraction or pre-extraction narrowing); rejected
# loudly if sent to the ParsedIR overload.
const _PARSED_OVERLOAD_CROSS_REJECT = (:optimize, :bit_width, :strategy)

"""
    reversible_compile(parsed::ParsedIR; max_loop_iterations=0,
                       compact_calls=false, add=:auto, mul=:auto,
                       fold_constants=true) -> ReversibleCircuit

Compile a pre-extracted `ParsedIR` (e.g. from
`extract_parsed_ir_from_ll` or `extract_parsed_ir_from_bc`) into a reversible
circuit. This path skips IR extraction and the `strategy=:tabulate` /
`bit_width` pre-processing that only apply to Julia-function inputs;
passing `optimize`, `bit_width`, or `strategy` here raises `ArgumentError`.
"""
function reversible_compile(parsed::ParsedIR;
                            max_loop_iterations::Int=_DEFAULT_COMPILE_OPTIONS.max_loop_iterations,
                            compact_calls::Bool=_DEFAULT_COMPILE_OPTIONS.compact_calls,
                            add::Symbol=_DEFAULT_COMPILE_OPTIONS.add,
                            mul::Symbol=_DEFAULT_COMPILE_OPTIONS.mul,
                            fold_constants::Bool=_DEFAULT_COMPILE_OPTIONS.fold_constants,
                            target::Symbol=_DEFAULT_COMPILE_OPTIONS.target,
                            kwargs...)
    _reject_unknown_kwargs("ParsedIR overload", _PARSED_OVERLOAD_KWARGS,
                           _PARSED_OVERLOAD_CROSS_REJECT, kwargs)
    lr = lower(parsed; max_loop_iterations, compact_calls, add, mul,
               fold_constants, target)
    return bennett(lr)
end

# ---- CompileOptions overloads (Bennett-u71l / U161) ----
#
# Thin wrappers that unpack a `CompileOptions` bundle into the kwarg form.
# Per-overload applicability is enforced by raising on non-default values
# of fields that aren't accepted on this path (mirrors the kwarg-side
# `_reject_unknown_kwargs` cross-rejection — same error class, same UX).

@inline function _check_field_at_default(overload::String, opts::CompileOptions,
                                          field::Symbol)
    actual  = getfield(opts, field)
    default = getfield(_DEFAULT_COMPILE_OPTIONS, field)
    actual == default || throw(ArgumentError(
        "reversible_compile ($overload): CompileOptions.$field=$(actual) " *
        "is not supported on this overload — leave it at the default " *
        "($(default))."))
    return nothing
end

"""
    reversible_compile(f, arg_types::Type{<:Tuple}, opts::CompileOptions)
    reversible_compile(parsed::ParsedIR,            opts::CompileOptions)
    reversible_compile(f, ::Type{Float64}, ts::Type{Float64}..., opts::CompileOptions)

`CompileOptions`-bundle overloads of `reversible_compile`. Equivalent to
the kwarg form with each field of `opts` forwarded as a kwarg of the
same name. Per-overload applicability is enforced (e.g. setting
`opts.bit_width` on the ParsedIR or Float64 overload raises
`ArgumentError`).
"""
function reversible_compile(f, arg_types::Type{<:Tuple}, opts::CompileOptions)
    return reversible_compile(f, arg_types;
        optimize            = opts.optimize,
        max_loop_iterations = opts.max_loop_iterations,
        compact_calls       = opts.compact_calls,
        bit_width           = opts.bit_width,
        add                 = opts.add,
        mul                 = opts.mul,
        strategy            = opts.strategy,
        fold_constants      = opts.fold_constants,
        target              = opts.target,
    )
end

function reversible_compile(parsed::ParsedIR, opts::CompileOptions)
    _check_field_at_default("ParsedIR overload", opts, :optimize)
    _check_field_at_default("ParsedIR overload", opts, :bit_width)
    _check_field_at_default("ParsedIR overload", opts, :strategy)
    return reversible_compile(parsed;
        max_loop_iterations = opts.max_loop_iterations,
        compact_calls       = opts.compact_calls,
        add                 = opts.add,
        mul                 = opts.mul,
        fold_constants      = opts.fold_constants,
        target              = opts.target,
    )
end

# ---- Per-task implementations (Bennett-19g6 / U91 modular layout) ----
include("narrow.jl")               # _narrow_ir + _narrow_inst per IR node type
include("callees.jl")              # _CALLEES_* groups + register_callee! loop
include("softfloat_dispatch.jl")   # SoftFloat struct + Float64 reversible_compile
include("precompile.jl")           # PrecompileTools.@compile_workload

end # module
