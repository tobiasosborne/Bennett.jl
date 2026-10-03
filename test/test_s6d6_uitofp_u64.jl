using Test
using Random
using Bennett
using Bennett: soft_uitofp

# Bennett-s6d6 (Astra B-extract-core F7): `uitofp i64 to double` was routed
# through the SIGNED converter `soft_sitofp`, so every UInt64 ≥ 2^63 came out
# as a negative double. Witness from plain Julia:
#   reinterpret(UInt64, Float64(typemax(UInt64)))  gave 0xbff0… want 0x43f0…
#   reinterpret(UInt64, Float64(UInt64(2)^63))     gave 0xc3e0… want 0x43e0…
# Fix: a distinct unsigned primitive `soft_uitofp`, dispatched for
# LLVMUIToFP. Narrower unsigned sources (i8/i16/i32) are zero-extended to
# i64 first and therefore always < 2^63 — they were already correct and must
# stay correct.

const _S6D6_ULP_HI = UInt64(1) << 11          # ulp of a double in [2^63, 2^64)
const _S6D6_HALF_HI = UInt64(1) << 10

# Edge cases: powers of two, 2^53 rounding boundary, the 2^63 sign boundary,
# round-to-nearest-even ties in the high half, typemax.
function _s6d6_edges()
    xs = UInt64[0, 1, 2, 3, 0xff, 0xffff, 0xffffffff,
                UInt64(2)^53 - 1, UInt64(2)^53, UInt64(2)^53 + 1,
                UInt64(2)^53 + 2, UInt64(2)^53 + 3,
                UInt64(2)^63 - 1, UInt64(2)^63, UInt64(2)^63 + 1,
                UInt64(2)^63 + _S6D6_HALF_HI - 1,
                UInt64(2)^63 + _S6D6_HALF_HI,        # tie → even (down)
                UInt64(2)^63 + _S6D6_HALF_HI + 1,
                UInt64(2)^63 + 3 * _S6D6_HALF_HI,    # tie → even (up)
                UInt64(2)^63 + _S6D6_ULP_HI,
                typemax(UInt64) - _S6D6_HALF_HI,     # tie at the top → 2^64
                typemax(UInt64) - _S6D6_HALF_HI - 1, # just below the top tie
                typemax(UInt64) - 1, typemax(UInt64),
                0xc000000000000000, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555]
    for k in 0:63
        push!(xs, UInt64(1) << k)
        k >= 1 && push!(xs, (UInt64(1) << k) - 1)
        # ties for every binade that needs rounding (k ≥ 53)
        if k >= 53
            h = UInt64(1) << (k - 53)
            push!(xs, (UInt64(1) << k) + h, (UInt64(1) << k) + 3h,
                      (UInt64(1) << k) + h + 1)
        end
    end
    return xs
end

_s6d6_want(x::UInt64) = reinterpret(UInt64, Float64(x))

s6d6_u64(x::UInt64) = reinterpret(UInt64, Float64(x))
s6d6_u32(x::UInt32) = reinterpret(UInt64, Float64(x))
s6d6_u16(x::UInt16) = reinterpret(UInt64, Float64(x))
s6d6_u8(x::UInt8)   = reinterpret(UInt64, Float64(x))
s6d6_i64(x::Int64)  = reinterpret(UInt64, Float64(x))

@testset "Bennett-s6d6: uitofp i64 → double is unsigned" begin

    @testset "soft_uitofp bit-exact vs Float64(::UInt64)" begin
        for x in _s6d6_edges()
            @test soft_uitofp(x) == _s6d6_want(x)
        end
        # Random sweep: collect mismatches so a regression reports once,
        # not 600k times.
        rng = MersenneTwister(0x56d6)
        bad = UInt64[]
        for _ in 1:200_000
            x = rand(rng, UInt64)
            for v in (x,
                      x | (UInt64(1) << 63),            # force the high half
                      x >> rand(rng, 0:63))             # spread over binades
                soft_uitofp(v) == _s6d6_want(v) || push!(bad, v)
            end
        end
        @test isempty(bad)
    end

    @testset "circuit: Float64(::UInt64)" begin
        c = reversible_compile(s6d6_u64, UInt64)
        rng = MersenneTwister(0x56d7)
        xs = vcat(_s6d6_edges(), rand(rng, UInt64, 64),
                  rand(rng, UInt64, 64) .| (UInt64(1) << 63))
        for x in xs
            @test reinterpret(UInt64, simulate(c, x)) == _s6d6_want(x)
        end
        @test verify_reversibility(c)
    end

    @testset "circuit: narrow unsigned sources stay correct" begin
        c8 = reversible_compile(s6d6_u8, UInt8)
        for x in typemin(UInt8):typemax(UInt8)
            @test reinterpret(UInt64, simulate(c8, x)) == s6d6_u8(x)
        end
        @test verify_reversibility(c8)

        rng = MersenneTwister(0x56d8)
        c16 = reversible_compile(s6d6_u16, UInt16)
        for x in vcat(UInt16[0, 1, 0x7fff, 0x8000, 0xffff], rand(rng, UInt16, 64))
            @test reinterpret(UInt64, simulate(c16, x)) == s6d6_u16(x)
        end
        @test verify_reversibility(c16)

        c32 = reversible_compile(s6d6_u32, UInt32)
        for x in vcat(UInt32[0, 1, 0x7fffffff, 0x80000000, 0xffffffff],
                      rand(rng, UInt32, 64))
            @test reinterpret(UInt64, simulate(c32, x)) == s6d6_u32(x)
        end
        @test verify_reversibility(c32)
    end

    @testset "circuit: signed Float64(::Int64) unchanged" begin
        c = reversible_compile(s6d6_i64, Int64)
        for x in Int64[0, 1, -1, typemin(Int64), typemax(Int64),
                       -(Int64(2)^53) - 1, Int64(2)^53 + 1]
            @test reinterpret(UInt64, simulate(c, x)) == s6d6_i64(x)
        end
        @test verify_reversibility(c)
    end
end
