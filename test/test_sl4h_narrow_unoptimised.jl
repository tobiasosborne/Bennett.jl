# Bennett-sl4h: with `bit_width=W` and `optimize=true` (the default), the
# UNOPTIMISED IR is narrowed first; only if extraction or the narrowing
# allowlist refuses it is the optimised IR narrowed (the pre-sl4h path, with
# its Bennett-koi8 folded-comparison checks).
#
# LLVM's folds are only valid at the source width: `x * 16 == 0` on Int8 folds
# to `(x & 15) == 0`, true iff 16 | x — but in 6-bit modular arithmetic
# x * 16 == 0 iff 4 | x.  Every operand and constant of the folded IR is
# narrowable, so narrowing that IR accepted a wrong circuit.  The unoptimised IR
# holds the source's own multiply, which narrows correctly.
#
# INVARIANTS, over a generated corpus x T in {Int8, UInt8} x W in {2,3,4,6,7,8}:
#   (1) where the unoptimised narrowing is accepted, optimize=true uses it: the
#       same ParsedIR (one cache entry) and the same gate list as optimize=false;
#   (2) monotonicity: every cell the pre-sl4h path (optimised IR through
#       `_narrow_ir(...; optimized=true)`) accepted is still accepted;
#   (3) an accepted circuit is right on all 2^W input patterns and passes
#       verify_reversibility;
#   (4) a refusal is the narrowing ArgumentError (Bennett-mrhg).
# NOT FIXED (pinned @test_broken below): a program whose unoptimised IR is
# refused AND whose optimised IR holds a fold that uses an S-bit arithmetic fact.
#
# THE ORACLE (independent of src/) interprets the source expression in W-bit
# modular arithmetic: x is the W-bit input read in T's signedness, every
# arithmetic result wraps mod 2^W (renormalised to T's signedness), and a
# comparison compares those values against the literal the source wrote.

using Test
using Bennett

sl4h_wmask(W) = (1 << W) - 1
sl4h_wsign(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
sl4h_norm(::Type{Int8}, v, W)  = sl4h_wsign(mod(v, 1 << W), W)
sl4h_norm(::Type{UInt8}, v, W) = mod(v, 1 << W)
sl4h_in(::Type{Int8}, p)  = reinterpret(Int8, UInt8(p & 0xff))
sl4h_in(::Type{UInt8}, p) = UInt8(p & 0xff)

const SL4H_CMP = (:<, :<=, :>, :>=, :(==), :!=)
const SL4H_ARITH = (:+, :-, :*, :&, :|, :⊻, :<<)

"Evaluate source expression `ex` on the W-bit value `v` (already normalised)."
function sl4h_eval(ex, v, T, W)
    ex === :x && return v
    ex isa Integer && return Int(ex)
    ex isa Expr && ex.head === :call || error("sl4h_eval: unexpected $ex")
    op = ex.args[1]
    if op === :ifelse
        return sl4h_eval(ex.args[2], v, T, W) ? sl4h_eval(ex.args[3], v, T, W) :
                                                sl4h_eval(ex.args[4], v, T, W)
    end
    a = sl4h_eval(ex.args[2], v, T, W)
    b = sl4h_eval(ex.args[3], v, T, W)
    a isa Bool && b isa Bool && op in (:&, :|) && return op === :& ? a & b : a | b
    op in SL4H_CMP && return getfield(Base, op)(a, b)
    op in SL4H_ARITH && return sl4h_norm(T, getfield(Base, op)(a, b), W)
    # `>>` is arithmetic for Int8 (on the signed value), logical for UInt8 (the
    # value is already non-negative); `>>>` is logical on the W-bit pattern
    op === :>> && return sl4h_norm(T, a >> b, W)
    op === :>>> && return sl4h_norm(T, mod(a, 1 << W) >>> b, W)
    error("sl4h_eval: unexpected operator $op")
end

const SL4H_WS = (2, 3, 4, 6, 7, 8)
const SL4H_CASES = Tuple{DataType,String,Any,Function}[]
let n = 0
    for T in (Int8, UInt8)
        t(c) = c % T
        preds = Any[:($op(x, $(t(c)))) for op in SL4H_CMP
                    for c in (0, 1, 3, 16, 100, -1, typemax(T))]
        append!(preds, Any[
            :(x * $(t(16)) == $(t(0))),          # folds to (x & 15) == 0
            :(x * $(t(4)) == $(t(0))),           # folds to (x & 63) == 0
            :(x * $(t(4)) < $(t(3))),
            :((x + $(t(3))) < $(t(2))),
            :((x & $(t(15))) == $(t(0))),
            :((x >> 1) == $(t(0))),
            :((x << 2) != $(t(0))),
            :(x < $(t(0))),                      # Int8: sign test -> lshr 7
            :((x < $(t(2))) | (x >= $(t(128)))), # UInt8: folds to slt x, 2
            :((x >= $(t(248))) & (x <= $(t(248)))),
            :((x >= $(t(9))) & (x <= $(t(12)))), # folds to ult (x - 9), 4
            :((x > $(t(1))) & (x < $(t(6)))),
        ])
        vals = Any[:(x * $(t(16))), :(x * $(t(4))), :(x * x), :(x + $(t(1))),
                   :(x - $(t(5))), :(x << 1), :(x << 3), :(x >> 1), :(x >>> 2),
                   :(x & $(t(15))), :(x | $(t(3))), :(x ⊻ $(t(0x5a))),
                   :(ifelse(x < $(t(3)), x * $(t(3)), x + $(t(1))))]
        for body in preds
            fname = Symbol("sl4h_p_", n += 1)
            f = @eval $fname(x::$T) = ifelse($body, $(T(1)), $(T(0)))
            push!(SL4H_CASES, (T, string(body), :(ifelse($body, 1, 0)), f))
        end
        for body in vals
            fname = Symbol("sl4h_v_", n += 1)
            f = @eval $fname(x::$T) = $body
            push!(SL4H_CASES, (T, string(body), body, f))
        end
    end
end

function sl4h_compile(f, T, W, optimize)
    try
        return reversible_compile(f, T; bit_width=W, optimize,
                                  strategy=:expression), nothing
    catch e
        e isa ArgumentError || rethrow()
        return nothing, e
    end
end
sl4h_is_refusal(e) = e isa ArgumentError && occursin("refusing to narrow", e.msg) &&
                     occursin("Bennett-mrhg", e.msg)

"W-bit patterns on which circuit `c` disagrees with the W-bit oracle."
function sl4h_mismatches(c, ex, T, W)
    bad = Int[]
    for p in 0:sl4h_wmask(W)
        want = mod(Int(sl4h_eval(ex, sl4h_norm(T, p, W), T, W)), 1 << W)
        got = Int(simulate(c, T, sl4h_in(T, p))) & sl4h_wmask(W)
        got == want || push!(bad, p)
    end
    return bad
end

sl4h_mul16(x::Int8) = ifelse(x * Int8(16) == Int8(0), Int8(1), Int8(0))

# pre-sl4h path: the optimised IR through the koi8-checked narrowing
function sl4h_old_accepts(f, T, W)
    try
        Bennett._narrow_ir(Bennett.extract_parsed_ir(f, Tuple{T}; optimize=true), W;
                           optimized=true)
        return true
    catch e
        e isa ArgumentError || rethrow()
        return false
    end
end
"The narrowed ParsedIR the unoptimised attempt yields, or `nothing` if refused."
function sl4h_unopt_pir(f, T, W)
    try
        return Bennett._extract_parsed_ir_cached(f, Tuple{T}; optimize=false, bit_width=W)
    catch e
        e isa ArgumentError || rethrow()
        return nothing
    end
end
sl4h_wz(W, a) = mod(a, 1 << W) == 0
"Number of W-bit patterns on which `c` disagrees with `oracle(v)` (v: the W-bit value as a T)."
sl4h_nbad(c, T, W, oracle) =
    count(p -> (Int(simulate(c, T, sl4h_in(T, p))) & sl4h_wmask(W)) !=
               mod(Int(oracle(sl4h_norm(T, p, W))), 1 << W), 0:sl4h_wmask(W))

# the ordinary spellings whose unoptimised IR the allowlist refuses (Julia's
# promotion to i64, the `ashr x, 7` overshift arm); they must keep compiling
sl4h_eq5(x::Int8)    = x == 5
sl4h_even(x::Int8)   = iseven(x)
sl4h_gt2(x::UInt8)   = x > 2
sl4h_ieq5(x::Int8)   = Int8(x == 5 ? 1 : 0)
sl4h_ashr1(x::Int8)  = x >> 1
const SL4H_IDIOMS = (
    ("x == 5",               sl4h_eq5,  Int8,  v -> v == 5),
    ("iseven(x)",            sl4h_even, Int8,  v -> iseven(v)),
    ("UInt8 x > 2",          sl4h_gt2,  UInt8, v -> v > 2),
    ("Int8(x == 5 ? 1 : 0)", sl4h_ieq5, Int8,  v -> v == 5 ? 1 : 0),
    ("Int8 x >> 1",          sl4h_ashr1, Int8, v -> v >> 1),
)

# residual hole: `x == 5` (untyped literal) makes the unoptimised IR refused,
# so the fallback narrows the optimised IR, where `x * 16 == 0` is `(x & 15) == 0`
sl4h_hole(x::Int8) = ifelse((x == 5) | (x * Int8(16) == Int8(0)), Int8(1), Int8(0))

@testset "Bennett-sl4h — bit_width narrows the unoptimised IR first" begin

@testset "witness: x * 16 == 0 at bit_width=6" begin
    oracle(v) = sl4h_wz(6, 16v) ? 1 : 0
    for optimize in (false, true)
        c, err = sl4h_compile(sl4h_mul16, Int8, 6, optimize)
        @test err === nothing
        @test c !== nothing && verify_reversibility(c)
        @test c !== nothing && sl4h_nbad(c, Int8, 6, oracle) == 0
    end
    # the cell the optimised IR got wrong: x = 4 (4 * 16 = 64 == 0 mod 64)
    c, _ = sl4h_compile(sl4h_mul16, Int8, 6, true)
    @test c !== nothing && Int(simulate(c, Int8, Int8(4))) == 1
end

@testset "parsed-IR cache: shared entry on success, nothing cached on refusal" begin
    Bennett._clear_parsed_ir_cache!()
    # unoptimised attempt accepted: both flags give the very same ParsedIR,
    # which holds the source's multiply, not the optimiser's mask
    p1 = Bennett._extract_parsed_ir_cached(sl4h_mul16, Tuple{Int8};
                                           optimize=true, bit_width=6)
    p0 = Bennett._extract_parsed_ir_cached(sl4h_mul16, Tuple{Int8};
                                           optimize=false, bit_width=6)
    @test p0 === p1
    @test any(i -> i isa Bennett.IRBinOp && i.op === :mul,
              (i for b in p1.blocks for i in b.instructions))
    # unoptimised attempt refused (`x == 5` promotes to i64): the fallback
    # result is cached under the optimize=true key only, and the refused
    # optimize=false attempt left no entry behind
    Bennett._clear_parsed_ir_cache!()
    q1 = Bennett._extract_parsed_ir_cached(sl4h_eq5, Tuple{Int8};
                                           optimize=true, bit_width=6)
    @test haskey(Bennett._parsed_ir_cache, (sl4h_eq5, Tuple{Int8}, true, :auto, 6))
    @test !haskey(Bennett._parsed_ir_cache, (sl4h_eq5, Tuple{Int8}, false, :auto, 6))
    @test q1 === Bennett._extract_parsed_ir_cached(sl4h_eq5, Tuple{Int8};
                                                   optimize=true, bit_width=6)
    @test_throws ArgumentError Bennett._extract_parsed_ir_cached(sl4h_eq5, Tuple{Int8};
                                                   optimize=false, bit_width=6)
    # W == S re-types nothing: the optimised path, as before sl4h
    for f in (sl4h_mul16, sl4h_eq5)
        c8 = reversible_compile(f, Int8; bit_width=8, strategy=:expression)
        cold = reversible_compile(Bennett._narrow_ir(Bennett.extract_parsed_ir(
                   f, Tuple{Int8}; optimize=true), 8; optimized=true))
        @test c8.gates == cold.gates
    end
end

@testset "fallback trigger: refusals fall back, bugs propagate" begin
    @test Bennett._narrow_attempt_refused(ArgumentError("refusing to narrow"))
    @test Bennett._narrow_attempt_refused(ErrorException("ir_extract.jl: ... unsupported"))
    for e in (InterruptException(), MethodError(+, (1, "a")), BoundsError([1], 2),
              KeyError(:k), AssertionError("x"), UndefVarError(:y))
        @test !Bennett._narrow_attempt_refused(e)
    end
end

@testset "ordinary idioms still compile at optimize=true, right on all 2^W" begin
    for (desc, f, T, oracle) in SL4H_IDIOMS, W in (4, 6, 7)
        c, err = sl4h_compile(f, T, W, true)
        @test err === nothing
        err === nothing || (@info "sl4h idiom refused" desc W; continue)
        @test verify_reversibility(c)
        @test sl4h_nbad(c, T, W, oracle) == 0
    end
end

@testset "generated corpus: $(length(SL4H_CASES)) programs x W x optimize" begin
    n_acc = 0; n_unopt = 0; n_ref = 0
    differ = String[]; lost = String[]; wrong = String[]; unclean = String[]
    bad_err = String[]
    for (T, desc, ex, f) in SL4H_CASES, W in SL4H_WS
        cell = "$T $desc @W=$W"
        c0, e0 = sl4h_compile(f, T, W, false)
        c1, e1 = sl4h_compile(f, T, W, true)
        for e in (e0, e1)
            e === nothing || sl4h_is_refusal(e) ||
                push!(bad_err, "$cell: $(sprint(showerror, e))")
        end
        # (2) monotonicity against the pre-sl4h path
        e1 !== nothing && sl4h_old_accepts(f, T, W) && push!(lost, cell)
        # (1) the unoptimised narrowing is accepted => optimize=true builds the
        # same circuit.  (Gates, not ParsedIR identity: this corpus overflows
        # the bounded parsed-IR cache, so an entry can be evicted and rebuilt
        # between the two compiles; identity is checked in the cache testset.)
        if e0 === nothing && W != 8
            n_unopt += 1
            (e1 === nothing && c0.gates == c1.gates &&
             c0.input_widths == c1.input_widths && c0.output_wires == c1.output_wires) ||
                push!(differ, cell)
        end
        if e1 !== nothing
            n_ref += 1
            continue
        end
        n_acc += 1
        verify_reversibility(c1) || push!(unclean, cell)
        bad = sl4h_mismatches(c1, ex, T, W)
        isempty(bad) || push!(wrong, "$cell wrong at patterns $(first(bad, 6))")
    end
    println("  sl4h corpus: $(length(SL4H_CASES)) programs, $(n_acc + n_ref) cells at ",
            "optimize=true: $n_acc accepted ($n_unopt via the unoptimised IR at W < 8), ",
            "$n_ref refused; $(length(wrong)) accepted-and-wrong")
    foreach(m -> println("    WRONG ", m), first(wrong, 20))
    foreach(m -> println("    DIFFER ", m), first(differ, 10))
    foreach(m -> println("    LOST ", m), first(lost, 10))
    foreach(m -> println("    BAD ERR ", m), first(bad_err, 5))
    @test isempty(differ)    # (1) unoptimised accepted => optimize=true is that circuit
    @test isempty(lost)      # (2) nothing the pre-sl4h path accepted is refused
    @test isempty(wrong)     # (3) accepted => right on every W-bit input
    @test isempty(unclean)   # (3) ... and every ancilla returns to zero
    @test isempty(bad_err)   # (4) a refusal is the narrowing ArgumentError
    @test n_acc >= 400       # non-vacuity
    @test n_unopt >= 300
end

@testset "residual hole (Bennett-sl4h, still open): fallback + S-bit fold" begin
    # `(x == 5) | (x * 16 == 0)` at W = 6.  The untyped literal 5 makes the
    # unoptimised IR compare an i64 sext of x — refused — so optimize=true
    # falls back to the optimised IR, where `x * 16 == 0` is `(x & 15) == 0`
    # (16 | x, an 8-bit fact) and passes every local check.  The W-bit
    # meaning is 4 | x, so the circuit is wrong at x = 4, 8, 12, ... .
    oracle(v) = ((v == 5) | sl4h_wz(6, 16v)) ? 1 : 0
    @test sl4h_unopt_pir(sl4h_hole, Int8, 6) === nothing   # precondition: fallback
    c, err = sl4h_compile(sl4h_hole, Int8, 6, true)
    @test err === nothing                                  # measured: accepted
    @test c !== nothing && verify_reversibility(c)
    nbad = c === nothing ? -1 : sl4h_nbad(c, Int8, 6, oracle)
    # Bennett-sl4h: the accepted circuit is WRONG (12 of 64 patterns, measured
    # 2026-10-04); closing needs the unoptimised IR of `x == 5` to narrow
    # (allowlist work in the bead NOTES) so the fallback can be dropped.
    @test_broken nbad == 0
    # optimize=false refuses it outright (sound)
    @test sl4h_compile(sl4h_hole, Int8, 6, false)[2] !== nothing
end

end # @testset Bennett-sl4h
