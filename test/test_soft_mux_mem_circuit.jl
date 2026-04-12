using Test
using Bennett
using Bennett: soft_mux_store_4x8, soft_mux_load_4x8

# Gate-level compilation tests for the T1b memory callees.
# Compiles each through the full Bennett pipeline and verifies:
# - reversibility (ancillae return to zero)
# - bit-exact correctness across representative inputs

@testset "T1b.2 soft_mux_store/load compile to reversible circuits" begin

    @testset "soft_mux_load_4x8 gate-level" begin
        c = reversible_compile(soft_mux_load_4x8, UInt64, UInt64)
        @test verify_reversibility(c)
        println("  soft_mux_load_4x8:  $(gate_count(c).total) gates, $(c.n_wires) wires")

        # Correctness across all 4 slot indices, with a few array states
        for arr in (UInt64(0x87654321), UInt64(0x00000000), UInt64(0xffffffff),
                    UInt64(0xaabbccdd))
            for idx in UInt64(0):UInt64(3)
                expected = soft_mux_load_4x8(arr, idx)
                got = simulate(c, (arr, idx))
                @test got == expected
            end
        end
    end

    @testset "soft_mux_store_4x8 gate-level" begin
        c = reversible_compile(soft_mux_store_4x8, UInt64, UInt64, UInt64)
        @test verify_reversibility(c)
        println("  soft_mux_store_4x8: $(gate_count(c).total) gates, $(c.n_wires) wires")

        # Correctness across all 4 slot indices and a range of (arr, val) states
        for arr in (UInt64(0x00000000), UInt64(0xaabbccdd))
            for idx in UInt64(0):UInt64(3)
                for val in (UInt64(0x00), UInt64(0x55), UInt64(0xff), UInt64(0x42))
                    expected = soft_mux_store_4x8(arr, idx, val)
                    got = simulate(c, (arr, idx, val))
                    @test got == expected
                end
            end
        end
    end

    @testset "both are registered as callees (for T1b.3 dispatch)" begin
        # _lookup_callee should find them by name
        @test Bennett._lookup_callee("soft_mux_store_4x8") === soft_mux_store_4x8
        @test Bennett._lookup_callee("soft_mux_load_4x8")  === soft_mux_load_4x8
        # Also findable via julia-mangled name pattern
        @test Bennett._lookup_callee("julia_soft_mux_store_4x8_1") === soft_mux_store_4x8
        @test Bennett._lookup_callee("julia_soft_mux_load_4x8_99") === soft_mux_load_4x8
    end
end
