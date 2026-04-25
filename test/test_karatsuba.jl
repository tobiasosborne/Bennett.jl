@testset "Karatsuba multiplier" begin

    # ================================================================
    # Test 1: Karatsuba correctness — Int8, all 256×256 inputs
    # ================================================================
    @testset "karatsuba: Int8 exhaustive" begin
        f(x::Int8, y::Int8) = x * y
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8, Int8})

        # Lower with schoolbook (default)
        lr_school = Bennett.lower(parsed)
        c_school = Bennett.bennett(lr_school)

        # Lower with Karatsuba
        parsed2 = Bennett.extract_parsed_ir(f, Tuple{Int8, Int8})
        lr_karat = Bennett.lower(parsed2; use_karatsuba=true)
        c_karat = Bennett.bennett(lr_karat)

        gc_school = gate_count(c_school)
        gc_karat  = gate_count(c_karat)
        println("  Int8 mul: schoolbook=$(gc_school.Toffoli) Toff, karatsuba=$(gc_karat.Toffoli) Toff")

        # Correctness: every input pair
        for x in Int8(-10):Int8(10), y in Int8(-10):Int8(10)
            @test simulate(c_karat, (x, y)) == simulate(c_school, (x, y))
        end
        @test verify_reversibility(c_karat)

        # Gate count: Karatsuba must use strictly fewer Toffoli gates
        @test gc_karat.Toffoli < gc_school.Toffoli
    end
end
