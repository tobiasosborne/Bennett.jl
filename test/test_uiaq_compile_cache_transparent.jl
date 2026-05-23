# Bennett-uiaq: route reversible_compile(f, T) through _extract_parsed_ir_cached
# so back-to-back compiles auto-hit the Bennett-sr8v compile cache.
#
# Before uiaq: the (f, arg_types) overload at src/Bennett.jl:355 called
# `extract_parsed_ir(f, arg_types; optimize, mem)` directly. Each call
# produced a fresh ParsedIR with a different objectid, so the sr8v cache
# (keyed on objectid(parsed)) MISSED on every repeat call.
#
# After uiaq: that line routes through `_extract_parsed_ir_cached`, which
# also keys on `optimize` and `mem` so different extraction kwargs do
# not collide. Result: `reversible_compile(g, Int8)` twice returns
# `===`-identical ReversibleCircuit objects (sr8v hit).
#
# Red-green TDD per CLAUDE.md §3: tests written first.

using Test
using Bennett

@testset "Bennett-uiaq: reversible_compile(f, T) transparent caching" begin

    @testset "reversible_compile(f, T) hits sr8v on repeat call" begin
        Bennett._clear_compile_cache!()
        Bennett._clear_parsed_ir_cache!()
        g(x::Int8) = x + Int8(1)
        c1 = reversible_compile(g, Int8)
        c2 = reversible_compile(g, Int8)
        @test c1 === c2
        # Pinned baseline from CLAUDE.md §6: i8 `x+1` = 58 gates
        # (add=:ripple, fold_constants=true). Defaults match.
        @test gate_count(c1).total == 58
        @test verify_reversibility(c1)
    end

    @testset "different optimize busts cache" begin
        Bennett._clear_compile_cache!()
        Bennett._clear_parsed_ir_cache!()
        g(x::Int8) = x + Int8(1)
        c1 = reversible_compile(g, Int8)                       # optimize=true default
        c2 = reversible_compile(g, Int8; optimize=false)
        @test c1 !== c2
        @test verify_reversibility(c1)
        @test verify_reversibility(c2)
    end

    @testset "different mem busts cache" begin
        Bennett._clear_compile_cache!()
        Bennett._clear_parsed_ir_cache!()
        g(x::Int8) = x + Int8(1)
        c1 = reversible_compile(g, Int8)                       # mem=:auto default
        c2 = reversible_compile(g, Int8; mem=:auto)            # explicit :auto = default
        @test c1 === c2                                        # same-default hit
        # :heap is a distinct extraction-phase flag — must produce a
        # different ParsedIR objectid and therefore a fresh circuit.
        c3 = reversible_compile(g, Int8; mem=:heap)
        @test c3 !== c1
        @test verify_reversibility(c1)
        @test verify_reversibility(c3)
    end

    @testset "_clear_compile_cache! still busts properly" begin
        Bennett._clear_compile_cache!()
        Bennett._clear_parsed_ir_cache!()
        g(x::Int8) = x + Int8(1)
        c1 = reversible_compile(g, Int8)
        Bennett._clear_compile_cache!()
        c2 = reversible_compile(g, Int8)
        @test c1 !== c2
        @test verify_reversibility(c1)
        @test verify_reversibility(c2)
    end

    @testset "_extract_parsed_ir_cached backward-compat: positional, no kwargs" begin
        # Matches the call shape at src/lowering/call.jl:82:
        #   _extract_parsed_ir_cached(inst.callee, arg_types)
        # i.e. no kwargs — must still memoise on (f, arg_types) with the
        # new default optimize=true, mem=:auto.
        Bennett._clear_parsed_ir_cache!()
        pir1 = Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})
        pir2 = Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})
        @test pir1 === pir2
    end

end
