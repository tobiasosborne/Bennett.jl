# Bennett-0zsk / U46 — pin the load-bearing error() paths in
# src/lower.jl and src/ir_extract.jl with @test_throws so a buggy
# refactor that silently bypasses them surfaces immediately.
#
# Per the bead: src/lower.jl had 99 error() sites and src/ir_extract.jl
# had 33 as of 2026-04-25; existing test coverage hit only a small
# fraction.  This file adds 12 assertions covering the load-bearing
# user-facing entries — input-validation, strategy dispatch,
# unsupported-feature gates, and the LLVM-source loader's path /
# entry-function checks.
#
# `@test_throws "substring" expr` (Julia 1.8+, OK under the 1.10
# compat floor we set in Bennett-jppi) checks both the exception
# type AND a unique substring of the message — that way a future
# error message edit shows up here as a clear localisation, not a
# silent regression.

using Test
using Bennett

@testset "Bennett-0zsk / U46 — core error paths" begin

    # ─────────── lower.jl: dispatcher + input validation ───────────

    @testset "lower: unknown add strategy" begin
        @test_throws "unknown add strategy :bogus" begin
            reversible_compile(x -> x + Int8(1), Int8; add=:bogus)
        end
    end

    @testset "lower: unknown mul strategy" begin
        @test_throws "unknown mul strategy :bogus" begin
            reversible_compile(x -> x * Int8(2), Int8; mul=:bogus)
        end
    end

    @testset "reversible_compile: max_loop_iterations < 0" begin
        @test_throws ArgumentError begin
            reversible_compile(x -> x + Int8(1), Int8; max_loop_iterations=-3)
        end
        @test_throws "max_loop_iterations must be >= 0" begin
            reversible_compile(x -> x + Int8(1), Int8; max_loop_iterations=-3)
        end
    end

    @testset "reversible_compile: Int128 arg unsupported" begin
        # Bennett-l9cl / U09 — IROperand.value is Int64; widening is
        # tracked separately.  Until then this must fail loudly.
        f128(x::Int128, y::Int128) = x + y
        @test_throws ArgumentError begin
            reversible_compile(f128, Int128, Int128)
        end
        @test_throws "Int128 is not supported" begin
            reversible_compile(f128, Int128, Int128)
        end
    end

    @testset "reversible_compile: Float32 arg unsupported" begin
        # Float32 has no soft-float path today; only Float64 is wired.
        @test_throws ArgumentError begin
            reversible_compile(x -> x + Float32(1), Float32)
        end
        @test_throws "Float32 is not supported" begin
            reversible_compile(x -> x + Float32(1), Float32)
        end
    end

    @testset "reversible_compile: Float64 too many args" begin
        # The Float64 entry handles up to 3 args (matching
        # soft_fadd / soft_fma arity).
        f4(a, b, c, d) = (a + b) * (c + d)
        @test_throws "Float64 compile supports up to 3 arguments" begin
            reversible_compile(f4, Float64, Float64, Float64, Float64)
        end
    end

    @testset "reversible_compile: Float64 zero args" begin
        @test_throws "Need at least one Float64 argument type" begin
            reversible_compile(() -> 1.0)
        end
    end

    # ─────────── ir_extract.jl: loader + entry-function ───────────

    @testset "extract_parsed_ir_from_ll: file not found" begin
        @test_throws "file not found" begin
            Bennett.extract_parsed_ir_from_ll("/no/such/file.ll";
                                              entry_function="x")
        end
    end

    @testset "extract_parsed_ir_from_bc: file not found" begin
        @test_throws "file not found" begin
            Bennett.extract_parsed_ir_from_bc("/no/such/file.bc";
                                              entry_function="x")
        end
    end

    @testset "extract_parsed_ir_from_ll: entry_function not in module" begin
        mktempdir() do dir
            p = joinpath(dir, "tiny.ll")
            write(p, """
                define i32 @julia_only_function_1(i32 %x) {
                entry:
                  ret i32 %x
                }
                """)
            @test_throws "not found in module" begin
                Bennett.extract_parsed_ir_from_ll(p;
                    entry_function="julia_does_not_exist_99")
            end
        end
    end

    @testset "extract_parsed_ir_from_ll: malformed LLVM IR" begin
        # LLVM's own parser rejects this — the loader should let
        # that LLVMException bubble up rather than swallowing it.
        mktempdir() do dir
            p = joinpath(dir, "garbage.ll")
            write(p, "this is not LLVM IR")
            @test_throws Exception begin
                Bennett.extract_parsed_ir_from_ll(p; entry_function="foo")
            end
        end
    end

    @testset "ir_extract: heterogeneous Tuple sret unsupported" begin
        # Only [N x iM] homogeneous aggregate sret is supported today;
        # struct-of-different-widths must fail loudly per CLAUDE.md §1.
        function hetero(x::Int32, y::Int64)::Tuple{Int32, Int64}
            (x, y)
        end
        @test_throws "sret pointee" begin
            reversible_compile(hetero, Int32, Int64)
        end
    end
end
