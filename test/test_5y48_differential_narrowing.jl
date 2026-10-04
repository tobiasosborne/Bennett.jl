# Bennett-5y48 (differential) / Bennett-sl4h: `bit_width = W` with
# `optimize = true` narrows BOTH the unoptimised and the optimised LLVM IR.
# Each reading is wrong for a class the other cannot see: the optimised IR
# holds folds valid only at the source width (`x * 16 == 0` is
# `(x & 15) == 0`), the unoptimised IR holds Julia library code written for
# the source width (`bitreverse(x) == 0` keeps Julia's 8-bit masks; LLVM folds
# it to `x == 0`).
#
# INVARIANT: when both readings are accepted, the compile returns a circuit
# only if the two narrowed circuits agree on every input (<= 16 input bits;
# a fixed sample above), and that circuit is the unoptimised one; otherwise it
# is an ArgumentError naming Bennett-5y48 / Bennett-sl4h and the first
# differing input.  An input on which one circuit fails (loop guard, dirty
# ancilla, changed input) and the other does not is a disagreement.
#
# THE ORACLE (independent of src/) is the W-bit meaning of each program on
# the W-bit input pattern p.

using Test
using Bennett

d48_mask(W) = (1 << W) - 1
d48_sval(p, W) = p >= (1 << (W - 1)) ? p - (1 << W) : p
d48_in(::Type{T}, p) where {T} = reinterpret(T, (p % unsigned(T)))

d48_is_diff(e) = e isa ArgumentError && occursin("Bennett-5y48 / Bennett-sl4h", e.msg) &&
                 occursin("narrow to different", e.msg) &&
                 occursin("First differing input", e.msg)
d48_is_refusal(e) = e isa ArgumentError && occursin("refusing to narrow", e.msg)

# (name, body over x::T, W-bit oracle(T, p, W))
const D48_PROGS = [
    ("bitreverse==0", :(ifelse(bitreverse(x) == zero(x), one(x), zero(x))),
                      (T, p, W) -> p == 0 ? 1 : 0),
    ("x*16==0",       :(ifelse(x * (16 % typeof(x)) == zero(x), one(x), zero(x))),
                      (T, p, W) -> (p * 16) & d48_mask(W) == 0 ? 1 : 0),
    ("x*4==0",        :(ifelse(x * (4 % typeof(x)) == zero(x), one(x), zero(x))),
                      (T, p, W) -> (p * 4) & d48_mask(W) == 0 ? 1 : 0),
    ("x+1",           :(x + one(x)),            (T, p, W) -> (p + 1) & d48_mask(W)),
    ("x*x+3",         :(x * x + (3 % typeof(x))), (T, p, W) -> (p * p + 3) & d48_mask(W)),
    ("x>>>1 xor x",   :(xor(x >>> 1, x)),       (T, p, W) -> xor(p >> 1, p)),
    ("x<0 ? -x : x",  :(ifelse(x < zero(x), -x, x)),
                      (T, p, W) -> T <: Signed ? mod(abs(d48_sval(p, W)), 1 << W) : p),
]

const D48_FUNS = Dict{Tuple{String, DataType}, Function}()
let n = 0
    for (name, body, _) in D48_PROGS, T in (Int8, UInt8)
        fname = Symbol("d48_f_", n += 1)
        D48_FUNS[(name, T)] = @eval $fname(x::$T) = $body
    end
end

d48_two(x::Int16, y::Int16) = x * y + x
d48_two_bad(x::Int16, y::Int16) = ifelse((x == 0) & (y == 0), x * y + x + Int16(1), x * y + x)

function d48_agree_check(f)
    c1 = reversible_compile(f, Int8; bit_width=5, strategy=:expression)
    cU = reversible_compile(f, Int8; bit_width=5, optimize=false, strategy=:expression)
    n0 = length(Bennett._narrow_verdict_cache)
    c2 = reversible_compile(f, Int8; bit_width=5, strategy=:expression)
    return (c1 === cU && c2 === c1), n0, length(Bennett._narrow_verdict_cache)
end

@testset "Bennett-5y48 (differential): optimised vs unoptimised narrowing" begin

    @testset "review witness: refused, naming the first differing input" begin
        f = D48_FUNS[("bitreverse==0", UInt8)]
        err = try reversible_compile(f, UInt8; bit_width=7); nothing catch e; e end
        @test d48_is_diff(err)
        @test occursin("all 128 inputs", err.msg)
        @test occursin("unoptimised-IR circuit gives", err.msg) &&
              occursin("optimised-IR circuit gives", err.msg)
    end

    @testset "grid: program × T × W, optimize=true — accepted ⇒ right" begin
        counts = Dict(:right => 0, :diff => 0, :refused => 0)
        for (name, _, orc) in D48_PROGS, T in (Int8, UInt8), W in 2:7
            f = D48_FUNS[(name, T)]
            c = try
                reversible_compile(f, T; bit_width=W, strategy=:expression)
            catch e
                @test d48_is_refusal(e)
                counts[d48_is_diff(e) ? :diff : :refused] += 1
                continue
            end
            @test all(p -> Int(simulate(c, T, d48_in(T, p))) & d48_mask(W) == orc(T, p, W),
                      0:d48_mask(W))
            @test verify_reversibility(c)
            counts[:right] += 1
        end
        @info "Bennett-5y48 differential grid" counts...
        @test counts[:diff] > 0 && counts[:right] > 0
    end

    @testset "agreement returns the unoptimised circuit; verdict is cached" begin
        # One expression (a function): a top-level closure between statements
        # moves the world counter, which empties the world-gated caches.
        f = D48_FUNS[("x*x+3", Int8)]
        same, n0, n1 = d48_agree_check(f)
        @test same
        @test n0 == n1
    end

    @testset "> 16 input bits: sampled comparison (corners included)" begin
        c = reversible_compile(d48_two, Int16, Int16; bit_width=12)
        for (x, y) in ((0, 0), (5, 7), (-1, 3), (2047, -2048))
            @test Int(simulate(c, (Int16(x), Int16(y)))) & d48_mask(12) ==
                  (x * y + x) & d48_mask(12)
        end
        @test verify_reversibility(c)
        # A disagreement on the all-zeros input alone is found by the sample.
        a = reversible_compile(d48_two, Int16, Int16)
        b = reversible_compile(d48_two_bad, Int16, Int16)
        why = Bennett._narrow_disagreement(a, b, 16)
        @test why isa String && occursin("a sample of", why) &&
              occursin("(0x0, 0x0)", why)
        @test Bennett._narrow_disagreement(a, a, 16) === nothing
        M, exhaustive = Bennett._narrow_compare_inputs([12, 12])
        @test !exhaustive && size(M) == (2, 4096)
        M2, ex2 = Bennett._narrow_compare_inputs([8, 8])
        @test ex2 && size(M2, 2) == 65536 && length(unique(eachcol(M2))) == 65536
    end

    @testset "one circuit failing where the other does not is a disagreement" begin
        G = Bennett.ReversibleGate
        good = ReversibleCircuit(3, G[CNOTGate(1, 2)], [1], [2], [3], [1], [1])
        dirty = ReversibleCircuit(3, G[CNOTGate(1, 2), CNOTGate(1, 3)], [1], [2], [3], [1], [1])
        why = Bennett._narrow_disagreement(good, dirty, 1)
        @test why isa String && occursin("(0x1,)", why) && occursin("fails", why)
        @test Bennett._narrow_disagreement(good, good, 1) === nothing
        other = ReversibleCircuit(4, G[CNOTGate(1, 3)], [1, 2], [3], [4], [2], [1])
        @test occursin("layout", Bennett._narrow_disagreement(good, other, 1))
    end

    @testset "optimize=false and W == S are not cross-checked" begin
        f = D48_FUNS[("x*16==0", Int8)]
        c = reversible_compile(f, Int8; bit_width=6, optimize=false, strategy=:expression)
        @test all(p -> Int(simulate(c, Int8, d48_in(Int8, p))) & 63 ==
                       ((p * 16) & 63 == 0 ? 1 : 0), 0:63)
        c8 = reversible_compile(f, Int8; bit_width=8, strategy=:expression)
        @test all(x -> simulate(c8, Int8, x) == f(x), typemin(Int8):typemax(Int8))
    end
end
