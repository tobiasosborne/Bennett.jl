@testset "LLVM intrinsics coverage" begin

    @testset "ctpop (count_ones)" begin
        popcount8(x::Int8) = Int8(count_ones(x))
        c = reversible_compile(popcount8, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == Int8(count_ones(x))
        end
        @test verify_reversibility(c)
        println("  ctpop i8: $(gate_count(c).total) gates")
    end

    @testset "ctlz (leading_zeros)" begin
        clz8(x::Int8) = Int8(leading_zeros(x))
        c = reversible_compile(clz8, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == Int8(leading_zeros(x))
        end
        @test verify_reversibility(c)
        println("  ctlz i8: $(gate_count(c).total) gates")
    end

    @testset "cttz (trailing_zeros)" begin
        ctz8(x::Int8) = Int8(trailing_zeros(x))
        c = reversible_compile(ctz8, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == Int8(trailing_zeros(x))
        end
        @test verify_reversibility(c)
        println("  cttz i8: $(gate_count(c).total) gates")
    end

    @testset "bitreverse" begin
        bitrev8(x::Int8) = bitreverse(x)
        c = reversible_compile(bitrev8, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == bitreverse(x)
        end
        @test verify_reversibility(c)
        println("  bitreverse i8: $(gate_count(c).total) gates")
    end

    @testset "bswap (Int16)" begin
        bswap16(x::Int16) = bswap(x)
        c = reversible_compile(bswap16, Int16)
        for x in Int16(-100):Int16(100)
            @test Int16(simulate(c, x)) == bswap(x)
        end
        @test verify_reversibility(c)
        println("  bswap i16: $(gate_count(c).total) gates")
    end

    @testset "fneg (Float64 negation opcode)" begin
        # fneg is an LLVM opcode, not an intrinsic. Test via UInt64 bit patterns.
        neg_f64(x::UInt64) = reinterpret(UInt64, -reinterpret(Float64, x))
        c = reversible_compile(neg_f64, UInt64)
        for x in [1.0, -1.0, 0.0, -0.0, 3.14, Inf, -Inf]
            xb = reinterpret(UInt64, x)
            result = reinterpret(UInt64, simulate(c, xb))
            @test result == reinterpret(UInt64, -x)
        end
        @test verify_reversibility(c)
        println("  fneg via reinterpret: $(gate_count(c).total) gates")
    end

    @testset "bitcast (Float64 ↔ UInt64)" begin
        # reinterpret(UInt64, reinterpret(Float64, x)) == x — pure identity via two bitcasts
        roundtrip(x::UInt64) = reinterpret(UInt64, reinterpret(Float64, x))
        c = reversible_compile(roundtrip, UInt64)
        for x in UInt64[0, 1, 0x3ff0000000000000, 0x7ff0000000000000, 0xffffffffffffffff]
            @test reinterpret(UInt64, simulate(c, x)) == x
        end
        @test verify_reversibility(c)
        println("  bitcast roundtrip: $(gate_count(c).total) gates")
    end

    @testset "llvm.fabs (float absolute value)" begin
        # abs(Float64) emits @llvm.fabs.f64 — clear sign bit
        fabs_bits(x::UInt64) = reinterpret(UInt64, abs(reinterpret(Float64, x)))
        c = reversible_compile(fabs_bits, UInt64)
        for x in [1.0, -1.0, 0.0, -0.0, 3.14, -3.14, Inf, -Inf]
            xb = reinterpret(UInt64, x)
            result = reinterpret(UInt64, simulate(c, xb))
            @test result == reinterpret(UInt64, abs(x))
        end
        @test verify_reversibility(c)
        println("  fabs: $(gate_count(c).total) gates")
    end

    @testset "fcmp ole (Float64 <=)" begin
        f_le(x::Float64, y::Float64) = x <= y
        c = reversible_compile(f_le, Tuple{Float64, Float64})
        for (a, b, expected) in [(1.0, 2.0, true), (2.0, 1.0, false), (1.0, 1.0, true),
                                  (-1.0, 0.0, true), (0.0, -0.0, true), (NaN, 1.0, false)]
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            result = simulate(c, (ab, bb))
            @test (result != 0) == expected
        end
        @test verify_reversibility(c)
        println("  fcmp ole: $(gate_count(c).total) gates")
    end

    @testset "fcmp une (Float64 !=)" begin
        f_ne(x::Float64, y::Float64) = x != y
        c = reversible_compile(f_ne, Tuple{Float64, Float64})
        for (a, b, expected) in [(1.0, 2.0, true), (1.0, 1.0, false), (0.0, -0.0, false),
                                  (NaN, 1.0, true), (NaN, NaN, true)]
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            result = simulate(c, (ab, bb))
            @test (result != 0) == expected
        end
        @test verify_reversibility(c)
        println("  fcmp une: $(gate_count(c).total) gates")
    end

    @testset "fptosi (Float64 → Int64 via soft_fptosi)" begin
        # unsafe_trunc emits fptosi double to i64. Compile with Tuple{Float64}
        # to get direct Float64 param (not SoftFloat wrapped).
        float_to_int(x::Float64) = unsafe_trunc(Int64, x)
        c = reversible_compile(float_to_int, Tuple{Float64})
        for x in [0.0, 1.0, 2.0, 3.0, -1.0, -5.0, 100.0, -100.0,
                  0.5, 0.99, -0.5, 1e10, -1e10]
            xb = reinterpret(UInt64, x)
            # Bennett-zc50 / U100: simulate sees input_widths == output_widths
            # == 64 and all-UInt64 inputs → infers unsigned output. The
            # function's declared return is Int64, so normalize via `% Int64`
            # (same pattern as test_b1vp_fptoui.jl:71).
            result = simulate(c, xb) % Int64
            expected = unsafe_trunc(Int64, x)
            @test result == expected
        end
        @test verify_reversibility(c)
        println("  fptosi: $(gate_count(c).total) gates")
    end
end
