@testset "Bennett-salb / U119 — divide-by-zero + signed overflow contract" begin

    @testset "Public soft_udiv throws DivideError on b=0" begin
        for a in (UInt64(0), UInt64(1), UInt64(5), UInt64(0xff),
                  typemax(UInt64), UInt64(0x8000000000000000))
            @test_throws DivideError Bennett.soft_udiv(a, UInt64(0))
        end
    end

    @testset "Public soft_urem throws DivideError on b=0" begin
        for a in (UInt64(0), UInt64(1), UInt64(5), UInt64(0xff),
                  typemax(UInt64), UInt64(0x8000000000000000))
            @test_throws DivideError Bennett.soft_urem(a, UInt64(0))
        end
    end

    @testset "Public soft_udiv / soft_urem still correct on b != 0" begin
        for a in (UInt64(0), UInt64(1), UInt64(7), UInt64(255),
                  typemax(UInt64), UInt64(123456789))
            for b in (UInt64(1), UInt64(2), UInt64(3), UInt64(7), UInt64(255),
                      typemax(UInt64))
                @test Bennett.soft_udiv(a, b) == div(a, b)
                @test Bennett.soft_urem(a, b) == rem(a, b)
            end
        end
    end

    @testset "Private _compile callees: b=0 contract (LLVM-poison-equivalent)" begin
        # The compile-time callee is branchless and must NOT throw, since its
        # LLVM IR is inlined into circuits via lower_call!. On b=0 the documented
        # result is deterministic-but-unspecified (poison-equivalent).
        for a in (UInt64(0), UInt64(1), UInt64(5), UInt64(0xff), typemax(UInt64))
            @test Bennett._soft_udiv_compile(a, UInt64(0)) == typemax(UInt64)
            @test Bennett._soft_urem_compile(a, UInt64(0)) == a
        end
    end

    @testset "Private _compile callees: b != 0 matches Base" begin
        for a in (UInt64(0), UInt64(7), UInt64(255), UInt64(123456789))
            for b in (UInt64(1), UInt64(2), UInt64(7), UInt64(255), typemax(UInt64))
                @test Bennett._soft_udiv_compile(a, b) == div(a, b)
                @test Bennett._soft_urem_compile(a, b) == rem(a, b)
            end
        end
    end

    @testset "Compiled circuit: b=0 produces documented poison-equivalent" begin
        # Variable divisor — divisor 0 is only revealed at simulate time, so
        # lower_divrem! IS exercised. The result must be deterministic to
        # qualify as poison-equivalent (per LLVM LangRef: poison is undef but
        # not random).
        fu(x::UInt8, y::UInt8) = x ÷ y
        cu = reversible_compile(fu, Tuple{UInt8, UInt8})
        for a in (UInt8(0), UInt8(1), UInt8(7), UInt8(255))
            r = simulate(cu, UInt8, (a, UInt8(0)))
            @test r == typemax(UInt8)  # documented: typemax on b=0
        end
        @test verify_reversibility(cu)

        fr(x::UInt8, y::UInt8) = x % y
        cr = reversible_compile(fr, Tuple{UInt8, UInt8})
        for a in (UInt8(0), UInt8(1), UInt8(7), UInt8(255))
            r = simulate(cr, UInt8, (a, UInt8(0)))
            @test r == a  # documented: dividend on b=0
        end
        @test verify_reversibility(cr)
    end

    @testset "Compiled circuit: signed typemin ÷ -1 wraps to typemin (poison-equivalent)" begin
        # LLVM LangRef: sdiv typemin -1 is poison. Our compiled circuit
        # produces the wrap result (typemin) — deterministic, documented.
        fs(x::Int8, y::Int8) = x ÷ y
        cs = reversible_compile(fs, Tuple{Int8, Int8})
        @test Int8(simulate(cs, Int8, (typemin(Int8), Int8(-1)))) == typemin(Int8)
        @test verify_reversibility(cs)
    end
end
