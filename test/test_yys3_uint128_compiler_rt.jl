@testset "Bennett-yys3 / U163 — UInt128 vs manual 128-bit helpers (premise check)" begin

    # ---- Investigation summary (Bennett-yys3, 2026-04-27) ----
    #
    # The review (reviews/2026-04-21/12_torvalds.md F14) flagged the
    # 200+ LOC of manual 128-bit arithmetic in src/softfloat/softfloat_common.jl
    # (_sf_widemul_u64_to_128, _add128, _sub128, _neg128, _shl128_by1,
    # _shr128jam_by1, _shiftRightJam128) as existing solely to avoid
    # `__udivti3` / `__umodti3` compiler-rt calls that UInt128 supposedly
    # emits. The proposed fix: register the compiler-rt callees, replace
    # manual code with native UInt128 ops.
    #
    # **The premise is empirically stale** in current Julia:
    # `code_llvm(f, (UInt128, UInt128), optimize=false)` for `*`, `+`,
    # `-`, `<<`, AND even `÷` / `%` emits NO call to __udivti3 or
    # __umodti3 — Julia's UInt128 lowering inlines/expands these
    # operations directly. Modern compiler-rt for these ops appears to
    # be built into LLVM's lowering rather than a runtime call.
    #
    # Disposition: investigated, doc-only. The manual helpers ARE
    # replaceable by native UInt128 ops with no compiler-rt risk, but:
    # - The replacement would shift soft_fma's gate-emission profile
    #   (Julia's UInt128 ops vs hand-rolled hi/lo arithmetic).
    # - Existing pinned baselines for soft_fma would need re-measurement
    #   per CLAUDE.md §6.
    # - The "savings" would be in source-file LOC, not in gates emitted.
    # The refactor is feasible but out-of-scope for a bugs-only directive
    # session. Filed as investigated; no architectural follow-up filed
    # (per the chunk-045 directive against follow-up beads as a substitute).
    #
    # Companion docstring update: src/softfloat/softfloat_common.jl
    # documents the stale premise + points at this test for the empirical
    # verification.

    using InteractiveUtils

    function _emits_compiler_rt(f::F, types::Tuple) where F
        io = IOBuffer()
        code_llvm(io, f, types, optimize=false)
        ir = String(take!(io))
        return occursin(r"__udivti|__umodti", ir)
    end

    @testset "UInt128 arithmetic ops do NOT emit __udivti3/__umodti3" begin
        @test !_emits_compiler_rt((a::UInt128, b::UInt128) -> a * b, (UInt128, UInt128))
        @test !_emits_compiler_rt((a::UInt128, b::UInt128) -> a + b, (UInt128, UInt128))
        @test !_emits_compiler_rt((a::UInt128, b::UInt128) -> a - b, (UInt128, UInt128))
        @test !_emits_compiler_rt((a::UInt128, k::Int) -> a << k, (UInt128, Int))
        @test !_emits_compiler_rt((a::UInt128, k::Int) -> a >> k, (UInt128, Int))
        # Even division and modulo don't emit the named compiler-rt calls
        # in current Julia; lowering is via inlined sequences.
        @test !_emits_compiler_rt((a::UInt128, b::UInt128) -> a ÷ b, (UInt128, UInt128))
        @test !_emits_compiler_rt((a::UInt128, b::UInt128) -> a % b, (UInt128, UInt128))
    end

    @testset "Manual helpers still produce correct results (regression guard)" begin
        # Pin the manual helpers' contracts so any future replacement by
        # UInt128 ops can be cross-checked against these expected outputs.
        a = UInt64(0xDEADBEEFCAFEBABE)
        b = UInt64(0x0123456789ABCDEF)
        (hi, lo) = Bennett._sf_widemul_u64_to_128(a, b)
        # Cross-check against UInt128 widemul.
        expected = UInt128(a) * UInt128(b)
        @test (UInt128(hi) << 64) | UInt128(lo) == expected

        # _add128
        a_hi, a_lo = UInt64(0x1234), UInt64(0xFEDC)
        b_hi, b_lo = UInt64(0x5678), UInt64(0x9876)
        (sum_hi, sum_lo) = Bennett._add128(a_hi, a_lo, b_hi, b_lo)
        expected = ((UInt128(a_hi) << 64) | UInt128(a_lo)) +
                   ((UInt128(b_hi) << 64) | UInt128(b_lo))
        @test (UInt128(sum_hi) << 64) | UInt128(sum_lo) == expected

        # _sub128
        (diff_hi, diff_lo) = Bennett._sub128(a_hi, a_lo, b_hi, b_lo)
        expected = ((UInt128(a_hi) << 64) | UInt128(a_lo)) -
                   ((UInt128(b_hi) << 64) | UInt128(b_lo))
        @test (UInt128(diff_hi) << 64) | UInt128(diff_lo) == expected

        # _neg128
        (n_hi, n_lo) = Bennett._neg128(a_hi, a_lo)
        expected = UInt128(0) - ((UInt128(a_hi) << 64) | UInt128(a_lo))
        @test (UInt128(n_hi) << 64) | UInt128(n_lo) == expected
    end
end
