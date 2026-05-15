# Bennett-mq6f: native `soft_round_away` (round-half-AWAY-from-zero,
# ≡ `llvm.round.f64` per LLVM langref) + LLVM dispatch closing the
# kh6n round-family gap. Three-part scope:
#
#   - Part A: `soft_round_away` primitive in src/softfloat/fround.jl,
#     mirroring `soft_round` (banker's) verbatim except for the tie
#     handling at `±N.5`.
#   - Part B: `llvm.round.` dispatches to `soft_round_away` (was
#     silently miscompiled by the no-op-arm fallthrough to banker's
#     `soft_round`); `llvm.roundeven.` dispatches to `soft_round`
#     (replacing the kh6n explicit reject — both are banker's).
#   - Part C: callee registry + module export + worklog correction
#     of the kh6n misstatement claiming `soft_round` was round-half-
#     AWAY (it IS banker's; see Bennett-2hhx).

using Test
using Bennett
using Random

@inline _bits(x::Float64) = reinterpret(UInt64, x)
@inline _flt(x::UInt64)   = reinterpret(Float64, x)

const MQ6F_LL = joinpath(@__DIR__, "fixtures", "ll")

@testset "Bennett-mq6f: soft_round_away (round-half-AWAY-from-zero)" begin

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_round_away") === Bennett.soft_round_away
    end

    # ---- Bit-level primitive ----

    @testset "ties-to-AWAY (canonical halfway cases vs RoundNearestTiesAway)" begin
        # ±N.5 always rounds AWAY from zero. Use Base.round(x, RoundNearestTiesAway)
        # as the bit-exact reference (Julia exposes the rounding mode but does NOT
        # have a hardware-default round-half-away).
        ties = [
            (0.5,   1.0),    # tie 0/1, AWAY → 1
            (-0.5,  -1.0),
            (1.5,   2.0),
            (-1.5,  -2.0),
            (2.5,   3.0),    # tie 2/3, AWAY → 3 (DIFFERENT from soft_round which gives 2)
            (-2.5,  -3.0),
            (3.5,   4.0),
            (-3.5,  -4.0),
            (4.5,   5.0),    # AWAY → 5 (DIFFERENT from soft_round which gives 4)
            (-4.5,  -5.0),
            (123456789.5,   123456790.0),
            (-123456789.5, -123456790.0),
            (1.234567890e15, 1.234567890e15),  # already integer
        ]
        for (x, expected) in ties
            got_bits = Bennett.soft_round_away(_bits(x))
            @test got_bits == _bits(expected)
            @test got_bits == _bits(round(x, RoundNearestTiesAway))
        end
    end

    @testset "non-tie rounding (matches both soft_round and Base.round)" begin
        # For any non-tie input, banker's and round-half-AWAY agree (they
        # only differ at ±N.5). So `soft_round_away(x) == soft_round(x)`
        # for these.
        cases = [
            0.0, -0.0, 0.1, -0.1, 0.3, -0.3, 0.499, -0.499,
            0.501, -0.501, 0.7, -0.7, 1.0, -1.0, 1.1, -1.1,
            1.49, -1.49, 1.51, -1.51, 2.7, -2.7,
            π, -π, ℯ, -ℯ, 100.7, 100.3, -100.7, -100.3,
            1e-5, -1e-5, 1e10, -1e10,
            2.0^52 - 0.25, 2.0^52 - 0.75,
            -(2.0^52) + 0.25,
        ]
        for x in cases
            got_bits = Bennett.soft_round_away(_bits(x))
            @test got_bits == _bits(round(x, RoundNearestTiesAway))
            # Sanity: agree with soft_round (banker's) on non-ties.
            @test got_bits == Bennett.soft_round(_bits(x))
        end
    end

    @testset "subnormals → ±0 (sign preserved)" begin
        # Subnormals all have |x| < 2^-1022 << 0.5; round to ±0.
        smallest_subnormal = _flt(UInt64(1))
        largest_subnormal  = _flt(UInt64(0x000FFFFFFFFFFFFF))
        for x in [smallest_subnormal, -smallest_subnormal,
                  largest_subnormal, -largest_subnormal,
                  _flt(UInt64(0x0008000000000000)),
                  _flt(UInt64(0x8008000000000000))]
            got_bits = Bennett.soft_round_away(_bits(x))
            @test got_bits == _bits(round(x, RoundNearestTiesAway))
        end
    end

    @testset "Inf passes through" begin
        @test Bennett.soft_round_away(_bits( Inf)) == _bits( Inf)
        @test Bennett.soft_round_away(_bits(-Inf)) == _bits(-Inf)
    end

    @testset "NaN passes through quietened" begin
        qnan_bits = _bits(NaN)
        @test isnan(_flt(Bennett.soft_round_away(qnan_bits)))

        # qNaN with payload
        qnan_payload = UInt64(0x7FF8_DEAD_BEEF_CAFE)
        out = Bennett.soft_round_away(qnan_payload)
        @test isnan(_flt(out))
        @test (out & UInt64(0x0008000000000000)) != 0  # quiet bit set

        # sNaN must be force-quieted (Bennett-r84x convention)
        snan_bits = UInt64(0x7FF0_0000_0000_0001)
        out = Bennett.soft_round_away(snan_bits)
        @test isnan(_flt(out))
        @test (out & UInt64(0x0008000000000000)) != 0

        # Negative NaN
        out = Bennett.soft_round_away(_bits(-NaN))
        @test isnan(_flt(out))
    end

    @testset "carry-into-exponent (round 1.999... → 2.0)" begin
        # Almost-2 with all fraction bits set, exp=1023.
        almost_two = _flt(UInt64(0x3FFFFFFFFFFFFFFF))
        @test Bennett.soft_round_away(_bits( almost_two)) == _bits( 2.0)
        @test Bennett.soft_round_away(_bits(-almost_two)) == _bits(-2.0)
    end

    @testset "boundary at 2^52 (already-integer threshold)" begin
        for x in [2.0^52, 2.0^52 + 1, 2.0^52 - 1, 2.0^53,
                  -(2.0^52), -(2.0^52 + 1)]
            @test Bennett.soft_round_away(_bits(x)) == _bits(round(x, RoundNearestTiesAway))
        end
    end

    @testset "tie at every ±N.5 for N in 0:10" begin
        # Exhaustive small-integer tie sweep.
        for N in 0:10
            for s in (1, -1)
                x = s * (N + 0.5)
                got = Bennett.soft_round_away(_bits(x))
                @test got == _bits(round(x, RoundNearestTiesAway))
            end
        end
    end

    @testset "subnormal-input binade sweep (per CLAUDE.md §13 spirit)" begin
        # Round-half-AWAY of any subnormal is ±0 (subnormals have |x| << 0.5);
        # sweep all 1074 binades × ±. This is the canonical §13 sweep — the
        # discipline born from the soft_exp `[-708.4, -745]` garbage-output
        # post-mortem (see CLAUDE.md §13 Bennett-fnxg note).
        for shift in 0:1073
            x = ldexp(1.0, -1022 - shift)  # subnormal magnitude
            for s in (1, -1)
                a = s * x
                @test Bennett.soft_round_away(_bits(a)) == _bits(round(a, RoundNearestTiesAway))
            end
        end
    end

    @testset "random raw-bits sweep vs RoundNearestTiesAway" begin
        # Per CLAUDE.md §13: 5,000 random UInt64 inputs, bit-exact vs
        # `round(x, RoundNearestTiesAway)`. NaN payloads are tested by
        # the property "result is NaN with quiet bit set" rather than
        # bit-equality (`Base.round` may produce a different NaN bit
        # pattern depending on internal helper choice).
        rng = MersenneTwister(0x6f6f_6f6f_6f6f_6f6f)
        for _ in 1:5000
            bits = rand(rng, UInt64)
            x = _flt(bits)
            got = Bennett.soft_round_away(bits)
            if isnan(x)
                @test isnan(_flt(got))
                @test (got & UInt64(0x0008000000000000)) != 0
            else
                @test got == _bits(round(x, RoundNearestTiesAway))
            end
        end
    end

    @testset "soft_round vs soft_round_away divergence ONLY at ±N.5" begin
        # Sanity: across a structured non-tie sweep, the two primitives
        # MUST agree. The only design-time divergence is at exact ±N.5.
        for x in (0.1, 0.49, 0.51, 0.9, 1.49, 1.51, 2.49, 2.51,
                  -0.1, -0.49, -0.51, -1.49, -1.51,
                  17.3, -17.3, 100.4, -100.4)
            @test Bennett.soft_round(_bits(x)) == Bennett.soft_round_away(_bits(x))
        end
        # And at ±N.5 they MUST disagree where parity matters (banker's
        # rounds down at even tie, away rounds up always).
        for N in (0, 2, 4, 6)  # even N → tie-to-even gives N (down), away gives N+1 (up)
            for s in (1.0, -1.0)
                x = s * (N + 0.5)
                soft_r = Bennett.soft_round(_bits(x))
                soft_a = Bennett.soft_round_away(_bits(x))
                @test soft_r != soft_a
                @test soft_r == _bits(round(x))
                @test soft_a == _bits(round(x, RoundNearestTiesAway))
            end
        end
    end

    # ---- IR-level dispatch (.ll ingest) ----

    @testset "llvm.round.f64 dispatches via .ll ingest (round-half-AWAY)" begin
        path = joinpath(MQ6F_LL, "mq6f_round_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="mq6f_round_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Critical: half-integer ties MUST round AWAY. Pre-mq6f these returned
        # banker's results (2.5 → 2 etc.) — that was the silent miscompile.
        for x in (0.0, 0.5, 1.0, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5,
                  0.7, -0.7, 1e10, -1e10)
            got = simulate(c, (_bits(x),))
            @test got == _bits(round(x, RoundNearestTiesAway))
        end
    end

    @testset "llvm.roundeven.f64 dispatches via .ll ingest (banker's)" begin
        # Pre-mq6f the kh6n arm explicitly rejected this with _ir_error.
        # Post-mq6f it dispatches to soft_round (banker's) since both are
        # IEEE 754 roundToIntegralTiesToEven.
        path = joinpath(MQ6F_LL, "mq6f_roundeven_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="mq6f_roundeven_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Banker's: 2.5 → 2 (even), 1.5 → 2 (even), 3.5 → 4 (even).
        for x in (0.0, 0.5, 1.5, 2.5, 3.5, -0.5, -1.5, -2.5,
                  0.7, -0.7, 1e10, -1e10)
            got = simulate(c, (_bits(x),))
            @test got == _bits(round(x))  # Base.round IS banker's
        end
    end

    @testset "f32 forms still rejected (CLAUDE.md §13)" begin
        for fname in ("mq6f_round_f32_reject.ll",
                      "mq6f_roundeven_f32_reject.ll")
            err = try
                entry = replace(fname, "_reject.ll" => "")
                Bennett.extract_parsed_ir_from_ll(joinpath(MQ6F_LL, fname);
                                                  entry_function=entry)
                nothing
            catch e
                sprint(showerror, e)
            end
            @test err !== nothing
            @test occursin("f64", err) || occursin("f32", err) || occursin("Bennett-mq6f", err)
        end
    end
end
