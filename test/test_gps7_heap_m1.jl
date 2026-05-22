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
using LLVM

# ---------------------------------------------------------------------------
# The M1 reference function. f1 builds a heap Int8 vector, pushes x, returns
# v[1] — which is x. f1 is the identity on Int8.
#
# Bennett-2mj3: f1 is now driven off a PRE-CAPTURED .ll fixture rather than
# `code_llvm`'d in-suite. `Pkg.test()` runs `--check-bounds=yes`, which forces
# every `@boundscheck` ON — f1's IR then carries an `@ijl_bounds_error_int`
# call the heap recogniser (correctly, FAIL-LOUD) rejects, so f1 cannot be
# compiled from source inside the suite. heap_m1_f1.ll was captured under
# DEFAULT check-bounds (the IR shape the recogniser was designed for) by
# `scripts/gen_heap_fixtures.jl`. The oracle check (f1 == identity) is
# unchanged — fixture conversion replaces only the IR-gen step.
f1(x::Int8) = let v = Int8[]; push!(v, x); v[1] end

const _GPS7_FIX = joinpath(@__DIR__, "fixtures")

# Compile a hand-written/captured .ll fixture under mem=:heap. Same idiom as
# `_m3_compile_ll` in test_5ikt_heap_m3.jl.
function _gps7_compile_ll(name::AbstractString)
    ir = read(joinpath(_GPS7_FIX, name), String)
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir)
        parsed = Bennett._module_to_parsed_ir(mod; mem=:heap)
        lr = Bennett.lower(parsed)
        Bennett.bennett(lr)
    end
end

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

# cond_pair: `[x, -x][1 + (x<0)]` — selects x when x≥0, -x when x<0, i.e.
# it computes abs(x) (note -(-128) wraps to -128). The vector literal lowers
# to a small heap `Vector{Int8}`, so the GC skeleton IS present and the
# mem=:heap recogniser DOES run on it. The M1 contract is "never MISCOMPILE
# cond_pair": whatever the recogniser does, the result must be oracle-correct.
#
# Bennett-2mj3: the lambda has ONE positional arg `x::Int8` — earlier the test
# called it as `_gps7_cond_pair((x,))` (a 1-tuple), which is a plain bug. It
# is now called `_gps7_cond_pair(x)`.
const _gps7_cond_pair = (x::Int8) -> [x, -x][1 + Int(x < Int8(0))]

@testset "Bennett-gps7 / M1 — heap-memory support" begin

    @testset "f1 compiles under mem=:heap (.ll fixture)" begin
        # Driven off heap_m1_f1.ll — see the f1 header note (Bennett-2mj3).
        c = _gps7_compile_ll("heap_m1_f1.ll")
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f1(x)   # oracle: f1 is the identity
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
        # The M1 contract is "never MISCOMPILE cond_pair". Under mem=:heap the
        # `[x,-x]` vector literal's GC skeleton is recognised and collapsed,
        # and cond_pair compiles to a circuit that must be oracle-correct.
        #
        # Bennett-2mj3: this is asserted DIRECTLY — the test no longer branches
        # on whether the default path throws. (The default mem=:auto path's
        # behaviour differs by check-bounds mode: under `--check-bounds=yes`,
        # which `Pkg.test()` uses, it rejects on the U15 inline-asm wall;
        # under default check-bounds it compiles. That brittle mode-dependence
        # was the old test's bug — and it is irrelevant to the M1 contract,
        # which is about the mem=:heap path being correct.)
        c = reversible_compile(_gps7_cond_pair, Int8; mem=:heap)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == _gps7_cond_pair(x)
        end
    end
end
