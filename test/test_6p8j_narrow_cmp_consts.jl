# Bennett-6p8j: comparison constants under `bit_width=W` narrowing.
#
# `_narrow_cmp_consts` gave every predicate outside the signed-ordering list
# the bounds 0..2^W-1 — including eq/ne — while LLVM hands constants over
# sign-extended, so `x == Int8(-1)` was refused ("constant -1 does not fit")
# even at bit_width=8, where nothing is re-typed.  The fix reads the constant
# at the comparison's own width: an un-re-typed comparison keeps any constant;
# a re-typed one needs a constant whose meaning does not depend on facts the
# IR has lost (the IR cannot tell `Int8(-1)` from `0xff`, nor `x >= 0xff`
# from `x == 0xff`).
#
# THE ORACLE (independent of src/), the W-bit modular semantics:
#   * eq/ne is congruence mod 2^W: `x == C` holds iff the W-bit pattern of x
#     is C mod 2^W (exactly as `x + C` wraps C);
#   * an ORDERING reads the input as a W-bit number — signed for an Int8
#     argument, unsigned for a UInt8 one — and the literal as the NUMBER the
#     source wrote (`x < 10` is always true for a 4-bit signed x).  Wrapping
#     an ordering literal is the inverted-test bug of Bennett-mrhg.
# Every accepted circuit must give exactly that answer on every input, or the
# compile must be refused with the Bennett-mrhg ArgumentError (the narrowing
# contract of test_mrhg_narrow_soundness.jl).
#
# Bennett-koi8 tightened the rule: at W < 8 an eq/ne constant must lie in
# 0..2^(W-1)-1, where the pattern reading above and the number reading
# (`x == 5` never holds for a 3-bit signed x) coincide, and optimised IR may
# not carry a signed ordering or compare a computed value.  The two optimizer
# folds this file pinned as known holes are now refused.  The generated
# corpus in test_koi8_narrow_folded_cmp.jl is the main soundness check.

using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRICmp, IRCast, IRSelect, IRRet,
                ssa, iconst

p6_wmask(W) = (1 << W) - 1
p6_wsign(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
p6_in(::Type{Int8}, p)  = reinterpret(Int8, UInt8(p & 0xff))
p6_in(::Type{UInt8}, p) = UInt8(p & 0xff)
p6_num(::Type{Int8}, p, W)  = p6_wsign(p, W)   # the W-bit input as a number
p6_num(::Type{UInt8}, p, W) = p

"Boundary constants for width W, as numbers of the source type."
function p6_consts(T, W)
    smin, smax, umax = -(1 << (W - 1)), (1 << (W - 1)) - 1, (1 << W) - 1
    cs = T === Int8 ? [-128, smin - 1, smin, -1, 0, 1, smax, smax + 1, umax, umax + 1, 127] :
                      [0, 1, smax, smax + 1, umax, umax + 1, 127, 128, 255]
    return sort(unique(c for c in cs if typemin(T) <= c <= typemax(T)))
end

const P6_WS  = (2, 3, 4, 6, 8)
const P6_OPS = ((:<, "lt"), (:<=, "le"), (:>, "gt"), (:>=, "ge"),
                (:(==), "eq"), (:!=, "ne"))

# One top-level method per (type, operator, literal): the literal must be a
# real constant in the IR, not a captured value.
const P6_FUNS = Dict{Tuple{DataType,Symbol,Int},Function}()
for T in (Int8, UInt8), (op, opname) in P6_OPS
    for C in sort(unique(c for W in P6_WS for c in p6_consts(T, W)))
        fname = Symbol("p6_", T, "_", opname, "_", C < 0 ? "m$(-C)" : "$C")
        P6_FUNS[(T, op, C)] =
            @eval $fname(x::$T) = ifelse($op(x, $(T(C))), $(T(1)), $(T(0)))
    end
end

function p6_compile(f, T; W, optimize)
    try
        return reversible_compile(f, T; bit_width=W, optimize, strategy=:expression), nothing
    catch e
        e isa ArgumentError || rethrow()
        return nothing, e
    end
end
p6_is_refusal(e) = e isa ArgumentError && occursin("Bennett-mrhg", e.msg)

"Inputs (W-bit patterns) on which the circuit disagrees with the number-semantics oracle."
function p6_mismatches(c, f, T, op, C, W)
    bad = Int[]
    opf = getfield(Base, op)
    for p in 0:p6_wmask(W)
        want = (op in (:(==), :!=) ? opf(p, mod(C, 1 << W)) :
                                     opf(p6_num(T, p, W), C)) ? 1 : 0
        got = Int(simulate(c, T, p6_in(T, p))) & p6_wmask(W)
        got == want || push!(bad, p)
    end
    return bad
end

# Cells where the optimizer folds the comparison literal into a sign-bit test
# (`x < 0x80` -> `icmp sgt x, -1`), whose constants fit every W.  Pinned as a
# known hole by Bennett-6p8j; Bennett-koi8 refuses every signed ordering in
# optimised IR at W < 8, so these cells must now be refusals.
p6_signbit_fold(T, op, C, W, optimize) = optimize && W < 8 && T === UInt8 &&
    ((op in (:<, :>=) && C == 128) || (op in (:<=, :>) && C == 127))

p6_eq100(x::Int8) = ifelse(x == Int8(100), Int8(1), Int8(0))

# Range checks the optimizer rewrites into an UNSIGNED compare on signed data.
# Pre-fix both were accepted at W=4 and wrong (at x = -8, -7 and x = -8..-4).
p6_range(x::Int8) = ifelse(Int8(0) <= x < Int8(10), Int8(1), Int8(0))   # ult x, 10
p6_outside(x::Int8) = ifelse(x < Int8(0) || x > Int8(12), Int8(1), Int8(0)) # ugt x, 12
p6_band(x::Int8) = ifelse(Int8(9) <= x <= Int8(12), Int8(1), Int8(0))   # add x, -9; ult 4

@testset "Bennett-6p8j — comparison constants under bit_width narrowing" begin

@testset "bead witness: x == Int8(-1) at bit_width=8 (nothing is re-typed)" begin
    f = P6_FUNS[(Int8, :(==), -1)]
    for optimize in (false, true)
        c, err = p6_compile(f, Int8; W=8, optimize)
        @test err === nothing
        err === nothing || continue
        @test verify_reversibility(c)
        @test simulate(c, Int8(-1)) == Int8(1)
        @test all(simulate(c, x) == f(x) for x in typemin(Int8):typemax(Int8))
    end
end

@testset "exhaustive sweep: every predicate x boundary constant x W x optimize" begin
    n_acc = 0; n_ref = 0
    wrong = String[]; holes = String[]; missing_acc = String[]; bad_err = String[]
    n_fold = 0
    for T in (Int8, UInt8), (op, _) in P6_OPS, W in P6_WS, C in p6_consts(T, W),
        optimize in (false, true)
        f = P6_FUNS[(T, op, C)]
        c, err = p6_compile(f, T; W, optimize)
        cell = "$T $op $C @W=$W,opt=$optimize"
        p6_signbit_fold(T, op, C, W, optimize) && (n_fold += 1)
        # Must compile: the unoptimised IR is the literal `icmp pred x, C`;
        # at W = 8 nothing is re-typed; otherwise a signed ordering needs a
        # signed W-bit literal, an unsigned one 0..2^(W-1)-1 (the bound a
        # folded signed range check agrees on), and eq/ne a sign- or
        # zero-extended W-bit pattern other than the type maxima -1 / 127.
        # Bennett-koi8: eq/ne now needs 0..2^(W-1)-1 (a negative or high
        # constant can be an ordering the optimizer folded into an equality).
        c8 = C > 127 ? C - 256 : C            # the i8 constant LLVM hands over
        fits = W == 8 || (op in (:(==), :!=) ?
                (0 <= c8 <= (1 << (W - 1)) - 1) :
            T === Int8 ? -(1 << (W - 1)) <= C <= (1 << (W - 1)) - 1 :
                         0 <= C <= (1 << (W - 1)) - 1)
        if err !== nothing
            n_ref += 1
            p6_signbit_fold(T, op, C, W, optimize) && push!(holes, cell)
            p6_is_refusal(err) || push!(bad_err, cell)
            (!optimize && fits) && push!(missing_acc, cell)
            continue
        end
        n_acc += 1
        @test verify_reversibility(c)
        bad = p6_mismatches(c, f, T, op, C, W)
        isempty(bad) && continue
        push!(wrong, "$cell wrong at patterns $(first(bad, 6))")
    end
    println("  6p8j cells: $n_acc accepted, $n_ref refused; WRONG: $wrong; " *
            "missing: $missing_acc; sign-bit folds refused: $(length(holes))")
    @test isempty(wrong)          # soundness: accepted => right on every input
    @test isempty(bad_err)        # a refusal is the narrowing ArgumentError
    @test isempty(missing_acc)    # non-vacuity: the allowlist accepts what it should
    @test n_acc >= 300 && n_ref >= 100
    # the former known hole (Bennett-6p8j): every sign-bit-fold cell refused
    @test length(holes) == n_fold
    @test n_fold > 0
end

@testset "pinned refusals: one IR constant, two meanings" begin
    # `Int8(-1)`, `0xff` and the folded ordering `x >= 0xff` are the same IR
    # `icmp eq x, -1`; the ordering has no W-bit meaning at W < 8, so the
    # constant is refused for every source.
    for W in (2, 3, 4, 6), optimize in (false, true)
        for (T, C) in ((Int8, -1), (UInt8, 255)), op in (:(==), :!=)
            c, err = p6_compile(P6_FUNS[(T, op, C)], T; W, optimize)
            @test c === nothing && p6_is_refusal(err)
        end
        c, err = p6_compile(P6_FUNS[(UInt8, :>=, 255)], UInt8; W, optimize=true)
        @test c === nothing && p6_is_refusal(err)
        # a literal whose low W bits do not extend back to it
        c, err = p6_compile(p6_eq100, Int8; W, optimize)
        @test c === nothing && p6_is_refusal(err)
    end
    # `x >= Int8(127)` folds to `x == 127`, and at W = 7 127 IS the zero-
    # extension of its low 7 bits: only the type-maximum rule refuses it
    # (pre-fix it was accepted and true at the pattern 1111111 = -1).
    c, err = p6_compile(P6_FUNS[(Int8, :>=, 127)], Int8; W=7, optimize=true)
    @test c === nothing && p6_is_refusal(err)
    @test occursin("Bennett-6p8j",
                   p6_compile(P6_FUNS[(Int8, :(==), -1)], Int8; W=4, optimize=true)[2].msg)
end

@testset "folded signed range checks (icmp ult/ugt on Int8 data)" begin
    for (f, oracle) in ((p6_range, s -> 0 <= s < 10), (p6_outside, s -> s < 0 || s > 12))
        for W in (2, 3, 4, 6, 8), optimize in (false, true)
            c, err = p6_compile(f, Int8; W, optimize)
            if err !== nothing
                @test p6_is_refusal(err)
                continue
            end
            @test verify_reversibility(c)
            @test all((Int(simulate(c, Int8, p6_in(Int8, p))) & p6_wmask(W)) ==
                      (oracle(p6_wsign(p, W)) ? 1 : 0) for p in 0:p6_wmask(W))
        end
        # at W = 8 the IR is the source program: it must compile
        @test p6_compile(f, Int8; W=8, optimize=true)[2] === nothing
    end
    # the pre-fix wrong cells are now refusals
    @test p6_compile(p6_range, Int8; W=4, optimize=true)[1] === nothing
    @test p6_compile(p6_outside, Int8; W=4, optimize=true)[1] === nothing
    # FORMER KNOWN HOLE (Bennett-6p8j): `9 <= x <= 12` folds to
    # `icmp ult (add x, -9), 4`; the out-of-range literal 12 hides in an add
    # constant, and the narrowed test was true for x = -7..-4 at W = 4.
    # Bennett-koi8 refuses a comparison of a computed (add) value in
    # optimised IR; unoptimised IR is the source's own two compares.
    for W in (4, 6)
        err = try
            Bennett._narrow_ir(Bennett.extract_parsed_ir(p6_band, Tuple{Int8};
                                                         optimize=true), W; optimized=true)
            nothing
        catch e
            e
        end
        @test err !== nothing && p6_is_refusal(err)
        @test err !== nothing && occursin("Bennett-koi8", err.msg)
    end
    # W = 4: 12 is no signed 4-bit value, so the unoptimised IR is refused too
    c, err = p6_compile(p6_band, Int8; W=4, optimize=true)
    @test c === nothing && p6_is_refusal(err)
    # at a W where 9 and 12 are signed W-bit values the unoptimised IR narrows,
    # and since Bennett-sl4h optimize=true uses it (was: refused) — right
    for optimize in (false, true)
        c, err = p6_compile(p6_band, Int8; W=6, optimize)
        @test err === nothing
        @test c !== nothing && verify_reversibility(c) &&
              all((Int(simulate(c, Int8, p6_in(Int8, p))) & 63) ==
                  (9 <= p6_wsign(p, 6) <= 12 ? 1 : 0) for p in 0:63)
    end
end

@testset "hand-built IR: unsigned spelling, i1 compares, non-i8 constants" begin
    # `icmp slt x, 255` on i8 is `x < -1`: the constant is read at the
    # comparison width and rewritten to its signed value before lowering.
    mk(pred, k; w=8) = ParsedIR(8, [(:x, 8)],
        [IRBasicBlock(:entry, IRInst[
            IRICmp(:b, pred, ssa(:x), iconst(k), 8),
            IRCast(:r, :zext, ssa(:b), 1, 8)],
            IRRet(ssa(:r), 8))], [8])
    for W in (2, 3, 4, 6)
        # (hand-built IR is the literal program, so `optimized=false`: a
        # signed ordering in optimised IR is refused — Bennett-koi8)
        c = reversible_compile(Bennett._narrow_ir(mk(:slt, 255), W; optimized=false))
        @test verify_reversibility(c)
        @test all((simulate(c, Int8, Int8(p)) & p6_wmask(W)) ==
                  (p6_wsign(p, W) < -1 ? 1 : 0) for p in 0:p6_wmask(W))
    end
    # at W = 8 the unsigned spelling of -1 is accepted for eq unchanged
    c8 = reversible_compile(Bennett._narrow_ir(mk(:eq, 255), 8))
    @test verify_reversibility(c8)
    @test all(simulate(c8, Int8, x) == (x == Int8(-1) ? 1 : 0) for x in typemin(Int8):typemax(Int8))
    # 300 is not an i8 value: refused at every W, even 8
    for W in (4, 8)
        @test_throws ArgumentError Bennett._narrow_ir(mk(:eq, 300), W)
    end
    # an i1 compare is never re-typed, so `icmp eq i1 %b, -1` (true) is kept
    i1_p = ParsedIR(8, [(:x, 8)],
        [IRBasicBlock(:entry, IRInst[
            IRICmp(:b, :slt, ssa(:x), iconst(0), 8),
            IRICmp(:t, :eq, ssa(:b), iconst(-1), 1),
            IRSelect(:r, ssa(:t), iconst(3), iconst(1), 8)],
            IRRet(ssa(:r), 8))], [8])
    for W in (2, 3, 4)
        c = reversible_compile(Bennett._narrow_ir(i1_p, W; optimized=false))
        @test verify_reversibility(c)
        @test all((simulate(c, Int8, Int8(p)) & p6_wmask(W)) ==
                  (p6_wsign(p, W) < 0 ? 3 : 1) % (1 << W) for p in 0:p6_wmask(W))
    end
end

end # @testset Bennett-6p8j
