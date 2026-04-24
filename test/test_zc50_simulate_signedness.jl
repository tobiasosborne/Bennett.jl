using Test
using Bennett

# Bennett-zc50 / U100: simulate currently reinterprets every 8/16/32/64-bit
# output to Int8/16/32/64 (src/simulator.jl:115-118) and widens every tuple
# element to Int64 (src/simulator.jl:100). That's correct in bit pattern but
# wrong in declared type — users need `reinterpret(UInt64, simulate(...))`
# to recover their input's signedness.
#
# Fix: infer output signedness from the input argument types. All-unsigned
# inputs → unsigned outputs; mixed/all-signed → signed (current behavior,
# backward-compat). For tuple returns, each element keeps its declared width
# and inherits the input-derived signedness.

@testset "Bennett-zc50 / U100 simulate preserves signedness" begin

    @testset "single UInt input → UInt output (matching width)" begin
        c8  = reversible_compile(x -> x + UInt8(1),  UInt8)
        c16 = reversible_compile(x -> x + UInt16(1), UInt16)
        c32 = reversible_compile(x -> x + UInt32(1), UInt32)
        c64 = reversible_compile(x -> x + UInt64(1), UInt64)

        r8  = simulate(c8,  UInt8(250))
        r16 = simulate(c16, UInt16(0xFFFE))
        r32 = simulate(c32, UInt32(0xFFFFFFFE))
        r64 = simulate(c64, UInt64(0xFFFFFFFFFFFFFFFE))

        @test r8  === UInt8(251)
        @test r16 === UInt16(0xFFFF)
        @test r32 === UInt32(0xFFFFFFFF)
        @test r64 === UInt64(0xFFFFFFFFFFFFFFFF)
    end

    @testset "single Int input → Int output (regression, no change)" begin
        c8  = reversible_compile(x -> x + Int8(1),  Int8)
        c16 = reversible_compile(x -> x + Int16(1), Int16)
        c32 = reversible_compile(x -> x + Int32(1), Int32)
        c64 = reversible_compile(x -> x + Int64(1), Int64)

        @test simulate(c8,  Int8(-1))   === Int8(0)
        @test simulate(c16, Int16(-1))  === Int16(0)
        @test simulate(c32, Int32(-1))  === Int32(0)
        @test simulate(c64, Int64(-1))  === Int64(0)
    end

    @testset "tuple return keeps element widths; signedness from input" begin
        # Homogeneous Int8 inputs, tuple of Int8 outputs.
        f_ii(x::Int8, y::Int8) = (x + Int8(1), y + Int8(1))
        c_ii = reversible_compile(f_ii, Int8, Int8)
        r_ii = simulate(c_ii, (Int8(10), Int8(20)))
        @test r_ii === (Int8(11), Int8(21))

        # Homogeneous UInt16 inputs, tuple of UInt16 outputs.
        f_uu(x::UInt16, y::UInt16) = (x + UInt16(1), y + UInt16(1))
        c_uu = reversible_compile(f_uu, UInt16, UInt16)
        r_uu = simulate(c_uu, (UInt16(0xFFFE), UInt16(0x1000)))
        @test r_uu === (UInt16(0xFFFF), UInt16(0x1001))
    end

    @testset "simulate(c, single_integer) form also preserves signedness" begin
        # Covers the `simulate(c, ::Integer)` overload (simulator.jl:28-31)
        # in addition to the tuple form.
        c = reversible_compile(x -> x + UInt32(1), UInt32)
        r = simulate(c, UInt32(0xFFFFFFFE))
        @test r === UInt32(0xFFFFFFFF)
    end

    @testset "mixed signedness inputs default to signed (conservative)" begin
        # Documents the deliberate choice: we don't guess when inputs disagree.
        f(x::Int32, y::UInt32) = x + reinterpret(Int32, y)
        c = reversible_compile(f, Int32, UInt32)
        r = simulate(c, (Int32(1), UInt32(2)))
        @test r isa Signed
        @test r == 3
    end
end
