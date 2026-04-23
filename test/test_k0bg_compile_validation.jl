using Test
using Bennett

# Bennett-k0bg / U25 — `reversible_compile` silently accepted garbage
# kwargs (`bit_width=-5` produced a 26-wire circuit returning 1 on
# input 0; `bit_width=200` on Int8 silently accepted and produced a
# 602-wire circuit; `max_loop_iterations=-1` silently accepted).
# Non-integer types and unsupported types reached internals and
# produced LLVM-internal error messages.
#
# Post-fix: up-front `ArgumentError` naming the offending kwarg or type.

f1(x::Int8) = x + Int8(1)

@testset "Bennett-k0bg reversible_compile validation" begin

    # T1 — bit_width must be 0 (infer) or in [1, 64]. Narrow widths
    # like 2 and 4 are legal (exercised by test_narrow.jl); the old
    # catalogue fix was tighter but test_narrow broke — we relax to the
    # full positive range.
    @test_throws ArgumentError reversible_compile(f1, Int8; bit_width=-5)
    @test_throws ArgumentError reversible_compile(f1, Int8; bit_width=200)
    @test_throws ArgumentError reversible_compile(f1, Int8; bit_width=65)
    # Valid values still work:
    @test reversible_compile(f1, Int8; bit_width=0)  !== nothing
    @test reversible_compile(f1, Int8; bit_width=4)  !== nothing   # test_narrow uses this
    @test reversible_compile(f1, Int8; bit_width=8)  !== nothing
    @test reversible_compile(f1, Int8; bit_width=16) !== nothing

    # T2 — max_loop_iterations must be non-negative.
    @test_throws ArgumentError reversible_compile(f1, Int8; max_loop_iterations=-1)
    @test_throws ArgumentError reversible_compile(f1, Int8; max_loop_iterations=-100)
    @test reversible_compile(f1, Int8; max_loop_iterations=0)  !== nothing
    @test reversible_compile(f1, Int8; max_loop_iterations=10) !== nothing

    # T3 — unsupported scalar types raise up front.
    @test_throws ArgumentError reversible_compile(f1, Float32)   # not Float64
    @test_throws ArgumentError reversible_compile(f1, BigInt)    # not a sized integer
    @test_throws ArgumentError reversible_compile(f1, String)    # not a number

    # T4 — known-good types still compile (with matching function sigs):
    @test reversible_compile((x::Int8)  -> x + Int8(1),   Int8)   !== nothing
    @test reversible_compile((x::UInt8) -> x + UInt8(1),  UInt8)  !== nothing
    @test reversible_compile((x::Int16) -> x + Int16(1),  Int16)  !== nothing
    @test reversible_compile((x::Int32) -> x + Int32(1),  Int32)  !== nothing
    @test reversible_compile((x::Int64) -> x + Int64(1),  Int64)  !== nothing

    # T5 — NTuple{N, T} where T is a supported scalar is accepted.
    proc3(t::NTuple{3, Int8}) = t[1] + t[2] + t[3]
    @test reversible_compile(proc3, Tuple{NTuple{3, Int8}}) !== nothing
end
