# Bennett-emv: direct dispatch for `llvm.pow.f64` and `llvm.powi.f64.i32`
# as IRCall to soft_pow / soft_powi.
#
# `llvm.pow` takes (Float64, Float64) and routes to `soft_pow`. `llvm.powi`
# takes (Float64, Int32) and routes to `soft_powi`. Order is load-bearing
# because `startswith("llvm.pow")` matches both — `llvm.powi.*` checked
# first, then `llvm.pow.*`.
#
# Float32 forms rejected per CLAUDE.md §13 (Bennett-3rph).

@testset "Bennett-emv: llvm.pow / llvm.powi direct dispatch" begin

    # Bennett-hybr: compile the llvm.pow.f64 fixture ONCE and share the
    # resulting circuit across the two testsets that exercise it
    # (accuracy + special-cases). llvm.powi.f64.i32 is a separate fixture
    # used in only one testset so left in-place.
    _pow_f64_path = joinpath(@__DIR__, "fixtures", "ll", "emv_pow_f64.ll")
    _pow_f64_parsed = Bennett.extract_parsed_ir_from_ll(_pow_f64_path; entry_function="pow_f64")
    _pow_f64_c = reversible_compile(_pow_f64_parsed)

    @testset "callees registered" begin
        @test Bennett._lookup_callee("soft_pow")  === Bennett.soft_pow
        @test Bennett._lookup_callee("soft_powi") === Bennett.soft_powi
    end

    @testset "llvm.pow.f64 via .ll ingest" begin
        c = _pow_f64_c
        @test verify_reversibility(c)
        for (x, y) in [(2.0, 3.0), (3.0, 4.0), (10.0, 2.0), (2.0, 0.5),
                       (1.5, 2.5), (1.0, 100.0), (5.0, 0.0), (0.0, 2.0),
                       (-2.0, 3.0), (-2.0, 2.0)]
            xb = reinterpret(UInt64, x); yb = reinterpret(UInt64, y)
            got_bits = simulate(c, (xb, yb))
            actual = reinterpret(Float64, UInt64(got_bits))
            expected = try; x^y; catch; NaN; end
            ulp = if isnan(expected)
                isnan(actual) ? 0 : typemax(Int64)
            elseif isinf(expected) && isinf(actual) && sign(actual) == sign(expected)
                0
            else
                eb = reinterpret(UInt64, expected)
                ab = reinterpret(UInt64, actual)
                Int64(ab >= eb ? ab - eb : eb - ab)
            end
            @test ulp <= 2
        end
    end

    @testset "llvm.pow.f64 special cases via .ll ingest" begin
        c = _pow_f64_c
        function call_pow(x::Float64, y::Float64)
            r = simulate(c, (reinterpret(UInt64, x), reinterpret(UInt64, y)))
            reinterpret(Float64, UInt64(r))
        end
        @test call_pow(1.0, 100.0) === 1.0
        @test call_pow(-1.0, NaN)  === 1.0
        @test call_pow(2.0, 0.0)   === 1.0
        @test call_pow(NaN, 0.0)   === 1.0
        @test isnan(call_pow(NaN, 2.0))
        @test call_pow(0.0,  3.0)  === 0.0
        @test call_pow(0.0, -3.0)  === Inf
    end

    @testset "llvm.powi.f64.i32 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "emv_powi_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="powi_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        function call_powi(x::Float64, n::Int32)
            r = simulate(c, UInt64, (reinterpret(UInt64, x), reinterpret(UInt32, n)))
            reinterpret(Float64, r)
        end
        for (x, n) in [(2.0, Int32(3)), (3.0, Int32(4)), (10.0, Int32(3)),
                       (2.0, Int32(-3)), (1.5, Int32(5)), (-2.0, Int32(3)),
                       (-2.0, Int32(4)), (0.5, Int32(100)), (1.0, Int32(1000))]
            actual = call_powi(x, n)
            expected = x^n
            @test reinterpret(UInt64, actual) === reinterpret(UInt64, expected)
        end
    end

    @testset "llvm.pow.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "emv_pow_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="pow_f32")
    end

end
