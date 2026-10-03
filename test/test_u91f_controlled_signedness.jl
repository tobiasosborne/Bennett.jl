using Test
using Bennett

# Bennett-u91f (Astra B-circuit-core F4): `simulate(controlled(c), ctrl, x)`
# decoded unsigned outputs as signed (0xff → -1). `_simulate_ctrl` delegated
# to `_simulate` with the full inner input tuple `(Int(ctrl), x...)`; the
# Bennett-zc50 signedness heuristic (all inputs Unsigned AND all input /
# output widths equal) then saw a signed 1-bit ctrl input and fell back to
# signed decoding. Fix: the controlled wrapper infers signedness from the
# payload (f-input) layout only, so the controlled result equals the
# uncontrolled one in value AND type when ctrl = true, and is that type's
# zero when ctrl = false.

# Expected controlled result: `ctrl ? simulate(c, x) : zero-of-same-shape`.
_zero_like(r::Integer) = zero(r)
_zero_like(r::Tuple) = map(zero, r)

function _check_ctrl_matches(c, cc, x)
    ref = simulate(c, x)
    on  = simulate(cc, true, x)
    off = simulate(cc, false, x)
    return on === ref && off === _zero_like(ref)
end

@testset "Bennett-u91f controlled() preserves output signedness" begin

    @testset "identity UInt8, all 256 inputs, both controls" begin
        c  = reversible_compile(identity, UInt8; strategy=:expression)
        cc = controlled(c)
        @test simulate(cc, true, 0xff) === 0xff          # the F4 witness
        @test simulate(cc, false, 0xff) === 0x00
        for x in 0x00:0xff
            @test simulate(cc, true, x) === x
            @test simulate(cc, false, x) === 0x00
            @test _check_ctrl_matches(c, cc, x)
        end
        @test verify_reversibility(c)
        @test verify_reversibility(cc)
    end

    @testset "x + 1 on UInt8, all 256 inputs" begin
        c  = reversible_compile(x -> x + 0x01, UInt8)
        cc = controlled(c)
        for x in 0x00:0xff
            @test simulate(cc, true, x) === x + 0x01
            @test simulate(cc, false, x) === 0x00
        end
        @test verify_reversibility(cc)
    end

    @testset "tuple output (UInt8, UInt8), all 256 inputs" begin
        f(x::UInt8) = (x, x ⊻ 0x80)
        c  = reversible_compile(f, UInt8)
        cc = controlled(c)
        for x in 0x00:0xff
            @test simulate(cc, true, x) === f(x)
            @test simulate(cc, false, x) === (0x00, 0x00)
            @test _check_ctrl_matches(c, cc, x)
        end
        @test verify_reversibility(cc)
    end

    @testset "two UInt8 inputs (tuple-input overload)" begin
        g(x::UInt8, y::UInt8) = x + y
        c  = reversible_compile(g, UInt8, UInt8)
        cc = controlled(c)
        for (x, y) in ((0xff, 0x00), (0x80, 0x7f), (0xfe, 0x01), (0x01, 0x02),
                       (0xff, 0xff), (0x00, 0x00))
            @test simulate(cc, true, (x, y)) === g(x, y)
            @test simulate(cc, false, (x, y)) === 0x00
        end
        @test verify_reversibility(cc)
    end

    @testset "UInt64 sign-bit values" begin
        c  = reversible_compile(x -> x + UInt64(1), UInt64)
        cc = controlled(c)
        for x in (typemax(UInt64) - 1, typemax(UInt64), UInt64(1) << 63,
                  (UInt64(1) << 63) - 1, UInt64(0), UInt64(0x8000_0000_0000_0001),
                  UInt64(0xdead_beef_cafe_f00d))
            @test simulate(cc, true, x) === x + UInt64(1)
            @test simulate(cc, false, x) === UInt64(0)
            @test _check_ctrl_matches(c, cc, x)
        end
        @test verify_reversibility(cc)
    end

    @testset "signed payload stays signed (regression)" begin
        c  = reversible_compile(x -> x + Int8(1), Int8)
        cc = controlled(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(cc, true, x) === x + Int8(1)
            @test simulate(cc, false, x) === Int8(0)
        end
        @test verify_reversibility(cc)
    end

    @testset "width-mismatched layout matches the uncontrolled fallback" begin
        # f8 narrows 16 → 8 bits: the zc50 heuristic does not classify this
        # layout, so both paths fall back to signed decoding. The controlled
        # path must agree with the uncontrolled one, not invent a third answer.
        f8(x::UInt16) = x % UInt8
        c  = reversible_compile(f8, UInt16; strategy=:expression)
        cc = controlled(c)
        for x in (0x0000, 0x00ff, 0x7f80, 0xffff, 0x1234)
            @test _check_ctrl_matches(c, cc, x)
            @test simulate(cc, true, x) % UInt8 === f8(x)
        end
        @test verify_reversibility(cc)
    end
end
