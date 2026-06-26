# Bennett-jfw6 — regression lock for the `mem=:vm` Case A Vector/GenericMemory
# extraction recognizer (src/extract/vector_vm*.jl, 921 LOC).
#
# The recognizer is ALREADY IMPLEMENTED and shipping; this file LOCKS its
# verified behavior. Per CLAUDE.md Rule 4 (exhaustive verification) the
# recognizer must not silently miscompile, and per Rule 1 (fail fast, fail
# loud) every out-of-scope shape must `error()` with a clear, stable message.
#
# Test strategy (per CLAUDE.md Rule 5 — LLVM IR is NOT a stable API):
#   * SUCCESS cases assert STRUCTURAL invariants (multi-block, exactly one
#     dynamic-N IRAlloca, >=1 IRVarGEP, >=1 IRStore) — NEVER exact block/gate
#     counts.
#   * FAIL-LOUD cases assert that extraction throws AND that the message
#     contains a stable fragment of the documented error wording.
#
# Functions are defined at TOP LEVEL (not closures) because
# `extract_parsed_ir` compiles them through Julia/LLVM codegen.

using Bennett
using Test

# Collect all non-terminator instructions across every block.
_jfw6_allins(pir) = collect(Iterators.flatten(bb.instructions for bb in pir.blocks))

# Run the recognizer; return the message of whatever error it throws (via
# showerror so it matches what a user would see), or `nothing` on success.
function _jfw6_failmsg(f, argT)
    try
        Bennett.extract_parsed_ir(f, argT; optimize=false, mem=:vm)
        return nothing
    catch e
        return sprint(showerror, e)
    end
end

# ---------------------------------------------------------------------------
# SUCCESS-CASE functions: a single `for i in 1:n` loop over ONE dynamic Vector.
# ---------------------------------------------------------------------------

# S1 — fused write + reduce in one loop (writes v[i], then reads it back into s).
function jfw6_vfused(n::Int64)
    v = Vector{Int8}(undef, n)
    s = Int8(0)
    for i in 1:n
        @inbounds v[i] = Int8(i % 100)
        @inbounds s += v[i]
    end
    return s
end

# S2 — single write loop, then a scalar read of v[1] (no in-loop read-back).
function jfw6_vwrite1(n::Int64)
    v = Vector{Int8}(undef, n)
    for i in 1:n
        @inbounds v[i] = Int8(i % 100)
    end
    return @inbounds v[1]
end

# ---------------------------------------------------------------------------
# FAIL-LOUD functions: out-of-Case-A shapes the recognizer must reject.
# ---------------------------------------------------------------------------

# F1 — two separate `for i in 1:n` loops (fill loop + sum loop): ambiguous
#      loop preheader (two `icmp(1, n)` bound tests).
function jfw6_vtwo_loop(n::Int64)
    v = Vector{Int8}(undef, n)
    for i in 1:n
        @inbounds v[i] = Int8(i % 100)
    end
    s = Int8(0)
    for j in 1:n
        @inbounds s += v[j]
    end
    return s
end

# F2 — while loop instead of `for i in 1:n`: no `icmp(1, n)` bound test.
function jfw6_vwhile(n::Int64)
    v = Vector{Int8}(undef, n)
    i = 1
    @inbounds while i <= n
        v[i] = Int8(i % 100)
        i += 1
    end
    return @inbounds v[1]
end

# F3 — two dynamic Vectors: Case A models a SINGLE dynamic backing per routine.
function jfw6_vtwo_vec(n::Int64)
    a = Vector{Int8}(undef, n)
    b = Vector{Int8}(undef, n)
    for i in 1:n
        @inbounds a[i] = Int8(i % 100)
    end
    for i in 1:n
        @inbounds b[i] = a[i]
    end
    return @inbounds b[1]
end

# F4 — non-scalar (struct/tuple) element type: no scalar element store/load.
function jfw6_vstruct(n::Int64)
    v = Vector{Tuple{Int8,Int8}}(undef, n)
    for i in 1:n
        @inbounds v[i] = (Int8(i % 100), Int8(0))
    end
    return @inbounds v[1][1]
end

@testset "Bennett-jfw6 mem=:vm Case A Vector/GenericMemory recognizer" begin

    @testset "SUCCESS — structural invariants" begin
        # S1: fused write + reduce.
        pir1 = Bennett.extract_parsed_ir(jfw6_vfused, Tuple{Int64}; optimize=false, mem=:vm)
        ins1 = _jfw6_allins(pir1)
        allocs1 = filter(i -> i isa Bennett.IRAlloca, ins1)
        @test length(pir1.blocks) >= 2                 # multi-block CFG (loop)
        @test length(allocs1) == 1                     # exactly one Memory alloca
        @test allocs1[1].n_elems isa Bennett.SSAOperand  # dynamic-N (runtime size)
        @test count(i -> i isa Bennett.IRVarGEP, ins1) >= 1
        @test count(i -> i isa Bennett.IRStore, ins1) >= 1
        @test count(i -> i isa Bennett.IRLoad, ins1) >= 1   # S1 reads v[i] back

        # S2: single write loop + scalar read.
        pir2 = Bennett.extract_parsed_ir(jfw6_vwrite1, Tuple{Int64}; optimize=false, mem=:vm)
        ins2 = _jfw6_allins(pir2)
        allocs2 = filter(i -> i isa Bennett.IRAlloca, ins2)
        @test length(pir2.blocks) >= 2
        @test length(allocs2) == 1
        @test allocs2[1].n_elems isa Bennett.SSAOperand
        @test count(i -> i isa Bennett.IRVarGEP, ins2) >= 1
        @test count(i -> i isa Bennett.IRStore, ins2) >= 1
    end

    @testset "FAIL-LOUD — out-of-Case-A shapes reject with a clear message" begin
        # F1 — two loops → ambiguous preheader.
        @test_throws Exception Bennett.extract_parsed_ir(jfw6_vtwo_loop, Tuple{Int64}; optimize=false, mem=:vm)
        m1 = _jfw6_failmsg(jfw6_vtwo_loop, Tuple{Int64})
        @test m1 !== nothing
        @test occursin("ambiguous loop preheader", m1)

        # F2 — while loop → not a `for i in 1:n` loop.
        @test_throws Exception Bennett.extract_parsed_ir(jfw6_vwhile, Tuple{Int64}; optimize=false, mem=:vm)
        m2 = _jfw6_failmsg(jfw6_vwhile, Tuple{Int64})
        @test m2 !== nothing
        @test occursin("for i in 1:n", m2)

        # F3 — two dynamic Vectors → SINGLE dynamic Vector backing only.
        @test_throws Exception Bennett.extract_parsed_ir(jfw6_vtwo_vec, Tuple{Int64}; optimize=false, mem=:vm)
        m3 = _jfw6_failmsg(jfw6_vtwo_vec, Tuple{Int64})
        @test m3 !== nothing
        @test occursin("SINGLE dynamic Vector", m3)

        # F4 — struct/tuple element type → no scalar element store/load.
        @test_throws Exception Bennett.extract_parsed_ir(jfw6_vstruct, Tuple{Int64}; optimize=false, mem=:vm)
        m4 = _jfw6_failmsg(jfw6_vstruct, Tuple{Int64})
        @test m4 !== nothing
        @test occursin("no element store/load", m4)
    end

end
