using Test
using Bennett
using Bennett: soft_mux_store_4x8, soft_mux_load_4x8,
               soft_mux_store_8x8, soft_mux_load_8x8

@testset "T1b.5 scaling for soft_mux_*_NxW" begin

    @testset "soft_mux_store_8x8 / soft_mux_load_8x8 pure Julia" begin
        # Exhaustive: 8 indices × full byte values on representative arr seeds.
        for arr in (UInt64(0), UInt64(0x0123456789abcdef), ~UInt64(0))
            for idx in UInt64(0):UInt64(7)
                # Load
                expected_slot = UInt64((arr >> (idx*8)) & 0xff)
                @test soft_mux_load_8x8(arr, idx) == expected_slot

                # Store + load round-trip
                for val in (UInt64(0), UInt64(0x7f), UInt64(0xff), UInt64(0xaa))
                    new_arr = soft_mux_store_8x8(arr, idx, val)
                    @test soft_mux_load_8x8(new_arr, idx) == (val & 0xff)
                end
            end
        end
    end

    @testset "N=8 store preserves other slots" begin
        arr = UInt64(0x0123456789abcdef)
        for idx in UInt64(0):UInt64(7)
            new_arr = soft_mux_store_8x8(arr, idx, UInt64(0))
            # All other slots unchanged
            for k in 0:7
                if UInt64(k) == idx
                    @test ((new_arr >> (k*8)) & 0xff) == 0
                else
                    @test ((new_arr >> (k*8)) & 0xff) == ((arr >> (k*8)) & 0xff)
                end
            end
        end
    end

    @testset "gate-level scaling: N=4 vs N=8" begin
        # U28 / Bennett-epwy: the scaling measurement is pre-fold. With
        # fold_constants=true (the new default) the N=8 load collapses
        # more aggressively than N=4 (more constant MUX-tree indices fold
        # into CNOTs), inverting the `g4 < g8` invariant by a narrow
        # margin (2409 vs 2364). Pin the compile step to `fold_constants=
        # false` so this test measures raw lowered-gate scaling of the
        # soft_mux_* primitives, which is what it was written to check.
        mk(f, types) = begin
            parsed = Bennett.extract_parsed_ir(f, Tuple{types...})
            Bennett.bennett(Bennett.lower(parsed; fold_constants=false))
        end
        c4_load  = mk(soft_mux_load_4x8,  (UInt64, UInt64))
        c8_load  = mk(soft_mux_load_8x8,  (UInt64, UInt64))
        c4_store = mk(soft_mux_store_4x8, (UInt64, UInt64, UInt64))
        c8_store = mk(soft_mux_store_8x8, (UInt64, UInt64, UInt64))

        g4_load  = gate_count(c4_load).total
        g8_load  = gate_count(c8_load).total
        g4_store = gate_count(c4_store).total
        g8_store = gate_count(c8_store).total

        println("  Scaling table (N=elements, W=8 bits per elem):")
        println("  N=4 load:  $(g4_load) gates, $(c4_load.n_wires) wires")
        println("  N=8 load:  $(g8_load) gates, $(c8_load.n_wires) wires")
        println("  N=4 store: $(g4_store) gates, $(c4_store.n_wires) wires")
        println("  N=8 store: $(g8_store) gates, $(c8_store.n_wires) wires")
        println("  Load scaling factor  (8/4): $(round(g8_load / g4_load, digits=2))")
        println("  Store scaling factor (8/4): $(round(g8_store / g4_store, digits=2))")

        # N=8 should be larger than N=4 (more slots to handle) but within
        # ~3× of N=4 (O(N·W) nominal — the 64-bit ABI constant is dominant).
        @test g4_load < g8_load
        @test g4_store < g8_store
        @test g8_load < 3 * g4_load
        @test g8_store < 3 * g4_store

        # Reversibility maintained at both scales
        @test verify_reversibility(c4_load)
        @test verify_reversibility(c8_load)
        @test verify_reversibility(c4_store)
        @test verify_reversibility(c8_store)
    end

    @testset "circuit correctness for N=8" begin
        c = reversible_compile(soft_mux_load_8x8, UInt64, UInt64)
        arr = UInt64(0x1122334455667788)  # slots 0x88, 0x77, ..., 0x11
        for idx in UInt64(0):UInt64(7)
            expected = soft_mux_load_8x8(arr, idx)
            @test simulate(c, (arr, idx)) == expected
        end
    end
end
