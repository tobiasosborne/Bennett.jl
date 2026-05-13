using Test
using Bennett

const AO66_LL = joinpath(@__DIR__, "fixtures", "ll")

function ao66_compile(entry::AbstractString, file::AbstractString)
    parsed = Bennett.extract_parsed_ir_from_ll(joinpath(AO66_LL, file);
                                               entry_function=entry)
    circuit = reversible_compile(parsed)
    @test verify_reversibility(circuit)
    return circuit
end

ao66_i64_hash(xs::Vararg{Int64}) = foldl((acc, x) -> acc * 131 + x, xs)
ao66_i32_hash(xs::Vararg{Int32}) = foldl((acc, x) -> acc * Int32(31) + x, xs)

@testset "Bennett-ao66: vector intrinsic re-scalarisation" begin
    @testset "llvm.smax.v4i64" begin
        c = ao66_compile("ao66_smax_v4i64", "ao66_smax_v4i64.ll")
        for (a, b) in ((Int64(-3), Int64(4)),
                       (Int64(9), Int64(-2)),
                       (Int64(-8), Int64(-1)))
            expected = ao66_i64_hash(max(a, Int64(0)),
                                     max(b, Int64(0)),
                                     Int64(0),
                                     Int64(7))
            @test simulate(c, (a, b)) == expected
        end
    end

    @testset "llvm.umax.v2i64" begin
        c = ao66_compile("ao66_umax_v2i64", "ao66_umax_v2i64.ll")
        for (a, b) in ((UInt64(1), UInt64(2)),
                       (UInt64(9), UInt64(4)),
                       (typemax(UInt64) - UInt64(1), UInt64(0)))
            e0 = max(a, UInt64(3))
            e1 = max(b, UInt64(5))
            @test simulate(c, (a, b)) == xor(e0, e1 << 1)
        end
    end

    @testset "llvm.abs.v4i32" begin
        c = ao66_compile("ao66_abs_v4i32", "ao66_abs_v4i32.ll")
        for (a, b) in ((Int32(-3), Int32(4)),
                       (Int32(9), Int32(-2)),
                       (Int32(0), Int32(-11)))
            expected = ao66_i32_hash(abs(a), abs(b), Int32(7), Int32(9))
            @test simulate(c, (a, b)) == expected
        end
    end

    @testset "llvm.sqrt.v2f64" begin
        lane0 = ao66_compile("ao66_sqrt_v2f64_lane0", "ao66_sqrt_v2f64.ll")
        lane1 = ao66_compile("ao66_sqrt_v2f64_lane1", "ao66_sqrt_v2f64.ll")
        cases = ((1.0, 4.0),
                 (0.25, 9.0),
                 (-0.0, Inf),
                 (prevfloat(floatmin(Float64)), 16.0))
        for (a, b) in cases
            ab = reinterpret(UInt64, a)
            bb = reinterpret(UInt64, b)
            @test simulate(lane0, (ab, bb)) == reinterpret(UInt64, sqrt(a))
            @test simulate(lane1, (ab, bb)) == reinterpret(UInt64, sqrt(b))
        end
    end

    @testset "llvm.fma.v2f64" begin
        lane0 = ao66_compile("ao66_fma_v2f64_lane0", "ao66_fma_v2f64.ll")
        lane1 = ao66_compile("ao66_fma_v2f64_lane1", "ao66_fma_v2f64.ll")
        cases = ((1.0, 2.0, 3.0, 4.0, 5.0, 6.0),
                 (1.5, 2.5, 0.25, -2.0, 3.0, 7.0),
                 (1e10, 1e-10, 1.0, -1.0, -1.0, 0.0))
        for (a0, b0, c0, a1, b1, c1) in cases
            bits = reinterpret.(UInt64, (a0, b0, c0, a1, b1, c1))
            @test simulate(lane0, bits) == reinterpret(UInt64, Base.fma(a0, b0, c0))
            @test simulate(lane1, bits) == reinterpret(UInt64, Base.fma(a1, b1, c1))
        end
    end

    @testset "unsupported vector intrinsic fails loud" begin
        err = try
            Bennett.extract_parsed_ir_from_ll(
                joinpath(AO66_LL, "ao66_expect_v4i64_reject.ll");
                entry_function="ao66_expect_v4i64")
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("vector intrinsic llvm.expect.v4i64", err)
        @test occursin("has no scalar intrinsic handler", err)
    end

    @testset "poison immarg vector intrinsic fails loud" begin
        err = try
            Bennett.extract_parsed_ir_from_ll(
                joinpath(AO66_LL, "ao66_abs_poison_v4i32_reject.ll");
                entry_function="ao66_abs_poison_v4i32")
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("llvm.abs.v4i32", err)
        @test occursin("immarg=true", err)
    end

    @testset "float vector min/max fails loud" begin
        err = try
            Bennett.extract_parsed_ir_from_ll(
                joinpath(AO66_LL, "ao66_minimum_v2f64_reject.ll");
                entry_function="ao66_minimum_v2f64")
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("llvm.minimum.v2f64", err)
        @test occursin("integer comparisons", err)
    end

    @testset "llvm.sqrt.v2f32 still rejected" begin
        err = try
            Bennett.extract_parsed_ir_from_ll(
                joinpath(AO66_LL, "ao66_sqrt_v2f32_reject.ll");
                entry_function="ao66_sqrt_v2f32_lane0")
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("llvm.sqrt: only f64 supported", err)
    end
end
