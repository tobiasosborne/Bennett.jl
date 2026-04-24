using Test
using Bennett

@testset "Per-callee Bennett construction (compact_calls)" begin
    @testset "compact_calls correctness for Float64 polynomial" begin
        # x^2 + 3x + 1 uses 2 fmul + 2 fadd = 4 callee calls
        f(x) = x * x + 3.0 * x + 1.0

        c_default = reversible_compile(f, Float64)
        c_compact = reversible_compile(f, Float64; compact_calls=true)

        # Both must produce correct results
        for x in [0.0, 1.0, -1.0, 2.0, 3.14, 0.5]
            bits = reinterpret(UInt64, x)
            @test simulate(c_default, bits) == simulate(c_compact, bits)
        end
        @test verify_reversibility(c_default)
        @test verify_reversibility(c_compact)

        gc_default = gate_count(c_default)
        gc_compact = gate_count(c_compact)
        println("  Float64 poly: default gates=$(gc_default.total) wires=$(c_default.n_wires), compact gates=$(gc_compact.total) wires=$(c_compact.n_wires)")

        # Compact should have more gates (callee gates doubled per call)
        @test gc_compact.total > gc_default.total
    end

    @testset "compact_calls produces valid circuit for simple addition" begin
        f(x) = x + 1.0
        c = reversible_compile(f, Float64; compact_calls=true)
        bits = reinterpret(UInt64, 2.0)
        # Bennett-zc50 / U100: simulate preserves signedness; UInt64 in → UInt64 out.
        result = reinterpret(Float64, simulate(c, bits))
        @test result == 3.0
        @test verify_reversibility(c)
    end
end
