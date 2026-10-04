using Test, Bennett
@testset "Variable-index GEP (dynamic array access)" begin

    # ================================================================
    # Test 1: NTuple{4,Int8} dynamic access compiles and is correct
    # ================================================================
    @testset "dynamic NTuple{4} access" begin
        function get_elem(arr::NTuple{4,Int8}, idx::Int8)
            return arr[idx]
        end

        circuit = reversible_compile(get_elem, NTuple{4,Int8}, Int8)
        @test verify_reversibility(circuit)

        gc = gate_count(circuit)
        println("  NTuple{4} dynamic access: $(gc.total) gates, $(gc.Toffoli) Toffoli, $(circuit.n_wires) wires")

        # Pack NTuple{4,Int8} as a single UInt32 (little-endian byte packing)
        function pack_ntuple(arr::NTuple{4,Int8})
            v = UInt32(0)
            for i in 1:4
                v |= UInt32(reinterpret(UInt8, arr[i])) << (8*(i-1))
            end
            return v
        end

        # Test all valid indices with various array contents
        arr = (Int8(10), Int8(20), Int8(30), Int8(40))
        for idx in Int8(1):Int8(4)
            packed = pack_ntuple(arr)
            result = simulate(circuit, (packed, idx))
            @test result == get_elem(arr, idx)
        end

        # Different array contents
        arr2 = (Int8(-1), Int8(0), Int8(127), Int8(-128))
        for idx in Int8(1):Int8(4)
            packed = pack_ntuple(arr2)
            result = simulate(circuit, (packed, idx))
            @test result == get_elem(arr2, idx)
        end
    end
end
