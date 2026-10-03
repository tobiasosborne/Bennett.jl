# Bennett-koi8: `bit_width=W` narrowing must not accept a comparison the
# optimizer folded out of a source-width ORDERING.
#
# LLVM folds the UInt8 range test `(x >= 248) & (x <= 248)` to
# `icmp eq i8 x, -8`.  The Bennett-6p8j rule accepted -8 for eq at W = 4 (it
# sign-extends back from its low 4 bits) and compared against the pattern 8,
# so input 8 returned 1 — but every 4-bit unsigned value is below 248, so the
# source program returns 0.  Hand-picked cases have missed a fold three times
# running, so the main check here is a GENERATED corpus of source predicates
# over boundary constants.
#
# THE ORACLE (independent of src/): evaluate the source function itself on the
# W-bit input read as a number in the source type's signedness — signed
# (-2^(W-1)..2^(W-1)-1) for an Int8 argument, unsigned (0..2^W-1) for a UInt8
# one.  Literals are the numbers the source wrote, for eq/ne too (`x == 5` is
# never true for a 3-bit signed x).  Every ACCEPTED circuit must give exactly
# that answer on every W-bit input; a refusal (the Bennett-mrhg ArgumentError)
# is always a correct answer.

using Test
using Random
using Bennett

k8_wmask(W) = (1 << W) - 1
k8_wsign(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
k8_in(::Type{Int8}, p)  = reinterpret(Int8, UInt8(p & 0xff))
k8_in(::Type{UInt8}, p) = UInt8(p & 0xff)
k8_num(::Type{Int8}, p, W)  = Int8(k8_wsign(p, W))   # the W-bit input as a T
k8_num(::Type{UInt8}, p, W) = UInt8(p)

const K8_WS  = (2, 3, 4, 6, 8)
const K8_OPS = (:<, :<=, :>, :>=, :(==), :!=)
# 0, 1, 2, 2^(W-1)-1, 2^(W-1), 2^W-1, 2^W for every W, then 127, 128, 248,
# 255, -1, -8, typemin, typemax — each wrapped into the source type (`c % T`),
# so for UInt8 -1 is 255 and for Int8 248 is -8.
const K8_RAW = sort(unique(vcat([0, 1, 2],
    [c for W in K8_WS for c in ((1 << (W - 1)) - 1, 1 << (W - 1), (1 << W) - 1, 1 << W)],
    [127, 128, 248, 255, -1, -8])))
k8_consts(T) = sort(unique(vcat([c % T for c in K8_RAW], [typemin(T), typemax(T)])))

# One top-level method per source predicate: the literals must be real IR
# constants, not captured values.  Singletons are enumerated; the 2-term `&` /
# `|` combinations (36 operator pairs x 17^2 constants per type) are sampled
# with a fixed seed.
const K8_NPAIRS = parse(Int, get(ENV, "BENNETT_KOI8_NPAIRS", "60"))
const K8_CASES = Tuple{DataType,String,Function}[]
let rng = Xoshiro(0x6b6f6938), n = 0
    for T in (UInt8, Int8)
        cs = k8_consts(T)
        preds = Any[(:($op(x, $c)), "x $op $c") for op in K8_OPS for c in cs]
        for comb in (:&, :|)
            for _ in 1:K8_NPAIRS
                o1, o2 = rand(rng, K8_OPS), rand(rng, K8_OPS)
                c1, c2 = rand(rng, cs), rand(rng, cs)
                push!(preds, (Expr(:call, comb, :($o1(x, $c1)), :($o2(x, $c2))),
                              "(x $o1 $c1) $comb (x $o2 $c2)"))
            end
        end
        for (body, desc) in preds
            fname = Symbol("k8_case_", n += 1)
            f = @eval $fname(x::$T) = ifelse($body, $(T(1)), $(T(0)))
            push!(K8_CASES, (T, desc, f))
        end
    end
end

function k8_compile(f, T; W, optimize)
    try
        return reversible_compile(f, T; bit_width=W, optimize, strategy=:expression), nothing
    catch e
        e isa ArgumentError || rethrow()
        return nothing, e
    end
end
k8_is_refusal(e) = e isa ArgumentError && occursin("Bennett-mrhg", e.msg)

"W-bit patterns on which circuit `c` disagrees with the source function `f`."
function k8_mismatches(c, f, T, W)
    bad = Int[]
    for p in 0:k8_wmask(W)
        want = Int(f(k8_num(T, p, W))) & k8_wmask(W)
        got = Int(simulate(c, T, k8_in(T, p))) & k8_wmask(W)
        got == want || push!(bad, p)
    end
    return bad
end

k8_band(x::UInt8) = ifelse((x >= UInt8(248)) & (x <= UInt8(248)), UInt8(1), UInt8(0))
# folds outside the corpus's reach (pinned IR shapes at the time of writing)
k8_union(x::UInt8)  = ifelse((x < 0x02) | (x >= 0x80), 0x01, 0x00)  # icmp slt x, 2
k8_signbit(x::Int8) = ifelse(x < Int8(0), Int8(1), Int8(0))         # lshr x, 7
k8_mul16(x::Int8)   = ifelse(x * Int8(16) == Int8(0), Int8(1), Int8(0)) # (x & 15) == 0

@testset "Bennett-koi8 — folded comparisons under bit_width narrowing" begin

@testset "reviewer witness: (x >= 248) & (x <= 248) on UInt8" begin
    for W in (2, 3, 4, 6), optimize in (false, true)
        c, err = k8_compile(k8_band, UInt8; W, optimize)
        if err !== nothing
            @test k8_is_refusal(err)
            continue
        end
        @test verify_reversibility(c)
        @test isempty(k8_mismatches(c, k8_band, UInt8, W))
    end
    # the exact reported cell: refused (or, if ever accepted, 0 at input 8)
    c, err = k8_compile(k8_band, UInt8; W=4, optimize=true)
    @test c === nothing || Int(simulate(c, UInt8(8))) == 0
    # at W = 8 nothing is re-typed: the source program compiles unchanged
    c8, err8 = k8_compile(k8_band, UInt8; W=8, optimize=true)
    @test err8 === nothing
    @test c8 !== nothing && verify_reversibility(c8) &&
          all(simulate(c8, x) == k8_band(x) for x in typemin(UInt8):typemax(UInt8))
end

@testset "named folds: union -> signed ordering, sign test -> lshr S-1" begin
    # `(x < 2) | (x >= 0x80)` on UInt8 becomes `icmp slt x, 2`: a signed
    # ordering against a small constant, so refusing only the sign-bit tests
    # (-1 / 0) would not be enough.  Pre-fix: accepted, wrong on 8..15 at W=4.
    for W in (2, 3, 4, 6)
        c, err = k8_compile(k8_union, UInt8; W, optimize=true)
        @test c === nothing && k8_is_refusal(err)
    end
    # Int8 `x < 0` as an integer becomes `lshr x, 7`, which at W = 7 is 0.
    c, err = k8_compile(k8_signbit, Int8; W=7, optimize=true)
    @test c === nothing && k8_is_refusal(err) && occursin("Bennett-koi8", err.msg)
    c, err = k8_compile(k8_signbit, Int8; W=7, optimize=false)
    @test err === nothing
    @test c !== nothing && verify_reversibility(c) &&
          isempty(k8_mismatches(c, k8_signbit, Int8, 7))
end

@testset "residual hole (Bennett-sl4h): folds that use S-bit arithmetic facts" begin
    # `x * 16 == 0` folds to `(x & 15) == 0`, true iff 16 | x at 8 bits.  In
    # W = 6 modular arithmetic x * 16 == 0 iff 4 | x.  Every operand and
    # constant of the folded IR is narrowable, so no local rule sees it;
    # unoptimised IR narrows the source's own multiply and is right.
    oracle(p) = mod(16 * k8_wsign(p, 6), 64) == 0 ? 1 : 0
    for optimize in (false, true)
        c, err = k8_compile(k8_mul16, Int8; W=6, optimize)
        @test err === nothing
        ok = c !== nothing && verify_reversibility(c) &&
             all((Int(simulate(c, Int8, k8_in(Int8, p))) & 63) == oracle(p) for p in 0:63)
        optimize ? (@test_broken ok) : (@test ok)
    end
end

@testset "generated corpus: $(length(K8_CASES)) source predicates x W x optimize" begin
    n_acc = 0; n_ref = 0; n_rev = 0
    wrong = String[]; bad_err = String[]; w8_ref = String[]
    acc_by = Dict{Tuple{DataType,Int,Bool},Int}()
    for (T, desc, f) in K8_CASES, W in K8_WS, optimize in (false, true)
        c, err = k8_compile(f, T; W, optimize)
        cell = "$T $desc @W=$W,opt=$optimize"
        if err !== nothing
            n_ref += 1
            k8_is_refusal(err) || push!(bad_err, "$cell: $(sprint(showerror, err))")
            W == 8 && push!(w8_ref, cell)
            continue
        end
        n_acc += 1
        acc_by[(T, W, optimize)] = get(acc_by, (T, W, optimize), 0) + 1
        verify_reversibility(c) || (n_rev += 1)
        bad = k8_mismatches(c, f, T, W)
        isempty(bad) || push!(wrong, "$cell wrong at patterns $(first(bad, 6))")
    end
    println("  koi8 corpus: $(length(K8_CASES)) predicates, ",
            "$(n_acc + n_ref) compiles: $n_acc accepted, $n_ref refused; ",
            "$(length(wrong)) accepted-and-wrong")
    for T in (UInt8, Int8), optimize in (false, true)
        println("    $T opt=$optimize accepted per W: ",
                join(("W=$W:$(get(acc_by, (T, W, optimize), 0))" for W in K8_WS), " "))
    end
    isempty(wrong) || foreach(m -> println("    WRONG ", m), first(wrong, 30))
    isempty(bad_err) || foreach(m -> println("    BAD ERR ", m), first(bad_err, 5))
    @test isempty(wrong)        # soundness: accepted => right on every input
    @test n_rev == 0            # every accepted circuit cleans its ancillae
    @test isempty(bad_err)      # a refusal is the narrowing ArgumentError
    @test isempty(w8_ref)       # W == S re-types nothing: every case compiles
    @test n_acc >= 1000         # non-vacuity
end

end # @testset Bennett-koi8
