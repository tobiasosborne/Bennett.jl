# Bennett-gps7 / M1 — Julia heap-memory support, Milestone 1.
#
# M1 makes the smallest real heap case compile: a function that allocates a
# heap `Vector`, `push!`es into it, and returns a value that is provably
# INDEPENDENT of the heap. Under `optimize=true` such a function's IR still
# contains the full dead GC/heap skeleton (gcframe alloca + volatile memset,
# TLS-read inline asm, `@ijl_gc_small_alloc`, `Memory{T}` header stores, a
# `growend!` callee, a capacity diamond) — but the return value is the
# function argument directly. M1 RECOGNISES that skeleton, PROVES it dead
# w.r.t. the return (the 5-part liveness proof), and SUPPRESSES it so the
# surviving slice (`ret %x`) compiles to an identity circuit.
#
# `mem=:heap` is the opt-in extraction flag that enables the recogniser.
# Under the default `mem=:auto` the recogniser does NOT run — heap functions
# still hit the U15 inline-asm reject (unchanged behaviour).
#
# CLAUDE.md §1 (FAIL LOUD — the catastrophic failure here is a silent
# miscompile), §3 (red-green TDD), §4 (every test pairs verify_reversibility
# with an output-vs-oracle check).

using Test
using Bennett

# ---------------------------------------------------------------------------
# The M1 reference function. f1 builds a heap Int8 vector, pushes x, returns
# v[1] — which is x. f1 is the identity on Int8.
f1(x::Int8) = let v = Int8[]; push!(v, x); v[1] end

# Stress shapes (see consensus §6 risk surface). Each is dumped + studied as
# real optimize=true IR; the assertions below are pinned to observed
# behaviour, NOT guessed.

# push! inside a nested branch — the surviving non-skeleton slice contains a
# real `if x>0` branch, so M1 MUST reject loud (condition 4: surviving slice
# must be straight-line).
f_nested_branch(x::Int8) = let v = Int8[]
    if x > Int8(0); push!(v, x); end
    x
end

# Vector escapes into a non-inlined callee — the gc_alloc result flows into
# `@j_sink_*`, a non-allowlisted heap callee. M1 MUST reject loud
# (P-callee / P-return). This is the critical safety case.
@noinline _gps7_sink(v::Vector{Int8}) = length(v)
f_escape(x::Int8) = let v = Int8[]; push!(v, x); Int8(_gps7_sink(v)) end

# Vector-of-tuples — the surviving slice contains a real `load` off
# skeleton-owned `Memory` storage (the bounds-check size load) plus a
# non-skeleton bounds branch. M1 MUST reject loud (P-noload-into-live).
f_vec_tuples(x::Int8) = let v = Tuple{Int8,Int8}[]; push!(v, (x, x)); v[1][1] end

# A plain non-heap function — under mem=:heap the recogniser must be inert
# (zero @ijl_gc_small_alloc) and compilation must be byte-identical to default.
g_nonheap(x::Int8) = x + Int8(1)

# cond_pair: under default Julia check-bounds this lowers with a stack
# `alloca [3 x i64]` and NO GC skeleton. Under mem=:heap the recogniser is
# therefore inert and behaviour is identical to default. The M1 contract is
# "never MISCOMPILE cond_pair" — a loud reject is acceptable.
const _gps7_cond_pair = (x::Int8,) -> [x, -x][1 + Int(x < Int8(0))]

@testset "Bennett-gps7 / M1 — heap-memory support" begin

    @testset "f1 compiles under mem=:heap" begin
        c = reversible_compile(f1, Int8; mem=:heap)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f1(x)
        end
    end

    @testset "default mem=:auto still rejects f1 (unchanged)" begin
        # The U15 inline-asm reject must still fire on the default path —
        # mem=:heap is strictly opt-in, zero blast radius on the default.
        @test_throws Exception reversible_compile(f1, Int8)
    end

    @testset "non-heap function under mem=:heap (recogniser inert)" begin
        c = reversible_compile(g_nonheap, Int8; mem=:heap)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == g_nonheap(x)
        end
    end

    @testset "stress: push! in nested branch rejects loud" begin
        # Surviving slice has a real `if x>0` branch — not straight-line.
        @test_throws Exception reversible_compile(f_nested_branch, Int8; mem=:heap)
    end

    @testset "stress: vector escaping into a callee rejects loud" begin
        # gc_alloc result flows into a non-allowlisted heap callee.
        @test_throws Exception reversible_compile(f_escape, Int8; mem=:heap)
    end

    @testset "stress: vector-of-tuples rejects loud" begin
        # Surviving slice loads from skeleton-owned Memory storage.
        @test_throws Exception reversible_compile(f_vec_tuples, Int8; mem=:heap)
    end

    @testset "stress: cond_pair never miscompiles under mem=:heap" begin
        # cond_pair has no GC skeleton; recogniser inert; behaviour ==
        # default. Whatever happens, it must NOT silently produce a wrong
        # circuit. Default rejects (stack-alloca width mismatch); mem=:heap
        # must reject identically.
        default_threw = false
        try
            reversible_compile(_gps7_cond_pair, Int8)
        catch
            default_threw = true
        end
        if default_threw
            @test_throws Exception reversible_compile(_gps7_cond_pair, Int8; mem=:heap)
        else
            # If default ever starts compiling cond_pair, mem=:heap must
            # produce an oracle-correct circuit (never a miscompile).
            c = reversible_compile(_gps7_cond_pair, Int8; mem=:heap)
            @test verify_reversibility(c)
            for x in typemin(Int8):typemax(Int8)
                @test simulate(c, x) == _gps7_cond_pair((x,))
            end
        end
    end
end
