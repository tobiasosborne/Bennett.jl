# Bennett-sr8v: durable src-side memoisation for reversible_compile(::ParsedIR).
# Companion to Bennett-hybr (test-side parse/compile hoisting); this caches
# the final ReversibleCircuit keyed on (objectid(parsed), all 10 kwargs).
#
# The cache reuses the existing _extract_parsed_ir_cached pattern from
# src/extract/callees.jl (Dict + ReentrantLock, check-then-populate inside
# the lock). See CLAUDE.md §3 (red-green TDD), §8 (fast feedback).

using Test
using Bennett

@testset "Bennett-sr8v: reversible_compile(::ParsedIR) cache" begin

    # Bennett-1eyg: testsets 1-3 use the tiny x+1 Int8 ParsedIR (58-gate
    # circuit, CLAUDE.md §6 baseline) rather than the 2.4M-gate eq9p_acosh
    # fixture used originally. Cache identity is circuit-size-independent;
    # the heavy fixture cost 270s in the full suite for tests that only
    # need to prove `c1 === c2`.
    Bennett._clear_parsed_ir_cache!()
    _f_tiny = x -> x + Int8(1)
    _parsed = Bennett._extract_parsed_ir_cached(_f_tiny, Tuple{Int8})

    @testset "identity hit returns ===-same circuit" begin
        Bennett._clear_compile_cache!()
        c1 = reversible_compile(_parsed)
        c2 = reversible_compile(_parsed)
        @test c1 === c2
        # Defense-in-depth: cached circuit must still verify and match the
        # pinned baseline — guards against caching a wrong/empty result.
        @test verify_reversibility(c1)
        # CLAUDE.md §6 pinned baseline: i8 x+1 = 58 gates (add=:ripple, fold_constants=true).
        @test gate_count(c1).total == 58
    end

    @testset "different kwargs bust cache" begin
        Bennett._clear_compile_cache!()
        c1 = reversible_compile(_parsed; fold_constants=true)
        c2 = reversible_compile(_parsed; fold_constants=false)
        @test c1 !== c2
        @test verify_reversibility(c1)
        @test verify_reversibility(c2)
    end

    @testset "_clear_compile_cache! resets" begin
        Bennett._clear_compile_cache!()
        c1 = reversible_compile(_parsed)
        Bennett._clear_compile_cache!()
        c2 = reversible_compile(_parsed)
        @test c1 !== c2
        @test verify_reversibility(c1)
        @test verify_reversibility(c2)
    end

    @testset "(f, types) → ParsedIR → reversible_compile path hits sr8v" begin
        # The top-level `reversible_compile(f, types)` overload calls
        # `extract_parsed_ir` directly (NOT `_extract_parsed_ir_cached`)
        # at src/Bennett.jl:355, so back-to-back compiles produce
        # different ParsedIR objectids and miss sr8v at the top level.
        # The cached path is `_extract_parsed_ir_cached` (used internally
        # by callee lowering at src/lowering/call.jl:82): callers who
        # explicitly route through it AND the ParsedIR overload do
        # benefit from sr8v across compiles.
        Bennett._clear_compile_cache!()
        Bennett._clear_parsed_ir_cache!()
        f = x -> x + Int8(1)
        parsed1 = Bennett._extract_parsed_ir_cached(f, Tuple{Int8})
        parsed2 = Bennett._extract_parsed_ir_cached(f, Tuple{Int8})
        @test parsed1 === parsed2  # parsed-IR cache identity invariant
        c1 = reversible_compile(parsed1)
        c2 = reversible_compile(parsed2)
        @test c1 === c2
        @test verify_reversibility(c1)
        # Pinned baseline from CLAUDE.md §6: i8 `x+1` = 58 gates
        # (add=:ripple, fold_constants=true). Defaults match :auto → :ripple
        # for narrow widths, so 58 is the expected count.
        @test gate_count(c1).total == 58
    end

end
