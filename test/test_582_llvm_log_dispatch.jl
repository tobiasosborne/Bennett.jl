# Bennett-582: direct dispatch for `llvm.log` / `llvm.log2` / `llvm.log10`
# as IRCall to the matching soft_log{,2,10} primitive.
#
# Background mirrors Bennett-1pb (sqrt/exp/exp2): Julia's `Base.log` etc.
# normally routes through SoftFloat dispatch when callers wrap their inputs
# in `SoftFloat`, so `llvm.log.f64` rarely appears in IR Bennett extracts
# from Julia frontends. But the intrinsic CAN arrive with raw operands via
# `@fastmath log(x)` on a Float64, `Core.Intrinsics` (where exposed), or
# raw `.ll`/`.bc` ingest (the Bennett-xkv multi-language vision).
#
# Routing: `llvm.log10.*` → `soft_log10`, `llvm.log2.*` → `soft_log2`,
# `llvm.log.*` → `soft_log`. Order is load-bearing in the dispatcher
# because `startswith("llvm.log")` matches all three — log10 then log2
# then log.
#
# pow / sin / cos still need new soft-float bodies — Bennett-emv (pow,
# next phase), Bennett-3mo (sin/cos).

@testset "Bennett-582: llvm.log / llvm.log2 / llvm.log10 direct dispatch" begin

    # Bennett-hybr: compile the llvm.log.f64 fixture ONCE and share the
    # resulting circuit across the two testsets that exercise it (accuracy
    # + special-cases). log2 and log10 each appear in only one testset, so
    # they remain in-place.
    _log_f64_path = joinpath(@__DIR__, "fixtures", "ll", "582_log_f64.ll")
    _log_f64_parsed = Bennett.extract_parsed_ir_from_ll(_log_f64_path; entry_function="log_f64")
    _log_f64_c = reversible_compile(_log_f64_parsed)

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_log")   === Bennett.soft_log
        @test Bennett._lookup_callee("soft_log2")  === Bennett.soft_log2
        @test Bennett._lookup_callee("soft_log10") === Bennett.soft_log10
    end

    @testset "llvm.log.f64 via .ll ingest" begin
        c = _log_f64_c
        @test verify_reversibility(c)
        for x in (1.0, 2.0, 0.5, ℯ, 10.0, 100.0, 0.1, 1.5, 0.99, 1.01)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = log(xf)
            # ≤2 ULP per soft_log accuracy contract
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.log2.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "582_log2_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="log2_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (1.0, 2.0, 4.0, 8.0, 0.5, 0.25, 3.0, 5.0, 1e-100, 1e100)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = log2(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.log10.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "582_log10_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="log10_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (1.0, 10.0, 100.0, 1000.0, 0.1, 0.01, 7.0, 1e-50, 1e50)
            xf = Float64(x)
            got = simulate(c, reinterpret(UInt64, xf))
            actual = reinterpret(Float64, got)
            expected = log10(xf)
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            else
                eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.log.f64 special cases via .ll ingest" begin
        c = _log_f64_c
        # log(1) = 0 bit-exact (the only mathematically exact identity)
        @test simulate(c, reinterpret(UInt64, 1.0)) == reinterpret(UInt64, 0.0)
        # log(0) = -Inf
        @test simulate(c, reinterpret(UInt64, 0.0)) == reinterpret(UInt64, -Inf)
        # log(-1) = NaN
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, -1.0))))
        # log(+Inf) = +Inf
        @test simulate(c, reinterpret(UInt64, Inf)) == reinterpret(UInt64, Inf)
        # log(NaN) = NaN
        @test isnan(reinterpret(Float64, simulate(c, reinterpret(UInt64, NaN))))
    end

    @testset "llvm.log.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "582_log_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="log_f32")
    end

end
