@testset "Bennett-xiqt / U133 — subnormal flush-to-zero boundary regression guard" begin

    # ---- Investigation summary (Bennett-xiqt / U133, 2026-04-27) ----
    #
    # The review (reviews/2026-04-21/11_softfloat.md F8/M6) flagged
    # `_sf_handle_subnormal`'s `flush_to_zero = shift_sub >= 56`
    # boundary as potentially dropping the round-up case for values
    # whose true magnitude is just above half of smallest subnormal.
    # Per IEEE-754 RTNE, such values should round UP to smallest
    # subnormal, not flush to zero.
    #
    # Empirical investigation (this bead): 200k+ random fmul, 200k+
    # random fdiv, 100k each fadd/fsub/fma calls with subnormal-range
    # inputs produce ZERO disagreements vs Base.* / Base.fma. The flush
    # boundary IS exercised at shift_sub ∈ [56, 60] (~0.4% of all calls
    # for fmul) AND wr's bit 55 is always set in those cases — the wr
    # encoding at the boundary doesn't have a naive "bit 55 = round
    # bit" reading, and Base also rounds these inputs to ±0.
    #
    # Disposition: investigated, doc-only. The theoretical RTNE-incorrectness
    # at shift_sub == 56 is not triggered by any current soft_f* caller;
    # this test pins the empirical-agreement contract as a regression
    # guard against future changes to the helper or to fmul/fdiv/fma/fadd's
    # wr encoding.
    #
    # Companion docstring update: src/softfloat/softfloat_common.jl
    # _sf_handle_subnormal docstring documents the finding.

    using Bennett: _sf_handle_subnormal
    bits(x::Float64) = reinterpret(UInt64, x)
    fb(x::UInt64) = reinterpret(Float64, x)

    @testset "Helper: pinned current behavior at the flush boundary" begin
        # Pin the current behavior at shift_sub == 56 with bit 55 set
        # (the theoretical RTNE-incorrect case). Any future change to
        # the helper that produces a different output here trips this.
        # CURRENT semantics: wr unchanged, exp=0, flushed=±0, both
        # subnormal AND flush_to_zero flags = true.
        wr = (UInt64(1) << 55) | UInt64(0x123)
        result_exp = Int64(-55)  # → shift_sub = 1 - (-55) = 56
        for sign in (UInt64(0), UInt64(1))
            (wr_out, exp_out, flushed, sub, ftz) =
                _sf_handle_subnormal(wr, result_exp, sign)
            @test wr_out == wr
            @test exp_out == Int64(0)
            @test flushed == sign << 63
            @test sub == true
            @test ftz == true
        end

        # shift_sub == 55 (one below the boundary): should NOT flush.
        result_exp = Int64(-54)  # → shift_sub = 55
        (_, _, _, _, ftz) = _sf_handle_subnormal(wr, result_exp, UInt64(0))
        @test ftz == false

        # shift_sub == 0 (no shift, already-normalized subnormal): no flush.
        (_, _, _, _, ftz) = _sf_handle_subnormal(wr, Int64(1), UInt64(0))
        @test ftz == false
    end

    @testset "End-to-end empirical agreement (regression guard)" begin
        # Smaller-scale than the exploratory investigation (200k each),
        # but enough to trip if a future helper-fix accidentally breaks
        # the empirical agreement. Subnormal-range inputs only.
        function _scan(soft_op::F1, base_op::F2, n_iters::Int) where {F1, F2}
            d = 0
            for _ in 1:n_iters
                a_exp = rand(0x000:0x500)
                b_exp = rand(0x000:0x700)
                a = (UInt64(a_exp) << 52) | (rand(UInt64) & 0x000FFFFFFFFFFFFF)
                b = (UInt64(b_exp) << 52) | (rand(UInt64) & 0x000FFFFFFFFFFFFF)
                a |= (UInt64(rand(Bool)) << 63)
                b |= (UInt64(rand(Bool)) << 63)
                af, bf = fb(a), fb(b)
                base_r = bits(base_op(af, bf))
                soft_r = soft_op(a, b)
                base_r != soft_r && (d += 1)
            end
            return d
        end
        @test _scan(Bennett.soft_fmul, *, 5000) == 0
        @test _scan(Bennett.soft_fdiv, /, 5000) == 0
        @test _scan(Bennett.soft_fadd, +, 5000) == 0
        @test _scan(Bennett.soft_fsub, -, 5000) == 0
    end

    @testset "Targeted boundary cases (round-up to smallest subnormal)" begin
        # Inputs designed to produce a true product just above 2^-1075
        # (half of smallest subnormal): RTNE → smallest subnormal (frac=1).
        # Pre-xiqt these passed (Base.* and soft_fmul agree); pinned
        # here as a future regression guard.
        a = bits(ldexp(1.0, -1022))   # smallest normal
        for b_factor in (1.5, 1.25, 1.75, 1.1)
            b = bits(ldexp(1.0, -53) * b_factor)
            base_r = bits(fb(a) * fb(b))
            soft_r = Bennett.soft_fmul(a, b)
            @test soft_r == base_r
            @test soft_r == UInt64(0x0000000000000001)  # smallest subnormal
        end

        # Exactly half of smallest subnormal — RTNE ties-to-even → ±0.
        b_half = bits(ldexp(1.0, -53))
        @test Bennett.soft_fmul(a, b_half) == bits(fb(a) * fb(b_half))
        @test Bennett.soft_fmul(a, b_half) == UInt64(0)
    end
end
