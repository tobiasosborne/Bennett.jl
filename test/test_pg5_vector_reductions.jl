using Test
using Bennett

const PG5_LL = joinpath(@__DIR__, "fixtures", "ll")

function pg5_compile(entry::AbstractString, file::AbstractString)
    parsed = Bennett.extract_parsed_ir_from_ll(joinpath(PG5_LL, file);
                                               entry_function=entry)
    circuit = reversible_compile(parsed)
    @test verify_reversibility(circuit)
    return circuit
end

function pg5_reject(file::AbstractString, entry::AbstractString)
    err = try
        Bennett.extract_parsed_ir_from_ll(joinpath(PG5_LL, file);
                                          entry_function=entry)
        nothing
    catch e
        sprint(showerror, e)
    end
    return err
end

# Bennett-zc50 / U100 contract: simulate returns SIGNED when any input is
# signed, UNSIGNED when all inputs are Unsigned with aligned widths. The
# oracle below mirrors that — Int* inputs → Int* expected, UInt* → UInt*.

@testset "Bennett-pg5: llvm.vector.reduce.* integer reductions" begin
    @testset "reduce.add.v4i32 — sum of 4 lanes" begin
        c = pg5_compile("pg5_reduce_add_v4i32", "pg5_reduce_add_v4i32.ll")
        cases = ((Int32(1), Int32(2), Int32(3), Int32(4)),
                 (Int32(-5), Int32(7), Int32(0), Int32(11)),
                 (Int32(100), Int32(-100), Int32(50), Int32(-50)),
                 (Int32(-1), Int32(-1), Int32(-1), Int32(-1)))
        for (a, b, c0, d) in cases
            expected = a + b + c0 + d   # Int32 wrap; signed-input → signed simulate output
            @test simulate(c, (a, b, c0, d)) == expected
        end
    end

    @testset "reduce.add.v2i64 — sum of 2 lanes (smallest non-trivial width)" begin
        c = pg5_compile("pg5_reduce_add_v2i64", "pg5_reduce_add_v2i64.ll")
        for (a, b) in ((Int64(1), Int64(2)),
                       (Int64(-100), Int64(50)),
                       (typemax(Int64), Int64(1)))    # wraparound
            expected = a + b
            @test simulate(c, (a, b)) == expected
        end
    end

    @testset "reduce.mul.v4i32 — product of 4 lanes" begin
        c = pg5_compile("pg5_reduce_mul_v4i32", "pg5_reduce_mul_v4i32.ll")
        cases = ((Int32(1), Int32(2), Int32(3), Int32(4)),
                 (Int32(-2), Int32(3), Int32(-5), Int32(7)),
                 (Int32(0), Int32(99), Int32(99), Int32(99)),
                 (Int32(2), Int32(2), Int32(2), Int32(2)))
        for (a, b, c0, d) in cases
            expected = a * b * c0 * d
            @test simulate(c, (a, b, c0, d)) == expected
        end
    end

    @testset "reduce.and.v4i32 — bitwise AND of 4 lanes" begin
        c = pg5_compile("pg5_reduce_and_v4i32", "pg5_reduce_and_v4i32.ll")
        cases = ((UInt32(0xFFFFFFFF), UInt32(0xF0F0F0F0), UInt32(0x00FF00FF), UInt32(0xAAAAAAAA)),
                 (UInt32(0x12345678), UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF)),
                 (UInt32(0), UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF), UInt32(0xFFFFFFFF)),
                 (UInt32(0xAAAAAAAA), UInt32(0xCCCCCCCC), UInt32(0xF0F0F0F0), UInt32(0xFF00FF00)))
        for (a, b, c0, d) in cases
            expected = a & b & c0 & d
            @test simulate(c, (a, b, c0, d)) == expected
        end
    end

    @testset "reduce.or.v4i32 — bitwise OR of 4 lanes" begin
        c = pg5_compile("pg5_reduce_or_v4i32", "pg5_reduce_or_v4i32.ll")
        cases = ((UInt32(0x01), UInt32(0x02), UInt32(0x04), UInt32(0x08)),
                 (UInt32(0xF0F0F0F0), UInt32(0x0F0F0F0F), UInt32(0), UInt32(0)),
                 (UInt32(0), UInt32(0), UInt32(0), UInt32(0)),
                 (UInt32(0x12345678), UInt32(0x9ABCDEF0), UInt32(0xCAFEBABE), UInt32(0xDEADBEEF)))
        for (a, b, c0, d) in cases
            expected = a | b | c0 | d
            @test simulate(c, (a, b, c0, d)) == expected
        end
    end

    @testset "reduce.xor.v4i32 — bitwise XOR of 4 lanes" begin
        c = pg5_compile("pg5_reduce_xor_v4i32", "pg5_reduce_xor_v4i32.ll")
        cases = ((UInt32(0xFF), UInt32(0xFF), UInt32(0xFF), UInt32(0xFF)),     # all-equal cancels
                 (UInt32(0x12345678), UInt32(0x9ABCDEF0), UInt32(0), UInt32(0)),
                 (UInt32(0xAAAAAAAA), UInt32(0x55555555), UInt32(0), UInt32(0)),  # complement
                 (UInt32(0xCAFEBABE), UInt32(0xDEADBEEF), UInt32(0xFEEDFACE), UInt32(0xBADC0FFE)))
        for (a, b, c0, d) in cases
            expected = xor(a, b, c0, d)
            @test simulate(c, (a, b, c0, d)) == expected
        end
    end

    @testset "reduce.smax.v4i64 — signed max of 4 lanes" begin
        c = pg5_compile("pg5_reduce_smax_v4i64", "pg5_reduce_smax_v4i64.ll")
        cases = ((Int64(1), Int64(-2), Int64(3), Int64(-4)),
                 (Int64(-100), Int64(-50), Int64(-1), Int64(-200)),  # all negative
                 (typemin(Int64), typemin(Int64) + 1, Int64(-1), Int64(0)),
                 (Int64(0), Int64(0), Int64(0), Int64(0)))
        for lanes in cases
            expected = max(lanes...)
            @test simulate(c, lanes) == expected
        end
    end

    @testset "reduce.smin.v4i64 — signed min of 4 lanes" begin
        c = pg5_compile("pg5_reduce_smin_v4i64", "pg5_reduce_smin_v4i64.ll")
        cases = ((Int64(1), Int64(-2), Int64(3), Int64(-4)),
                 (Int64(100), Int64(50), Int64(1), Int64(200)),       # all positive
                 (typemax(Int64), typemax(Int64) - 1, Int64(1), Int64(0)),
                 (Int64(7), Int64(7), Int64(7), Int64(7)))
        for lanes in cases
            expected = min(lanes...)
            @test simulate(c, lanes) == expected
        end
    end

    @testset "reduce.umax.v4i32 — unsigned max of 4 lanes" begin
        c = pg5_compile("pg5_reduce_umax_v4i32", "pg5_reduce_umax_v4i32.ll")
        cases = ((UInt32(1), UInt32(2), UInt32(3), UInt32(4)),
                 (UInt32(0), UInt32(0), UInt32(0), UInt32(0)),
                 (typemax(UInt32), UInt32(0), UInt32(1), UInt32(2)),  # 0xFFFFFFFF wins
                 (UInt32(0x80000000), UInt32(0x7FFFFFFF), UInt32(0x40000000), UInt32(0x20000000)))
        for lanes in cases
            expected = max(lanes...)
            @test simulate(c, lanes) == expected
        end
    end

    @testset "reduce.umin.v4i32 — unsigned min of 4 lanes" begin
        c = pg5_compile("pg5_reduce_umin_v4i32", "pg5_reduce_umin_v4i32.ll")
        cases = ((UInt32(1), UInt32(2), UInt32(3), UInt32(4)),
                 (typemax(UInt32), typemax(UInt32), typemax(UInt32), typemax(UInt32)),
                 (UInt32(7), UInt32(0), UInt32(99), UInt32(50)),
                 (UInt32(0x80000000), UInt32(0x7FFFFFFF), UInt32(0xFFFFFFFF), UInt32(0xC0000000)))
        for lanes in cases
            expected = min(lanes...)
            @test simulate(c, lanes) == expected
        end
    end

    @testset "reduce.smax.v8i32 — signed max of 8 lanes (second-width coverage)" begin
        c = pg5_compile("pg5_reduce_smax_v8i32", "pg5_reduce_smax_v8i32.ll")
        cases = ((Int32(1), Int32(-2), Int32(3), Int32(-4),
                  Int32(5), Int32(-6), Int32(7), Int32(-8)),                     # max = 7
                 (Int32(-100), Int32(-50), Int32(-1), Int32(-200),
                  Int32(-99), Int32(-1000), Int32(-3), Int32(-7)),               # max = -1
                 (typemin(Int32), Int32(0), Int32(1), Int32(2),
                  Int32(3), Int32(4), Int32(5), Int32(6)))                       # max = 6
        for lanes in cases
            expected = max(lanes...)
            @test simulate(c, lanes) == expected
        end
    end

    @testset "reduce.fadd.v4f64 fails loud (out of scope per pg5)" begin
        err = pg5_reject("pg5_reduce_fadd_v4f64_reject.ll", "pg5_reduce_fadd_v4f64")
        @test err !== nothing
        @test occursin("llvm.vector.reduce.fadd", err)
        @test occursin("Bennett-lx5h", err)
    end
end
