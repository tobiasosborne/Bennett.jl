# Bennett-5y48 (differential) / Bennett-sl4h: `bit_width = W` with
# `optimize = true` narrows BOTH the unoptimised and the optimised LLVM IR and,
# when both are accepted, compiles both and compares the two circuits.
#
# Neither reading is sound on its own.  The optimised IR holds folds valid only
# at the source width S (`x * Int8(16) == 0` is `(x & 15) == 0`); the
# unoptimised IR holds Julia library code written for S bits, re-typed
# literally (`bitreverse(x) == 0` keeps Julia's S-bit masks, while LLVM folds
# the idiom to `x == 0`).  Each class is invisible in the other's IR, so a
# disagreement between the two narrowed circuits is the signal: the compile is
# then REFUSED rather than handing back either reading.

"""
    _narrow_candidates(f, arg_types, mem, W) -> ParsedIR or (U, O)

The two `W`-bit narrowings of `f` for `bit_width = W, optimize = true`:
`U` from the unoptimised IR (`_narrow_unoptimised`, the `optimize=false`
cache entry), `O` from the optimised IR (`_narrow_ir(...; optimized=true)`, the
`optimize=true` cache entry).  Returns

  - the optimised narrowing alone when `W` is the source width (nothing is
    re-typed, the folds are valid — no cross-check, no gate-count cost);
  - the one accepted narrowing when the other is refused — LIMITATION: this
    keeps the single-path holes (a fold the optimised IR alone could see, or
    an idiom only the unoptimised IR holds, is not cross-checked when the
    other reading is refused);
  - the pair `(U, O)` when both are accepted — the caller compiles both and
    compares them (`_narrow_differential_compile`).

When both are refused it throws, reporting the unoptimised refusal first and
the optimised one after it (an `ArgumentError` when either is one).
A refusal is an exception `_narrow_attempt_refused` accepts; anything else
propagates.
"""
function _narrow_candidates(f, arg_types::Type{<:Tuple}, mem::Symbol, W::Int)
    S = try
        _narrow_source_width(_extract_parsed_ir_cached(f, arg_types; optimize=false, mem))
    catch e
        e isa InterruptException && rethrow()
        _narrow_attempt_refused(e) || rethrow()
        e
    end
    S == W && return _extract_parsed_ir_cached(f, arg_types; optimize=true, mem, bit_width=W)
    U = S isa Exception ? S : _narrow_try(() ->
        _extract_parsed_ir_cached(f, arg_types; optimize=false, mem, bit_width=W))
    O = _narrow_try(() ->
        _extract_parsed_ir_cached(f, arg_types; optimize=true, mem, bit_width=W))
    U isa ParsedIR && O isa ParsedIR && return (U, O)
    U isa ParsedIR && return U
    O isa ParsedIR && return O
    msg = "$(_narrow_exc_msg(U))\n[Bennett-5y48 / Bennett-sl4h: the narrowing of " *
          "the OPTIMISED IR to $W bits was refused too: $(_narrow_exc_msg(O))]"
    throw((U isa ArgumentError || O isa ArgumentError) ? ArgumentError(msg) :
          ErrorException(msg))
end

function _narrow_try(thunk)
    try
        return thunk()
    catch e
        e isa InterruptException && rethrow()
        _narrow_attempt_refused(e) || rethrow()
        return e
    end
end

_narrow_exc_msg(e) = hasfield(typeof(e), :msg) ? string(e.msg) : sprint(showerror, e)

"""
    _narrow_differential_compile(U, O, W, opts) -> circuit (or VM program)

Compile both narrowings with the caller's lowering options `opts` (through the
ParsedIR overload, so the compile cache holds each circuit) and compare them.
They agree → the result is `U`'s compile.  They disagree on some input → an
`ArgumentError` naming Bennett-5y48 / Bennett-sl4h and the first differing
input with both outputs.  If lowering `O` is refused (`_narrow_attempt_refused`)
`U`'s circuit is used unchecked, as when `O`'s narrowing is refused; a refusal
lowering `U` propagates (as before the cross-check).

The comparison domain is every input when the narrowed inputs total at most
16 bits — agreement is then PROVED; above 16 bits it is a fixed deterministic
sample (corners, single-bit patterns, per-argument extremes and a seeded
pseudo-random set) — agreement is SAMPLED, not proved.  An input on which one
circuit fails (loop guard not converged, ancilla dirty, input changed) and
the other does not is a disagreement.  `target = :reversible_vm` compares the
default-target circuits and then returns `U`'s VM program.  The verdict is
cached per circuit pair (`_narrow_verdict_cache`), world-gated like the other
caches, so a repeated identical compile does not redo the comparison.
"""
function _narrow_differential_compile(U::ParsedIR, O::ParsedIR, W::Int, opts::NamedTuple)
    vm = opts.target === :reversible_vm
    copts = vm ? merge(opts, (; target=_DEFAULT_COMPILE_OPTIONS.target)) : opts
    cU = reversible_compile(U; copts...)
    cO = try
        reversible_compile(O; copts...)
    catch e
        e isa InterruptException && rethrow()
        _narrow_attempt_refused(e) || rethrow()
        nothing
    end
    if cO !== nothing
        why = _narrow_verdict(cU, cO, W)
        why === nothing || throw(ArgumentError(why))
    end
    return vm ? reversible_compile(U; opts...) : cU
end

const _narrow_verdict_cache = IdDict{Tuple{ReversibleCircuit, ReversibleCircuit},
                                     Union{Nothing, String}}()
const _narrow_verdict_cache_lock = ReentrantLock()
const _narrow_verdict_cache_world = Ref{Tuple{UInt, UInt}}((0, 0))
const _NARROW_VERDICT_CACHE_MAX = 32

"""`nothing` when `cU` and `cO` agree on the comparison domain, else the
refusal message; memoised on the circuit pair's identity."""
function _narrow_verdict(cU::ReversibleCircuit, cO::ReversibleCircuit, W::Int)
    key = (cU, cO)
    lock(_narrow_verdict_cache_lock) do
        w = _cache_world_gate!(_narrow_verdict_cache, _narrow_verdict_cache_world)
        haskey(_narrow_verdict_cache, key) && return _narrow_verdict_cache[key]
        v = _narrow_disagreement(cU, cO, W)
        return _cache_insert_bounded!(_narrow_verdict_cache, key, v,
                                      _NARROW_VERDICT_CACHE_MAX, w)
    end
end

const _NARROW_EXHAUSTIVE_BITS = 16
const _NARROW_SAMPLE_SIZE = 4096

"""Comparison inputs as a `nargs × N` matrix of per-argument bit patterns:
all `2^n` inputs when `n = sum(widths) <= 16`, else the deterministic sample."""
function _narrow_compare_inputs(widths::Vector{Int})
    k = length(widths)
    n = sum(widths; init=0)
    masks = UInt64[w >= 64 ? typemax(UInt64) : (UInt64(1) << w) - 1 for w in widths]
    if n <= _NARROW_EXHAUSTIVE_BITS
        M = Matrix{UInt64}(undef, k, 1 << n)
        for p in 0:(1 << n) - 1
            off = 0
            for j in 1:k
                M[j, p + 1] = (UInt64(p) >> off) & masks[j]
                off += widths[j]
            end
        end
        return M, true
    end
    cols = Vector{Vector{UInt64}}()
    zeros_ = zeros(UInt64, k); ones_ = copy(masks)
    push!(cols, zeros_, ones_)
    for j in 1:k, b in 0:widths[j] - 1          # single-bit set / single-bit clear
        v = copy(zeros_); v[j] = UInt64(1) << b; push!(cols, v)
        v = copy(ones_);  v[j] = masks[j] & ~(UInt64(1) << b); push!(cols, v)
    end
    for j in 1:k, base in (zeros_, ones_)       # per-argument extremes
        w = widths[j]
        for x in (UInt64(0), masks[j], UInt64(1), UInt64(1) << (w - 1),
                  masks[j] >> 1, masks[j] - 1)
            v = copy(base); v[j] = x & masks[j]; push!(cols, v)
        end
    end
    s = UInt64(0x5948)                          # splitmix64, fixed seed
    while length(cols) < _NARROW_SAMPLE_SIZE
        v = Vector{UInt64}(undef, k)
        for j in 1:k
            s += 0x9E3779B97F4A7C15
            z = s
            z = (z ⊻ (z >> 30)) * 0xBF58476D1CE4E5B9
            z = (z ⊻ (z >> 27)) * 0x94D049BB133111EB
            v[j] = (z ⊻ (z >> 31)) & masks[j]
        end
        push!(cols, v)
    end
    return reduce(hcat, cols), false
end

"""The gate stream as `(kind, a, b, target)` rows: 1 NOT, 2 CNOT, 3 Toffoli."""
function _narrow_gate_table(c::ReversibleCircuit)
    tab = Vector{NTuple{4, Int}}(undef, length(c.gates))
    for (i, g) in enumerate(c.gates)
        tab[i] = g isa NOTGate     ? (1, 0, 0, g.target) :
                 g isa CNOTGate    ? (2, g.control, 0, g.target) :
                 g isa ToffoliGate ? (3, g.control1, g.control2, g.target) :
                 error("_narrow_gate_table: unknown gate type $(typeof(g))")
    end
    return tab
end

"""Run 64 inputs (columns `cols` of `M`) bit-sliced through `c`; returns the
fail mask (loop guard 0, ancilla 1, or input changed) per lane."""
function _narrow_run_lanes!(buf::Vector{UInt64}, c::ReversibleCircuit, tab,
                            M::Matrix{UInt64}, cols::UnitRange{Int})
    fill!(buf, UInt64(0))
    off = 0
    for (j, w) in enumerate(c.input_widths)
        for b in 0:w - 1
            word = UInt64(0)
            for (lane, col) in enumerate(cols)
                word |= ((M[j, col] >> b) & 1) << (lane - 1)
            end
            buf[c.input_wires[off + b + 1]] = word
        end
        off += w
    end
    orig = buf[c.input_wires]
    for (k, a, b, t) in tab
        if k == 1
            buf[t] = ~buf[t]
        elseif k == 2
            buf[t] ⊻= buf[a]
        else
            buf[t] ⊻= buf[a] & buf[b]
        end
    end
    fail = UInt64(0)
    for lg in c.loop_check_wires
        fail |= ~buf[lg.wire]
    end
    for w in c.ancilla_wires
        fail |= buf[w]
    end
    for (i, w) in enumerate(c.input_wires)
        fail |= buf[w] ⊻ orig[i]
    end
    return fail
end

function _narrow_lane_output(buf, c::ReversibleCircuit, lane::Int)
    vals = UInt64[]
    off = 0
    for w in c.output_elem_widths
        v = UInt64(0)
        for b in 0:w - 1
            v |= ((buf[c.output_wires[off + b + 1]] >> (lane - 1)) & 1) << b
        end
        push!(vals, v)
        off += w
    end
    return vals
end

_narrow_fmt_patterns(vals) = "(" * join(("0x" * string(v; base=16) for v in vals), ", ") *
                             (length(vals) == 1 ? ",)" : ")")

"""`nothing` if the two circuits agree on every compared input, else the
refusal message naming the first differing input."""
function _narrow_disagreement(cU::ReversibleCircuit, cO::ReversibleCircuit, W::Int)
    head = "reversible_compile(...; bit_width=$W): refusing to narrow — the " *
           "optimised and the unoptimised LLVM IR of this function narrow to " *
           "different $W-bit functions (Bennett-5y48 / Bennett-sl4h; bit-width " *
           "narrowing, Bennett-mrhg): one reading " *
           "holds an operation valid only at the source width (an LLVM fold, or " *
           "Julia library code written for the source width)"
    if cU.input_widths != cO.input_widths || cU.output_elem_widths != cO.output_elem_widths
        return head * "; the two circuits do not even share a layout (input widths " *
               "$(cU.input_widths) vs $(cO.input_widths), output widths " *
               "$(cU.output_elem_widths) vs $(cO.output_elem_widths))"
    end
    M, exhaustive = _narrow_compare_inputs(cU.input_widths)
    N = size(M, 2)
    tU, tO = _narrow_gate_table(cU), _narrow_gate_table(cO)
    bU, bO = zeros(UInt64, cU.n_wires), zeros(UInt64, cO.n_wires)
    for start in 1:64:N
        cols = start:min(start + 63, N)
        lanes = length(cols)
        live = lanes == 64 ? typemax(UInt64) : (UInt64(1) << lanes) - 1
        fU = _narrow_run_lanes!(bU, cU, tU, M, cols) & live
        fO = _narrow_run_lanes!(bO, cO, tO, M, cols) & live
        od = UInt64(0)
        for (wu, wo) in zip(cU.output_wires, cO.output_wires)
            od |= bU[wu] ⊻ bO[wo]
        end
        diff = ((fU ⊻ fO) | (~(fU | fO) & od)) & live
        diff == 0 && continue
        lane = trailing_zeros(diff) + 1
        show_out(b, c, f) = (f >> (lane - 1)) & 1 == 1 ?
            "fails (loop guard / ancilla / input check)" :
            _narrow_fmt_patterns(_narrow_lane_output(b, c, lane))
        input = _narrow_fmt_patterns(M[:, cols[lane]])
        return head * ". First differing input (argument bit patterns, $W-bit): " *
               "$input — the unoptimised-IR circuit gives $(show_out(bU, cU, fU)), " *
               "the optimised-IR circuit gives $(show_out(bO, cO, fO)) (output bit " *
               "patterns). Compared $(exhaustive ? "all $N inputs" :
               "a sample of $N inputs") before refusing."
    end
    return nothing
end
