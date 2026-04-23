using Test
using Bennett: soft_feistel_int8, soft_feistel32

# Bennett-sqtd / U22 — `soft_feistel_int8` was documented as a "perfect
# hash" (bijection) on Int8. It isn't: the Int8 → UInt32 zero-extension
# covers 256 of 2³² UInt32 values, and the low-byte truncation back to
# UInt8 collides — 256 inputs → 207 distinct outputs, max collision 5.
# Docstring and header comment corrected. This test pins the exact
# image-set size so any future regression (or intentional algorithm
# change) is caught.

@testset "Bennett-sqtd soft_feistel_int8 collision baseline" begin

    # T1 — exact image-set size must be 207. If this changes, either the
    # Feistel algorithm was altered (audit the rotations / round count)
    # or an upstream fix widened the output type (update the baseline
    # + docstring).
    images = Set{Int8}()
    for k in typemin(Int8):typemax(Int8)
        push!(images, soft_feistel_int8(Int8(k)))
    end
    @test length(images) == 207

    # T2 — max collision count is 5.
    counts = Dict{Int8, Int}()
    for k in typemin(Int8):typemax(Int8)
        h = soft_feistel_int8(Int8(k))
        counts[h] = get(counts, h, 0) + 1
    end
    @test maximum(values(counts)) == 5

    # T3 — the underlying UInt32 Feistel IS a bijection. Verify on a
    # walking-bit sweep (full 2³² enumeration would be too slow).
    seen = Set{UInt32}()
    for bit in 0:31
        x = UInt32(1) << bit
        h = soft_feistel32(x)
        @test !(h in seen)
        push!(seen, h)
        # and on its complement
        x2 = ~x
        h2 = soft_feistel32(x2)
        @test !(h2 in seen)
        push!(seen, h2)
    end

    # T4 — docstring honesty: the word "bijection" should NOT appear in
    # the soft_feistel_int8 docstring. (Catches regressions where someone
    # re-introduces the claim without checking the image size.)
    docstr = string(@doc soft_feistel_int8)
    @test !occursin("bijection", lowercase(docstr)) ||
          occursin("not a bijection", lowercase(docstr))
end
