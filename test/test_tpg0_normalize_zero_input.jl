@testset "Bennett-tpg0 / U135 — _sf_normalize_to_bit52 zero-input contract" begin

    # Pre-tpg0: `_sf_normalize_to_bit52` (src/softfloat/softfloat_common.jl)
    # ran a 6-stage branchless CLZ. On `m == 0`, every `need*` branch
    # fires (no leading 1 found), so output is `(0, e - 63)` — a bogus
    # exponent. The docstring documented this as a caller-trust contract:
    # "callers handle zero inputs via the select chain before using m".
    #
    # Post-tpg0: the function explicitly handles m==0 by returning
    # `(0, e)` unchanged — branchless via an `ifelse` substitute pattern
    # using IMPLICIT (1<<52) as the internal sentinel. For m != 0 the
    # output is byte-identical (the IMPLICIT substitute is a no-op when
    # m already has bit 52 set; the CLZ doesn't underflow).

    using Bennett: _sf_normalize_to_bit52

    @testset "m == 0 returns (0, e) unchanged (no exponent garbage)" begin
        for e in (Int64(0), Int64(1), Int64(-100), Int64(1023), Int64(-1023),
                  Int64(0x7FF), Int64(typemin(Int64) + 64),
                  Int64(typemax(Int64) - 64))
            (m_out, e_out) = _sf_normalize_to_bit52(UInt64(0), e)
            @test m_out == UInt64(0)
            @test e_out == e   # not e - 63
        end
    end

    @testset "m != 0 already-normalized inputs are no-ops" begin
        # Bit 52 already set: leading 1 is at the target. CLZ should
        # decrement nothing.
        IMPLICIT = UInt64(0x0010000000000000)  # 1 << 52
        for m_low in (UInt64(0), UInt64(1), UInt64(0x000FFFFFFFFFFFFF),
                      UInt64(0x0008765432104321))
            for e in (Int64(0), Int64(1023), Int64(-1023))
                m = IMPLICIT | m_low
                (m_out, e_out) = _sf_normalize_to_bit52(m, e)
                @test m_out == m
                @test e_out == e
            end
        end
    end

    @testset "m != 0 subnormal inputs normalize correctly" begin
        # Subnormal: bit 52 NOT set. The CLZ should shift the leading 1
        # up to bit 52 and decrement e by the shift count.
        for m_in in (UInt64(1), UInt64(0x2), UInt64(0x4), UInt64(0x80),
                     UInt64(0x10000), UInt64(0xFFFFFFFF),
                     UInt64(0x000F000000000000))
            leading_pos = 63 - leading_zeros(m_in)
            expected_shift = 52 - leading_pos
            e = Int64(1023)
            (m_out, e_out) = _sf_normalize_to_bit52(m_in, e)
            @test (m_out >> 52) & UInt64(1) == UInt64(1)
            @test e_out == e - Int64(expected_shift)
        end
    end

    @testset "Random m != 0 inputs match Julia's leading_zeros oracle" begin
        # Cross-check against Julia's CLZ: for any m with bits only in
        # [0, 52], the shift count is `52 - position_of_leading_1`.
        # `position_of_leading_1` = `63 - leading_zeros(m)`.
        for _ in 1:200
            # Random mantissa with bits only in [0, 52]
            m = rand(UInt64) & UInt64(0x001FFFFFFFFFFFFF)  # 53-bit max (bit 52 may be set)
            m == 0 && continue
            e = rand(Int64(-1023):Int64(1023))
            (m_out, e_out) = _sf_normalize_to_bit52(m, e)

            leading_pos = 63 - leading_zeros(m)
            expected_shift = 52 - leading_pos
            @test m_out == m << expected_shift
            @test e_out == e - Int64(expected_shift)
        end
    end
end
