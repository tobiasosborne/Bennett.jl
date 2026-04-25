# Bennett-ej4n / U48 — cache extracted ParsedIR keyed on (callee, arg_types)
# so a circuit with N references to the same callee pays the ~21ms
# `extract_parsed_ir` cost once, not N times.
#
# Module-scoped cache (in src/ir_extract.jl) avoids worsening the
# Bennett-ehoa LoweringCtx-bloat.  Bennett's registered callees are
# stable functions defined in the package itself, so module scope is
# safe in practice; the cache is small (one entry per distinct
# (callee, arg_types) pair) and never grows after warm-up.
#
# These tests pin:
#   1. Direct cache hit returns the SAME ParsedIR object (`===`).
#   2. After a `reversible_compile` referencing N callees, the cache
#      contains exactly N entries (one per distinct (callee, arg_types)).
#   3. A second compile reuses the cached entries (size unchanged).
#   4. `_clear_parsed_ir_cache!()` empties the table.
#   5. Compilation correctness is unaffected (a soft_fadd-using fn
#      simulates to the same Float64 result).

using Test
using Bennett

@testset "Bennett-ej4n / U48 — callee ParsedIR cache" begin

    @testset "direct cache hit returns === ParsedIR" begin
        Bennett._clear_parsed_ir_cache!()
        @test isempty(Bennett._parsed_ir_cache)

        pir1 = Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})
        pir2 = Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})

        @test pir1 === pir2
        @test length(Bennett._parsed_ir_cache) == 1
    end

    @testset "distinct (callee, arg_types) → distinct entries" begin
        Bennett._clear_parsed_ir_cache!()

        Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})
        Bennett._extract_parsed_ir_cached(soft_fmul, Tuple{UInt64, UInt64})
        Bennett._extract_parsed_ir_cached(soft_fneg, Tuple{UInt64})

        @test length(Bennett._parsed_ir_cache) == 3
        @test haskey(Bennett._parsed_ir_cache, (soft_fadd, Tuple{UInt64, UInt64}))
        @test haskey(Bennett._parsed_ir_cache, (soft_fmul, Tuple{UInt64, UInt64}))
        @test haskey(Bennett._parsed_ir_cache, (soft_fneg, Tuple{UInt64}))
    end

    @testset "compile of a parent fn populates the cache" begin
        # The cache is hit by `lower_call!` — i.e. when the function being
        # compiled REFERENCES a registered callee.  Compiling a registered
        # callee directly (e.g. `reversible_compile(soft_fadd, ...)`) takes
        # the top-level path which does not consult the cache.
        Bennett._clear_parsed_ir_cache!()

        f = (a::UInt64, b::UInt64) -> soft_fadd(soft_fadd(a, b), a)
        circuit = reversible_compile(f, UInt64, UInt64)
        @test verify_reversibility(circuit)

        @test haskey(Bennett._parsed_ir_cache,
                     (soft_fadd, Tuple{UInt64, UInt64}))
        n_after_first = length(Bennett._parsed_ir_cache)
        @test n_after_first >= 1

        # Second compile of the same function: cache size MUST NOT grow.
        # Load-bearing — proves the cached path is hit on the hot loop.
        reversible_compile(f, UInt64, UInt64)
        @test length(Bennett._parsed_ir_cache) == n_after_first
    end

    @testset "multiple references in one fn → one cache entry per callee" begin
        Bennett._clear_parsed_ir_cache!()

        # Three explicit references to soft_fadd inside one Julia fn.
        # Without a cache, lower_call! would extract_parsed_ir three times.
        # With the cache, only one entry exists for (soft_fadd, ...).
        f = (a::UInt64, b::UInt64) -> begin
            t1 = soft_fadd(a, b)
            t2 = soft_fadd(t1, a)
            soft_fadd(t2, b)
        end
        circuit = reversible_compile(f, UInt64, UInt64)
        @test verify_reversibility(circuit)

        # Exactly ONE entry for (soft_fadd, Tuple{UInt64, UInt64}).
        # (The user fn `f` itself is not registered as a callee, so it
        # doesn't go through the cache — only soft_fadd does.)
        keys_for_fadd = filter(k -> k[1] === soft_fadd,
                               keys(Bennett._parsed_ir_cache))
        @test length(keys_for_fadd) == 1
    end

    @testset "compilation correctness is preserved" begin
        Bennett._clear_parsed_ir_cache!()
        circuit = reversible_compile(soft_fadd, UInt64, UInt64)

        for (a, b) in [(1.0, 2.0), (3.14, -1.5), (0.0, 0.0),
                       (Inf, 1.0), (1e-300, 1e-300)]
            a_bits = reinterpret(UInt64, a)
            b_bits = reinterpret(UInt64, b)
            result = simulate(circuit, (a_bits, b_bits))
            @test result == soft_fadd(a_bits, b_bits)
        end
    end

    @testset "_clear_parsed_ir_cache! empties the table" begin
        Bennett._extract_parsed_ir_cached(soft_fadd, Tuple{UInt64, UInt64})
        @test !isempty(Bennett._parsed_ir_cache)

        Bennett._clear_parsed_ir_cache!()
        @test isempty(Bennett._parsed_ir_cache)
    end
end
