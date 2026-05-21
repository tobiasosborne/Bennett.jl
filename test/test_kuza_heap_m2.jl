# Bennett-kuza / M2 — Julia heap-memory support, Milestone 2.
#
# M2 handles the *partially-dead* heap case: a statically-sized heap integer
# array whose element DATA is LIVE into the return. M1 (`src/extract/heap.jl`)
# only compiled functions whose heap collection was wholly DEAD w.r.t. the
# return. M2 partitions M1's monolithic skeleton set SKEL into
#   {dead GC machinery → drop} ∪ {live element traffic → re-root onto a
#    synthetic const-N IRAlloca}
# so the EXISTING :shadow / :shadow_checkpoint alloca lowering compiles it.
#
# No new IR node, no lowering change. All M2 logic lives in
# `src/extract/heap.jl`.
#
# CLAUDE.md §1 (FAIL LOUD — a silent miscompile is THE catastrophe), §3
# (red-green TDD), §4 (every test pairs verify_reversibility with an
# output-vs-oracle sweep).

using Test
using Bennett
using LLVM

# ---------------------------------------------------------------------------
# M2 primary target. g256 allocates a heap Int8 Vector of 256 elements (N=256
# keeps the heap skeleton — smaller N is SROA'd to a stack alloca), writes the
# three elements it will read, then returns a RUNTIME-indexed element. The
# element data is LIVE into the return.
#
# The runtime index is `mod(i,3)+1 ∈ {1,2,3}` — always in range AND always
# hits an INITIALISED element (indices 1,2,3 are all stored above). Reading an
# `undef` element would make `g256` itself return garbage (Julia reads
# uninitialised heap memory), so the oracle must only ever index written
# slots. The Julia bounds-check diamond never traps (index ⊆ [1,256]).
g256(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
    a[1] = x
    a[2] = x + Int8(1)
    a[3] = x + Int8(2)
    a[mod(i, Int8(3)) + 1]
end

const _KUZA_FIX = joinpath(@__DIR__, "fixtures")

# Julia oracle for the cond_pair fixture.
_kuza_cp(x::Int8) = [x, -x][1 + Int(x < Int8(0))]

# Heap array escapes into a non-inlined callee — the gc_alloc result flows
# into `@j_*sink*`, a non-allowlisted heap callee. M2 MUST reject loud.
@noinline _kuza_sink(v::Vector{Int8}) = length(v)
_kuza_escape(x::Int8) = let a = Array{Int8}(undef, 256)
    a[1] = x
    Int8(_kuza_sink(a)) + a[mod(x, Int8(100)) + 1]
end

@testset "Bennett-kuza / M2 — heap array element-data live" begin

    @testset "g256 — runtime-indexed heap array, bounds diamond" begin
        c = reversible_compile(g256, Int8, Int8; mem=:heap)
        @test verify_reversibility(c)
        # Oracle sweep over all 256 x and a representative i grid.
        for x in Int8(-128):Int8(127)
            for i in vcat(collect(Int8(-128):Int8(8):Int8(127)),
                          Int8[-1, 0, 1, 99, 100])
                @test simulate(c, (x, i)) == g256(x, i)
            end
        end
    end

    @testset "cond_pair under --check-bounds=yes" begin
        ir = read(joinpath(_KUZA_FIX, "heap_m2_cond_pair.ll"), String)
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod; mem=:heap)
            lr = Bennett.lower(parsed)
            c = Bennett.bennett(lr)
            @test verify_reversibility(c)
            for x in Int8(-128):Int8(127)
                @test simulate(c, x) == _kuza_cp(x)
            end
        end
    end

    @testset "reject — two distinct heap arrays (>2 allocs)" begin
        # Two independent heap Vectors → >=3 @ijl_gc_small_alloc.
        f2arr(x::Int8) = let a = Array{Int8}(undef, 256), b = Array{Int8}(undef, 256)
            a[1] = x; b[1] = x
            a[mod(x, Int8(100)) + 1] + b[mod(x, Int8(50)) + 1]
        end
        @test_throws Exception reversible_compile(f2arr, Int8; mem=:heap)
    end

    @testset "reject — heap array escapes into a callee" begin
        @test_throws Exception reversible_compile(
            _kuza_escape, Int8; mem=:heap)
    end

    @testset "reject — runtime-index element STORE" begin
        # M2 is scoped (consensus design §4 M2) to constant-offset stores +
        # runtime-indexed loads. A runtime-index element store `a[idx(i)]=x`
        # is NOT covered by the soundness proof — the M2-aware ret-ancestor
        # walk never reaches a store index. `_partition_skeleton` must reject
        # it loud, before `_ElemAccess` capture.
        fstore(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
            a[1] = x
            a[mod(i, Int8(3)) + 1] = x + Int8(7)   # runtime-index STORE
            a[2]                                    # const-index load
        end
        @test_throws Exception reversible_compile(
            fstore, Int8, Int8; mem=:heap)
    end

    @testset "reject — non-bounds-check user branch survives" begin
        # A real `if` on a non-skeleton condition that is NOT a bounds-check
        # diamond → general control flow, out of M2 scope.
        fbranch(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
            a[1] = x
            r = a[mod(i, Int8(100)) + 1]
            if r > Int8(0); r = r + Int8(1); end
            r
        end
        @test_throws Exception reversible_compile(fbranch, Int8, Int8; mem=:heap)
    end

end
