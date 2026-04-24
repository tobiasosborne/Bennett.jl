using Test
using Bennett
using Bennett: soft_fptoui

# Bennett-b1vp / U31: the `fptoui` LLVM opcode was routed through
# `soft_fptosi`, which returns a signed Int64. Any IR consumer that
# expected UINT64-in-range bits (e.g. `unsafe_trunc(UInt64, 1.0e19)`)
# got a sign-reinterpreted value. `soft_fptoui` now exists and is
# routed separately at the `LLVMFPToUI` dispatch site.
#
# Semantics pin (bit-exact against Julia x86-64 `unsafe_trunc(UInt64, ·)`):
# - x ∈ [0, 2^63): identical to `soft_fptosi` (cvttsd2si path).
# - x ∈ [2^63, 2^64): subtract 2^63, convert, OR bit 63.
# - NaN / ±Inf / |x| ≥ 2^64 / x ∈ (-∞, -2^63]: saturate to
#   0x8000000000000000 (x86 `cvttsd2si` indefinite).
# - x ∈ (-2^63, 0): two's-complement reinterpretation of the signed
#   convert (matches x86-64 native, even though strictly LLVM UB).
@testset "Bennett-b1vp / U31: soft_fptoui" begin

    @testset "in-range positives bit-exact against unsafe_trunc(UInt64, ·)" begin
        probes = [0.0, 0.5, 0.99, 1.0, 2.0, 100.0, 1e3, 1e10, 1e15,
                  1.0e18, 1.8e19, prevfloat(2.0^64)]
        for x in probes
            @test soft_fptoui(reinterpret(UInt64, x)) ==
                  unsafe_trunc(UInt64, x)
        end
    end

    @testset "crossing 2^63 boundary" begin
        # Just under and at 2^63: both should match native.
        @test soft_fptoui(reinterpret(UInt64, prevfloat(2.0^63))) ==
              unsafe_trunc(UInt64, prevfloat(2.0^63))
        @test soft_fptoui(reinterpret(UInt64, 2.0^63)) ==
              unsafe_trunc(UInt64, 2.0^63)
        # Well inside [2^63, 2^64) — this is the case U31 called out
        # specifically: `fptoui(1e19)` was being corrupted by the signed
        # route. Pin it.
        @test soft_fptoui(reinterpret(UInt64, 1.0e19)) ==
              unsafe_trunc(UInt64, 1.0e19)
        @test soft_fptoui(reinterpret(UInt64, 1.0e19)) == 10000000000000000000
    end

    @testset "invalid operands saturate to 0x8000000000000000" begin
        # Matches x86-64 `cvttsd2si` indefinite and Julia native.
        @test soft_fptoui(reinterpret(UInt64, NaN))  == UInt64(0x8000000000000000)
        @test soft_fptoui(reinterpret(UInt64,  Inf)) == UInt64(0x8000000000000000)
        @test soft_fptoui(reinterpret(UInt64, -Inf)) == UInt64(0x8000000000000000)
        @test soft_fptoui(reinterpret(UInt64, 2.0^64)) == UInt64(0x8000000000000000)
        @test soft_fptoui(reinterpret(UInt64, -2.0^63)) == UInt64(0x8000000000000000)
    end

    @testset "in-range negatives match native x86 two's-complement" begin
        for x in (-0.0, -1.0, -100.0, -1e10, -1.0e18, prevfloat(-2.0^63))
            @test soft_fptoui(reinterpret(UInt64, x)) ==
                  unsafe_trunc(UInt64, x)
        end
    end

    @testset "reversible_compile: fptoui dispatch routes to soft_fptoui" begin
        # unsafe_trunc(UInt64, x::Float64) emits `fptoui double to i64`.
        # Prior to U31 this was silently routed through soft_fptosi —
        # pin the correct dispatch here. `simulate` returns the i64 output
        # as `Int64`, so compare bit-patterns via `% UInt64` (bit-exact
        # reinterpretation) against the native unsigned truncation.
        f(x::Float64) = unsafe_trunc(UInt64, x)
        c = reversible_compile(f, Tuple{Float64})
        @test verify_reversibility(c)
        for x in [0.0, 1.0, 100.0, 1.0e10, 1.0e18, 1.0e19,
                  -0.0, -1.0, -100.0, NaN, Inf, -Inf]
            xb = reinterpret(UInt64, x)
            @test simulate(c, xb) % UInt64 == unsafe_trunc(UInt64, x)
        end
    end
end
