# Bennett-srsy / U103 — multi-language fixtures previously skipped
# silently when an external toolchain (rustc / clang / llvm-as) was
# absent, which let an incomplete CI image quietly bypass entire test
# corpora. Each missing-toolchain branch now consults `BENNETT_CI` and
# promotes the skip to a hard `error()` when the env var is `1`.
#
# This file does NOT actually invoke the corpus tests under
# `BENNETT_CI=1` (that would fail-loud on any contributor without
# the full toolchain) — instead it pins, by static inspection of the
# three test files, that:
#   1. `BENNETT_CI` is consulted in each guard.
#   2. The error message in each guard mentions `BENNETT_CI=1` and
#      attributes the bead so a future contributor sees where the
#      hard-fail came from.

using Test
using Bennett

const _SRSY_GUARDED_FILES = [
    "test_t5_corpus_rust.jl",
    "test_t5_corpus_c.jl",
    "test_p5b_bc_ingest.jl",
]

@testset "Bennett-srsy / U103 — CI toolchain guards" begin

    @testset "guards present in each toolchain-dependent test" begin
        for fname in _SRSY_GUARDED_FILES
            path = joinpath(@__DIR__, fname)
            src = read(path, String)
            @testset "$fname" begin
                @test occursin("BENNETT_CI", src)
                @test occursin("BENNETT_CI=1", src)
                @test occursin("Bennett-srsy", src)
            end
        end
    end

    @testset "default (no BENNETT_CI) skip behaviour preserved" begin
        # Confirm each file still emits the @info skip + @test_skip
        # path so a local contributor without the toolchain isn't
        # blocked from running the suite.
        for fname in _SRSY_GUARDED_FILES
            src = read(joinpath(@__DIR__, fname), String)
            @testset "$fname keeps local-skip path" begin
                @test occursin("@info", src)
                @test occursin("@test_skip", src)
            end
        end
    end

    @testset "BENNETT_CI default is off in this Pkg.test invocation" begin
        # The full-suite Pkg.test we run today does NOT set BENNETT_CI,
        # so the corpus tests are still gated on toolchain availability.
        # If a future agent flips this default they should also update
        # the test_t5_corpus_* + test_p5b_bc_ingest paths so partial
        # toolchain images don't error on contributors who haven't opted in.
        @test get(ENV, "BENNETT_CI", "0") != "1" || @info(
            "BENNETT_CI=1 is set; toolchain-dependent tests will hard-fail " *
            "on missing rustc/clang/llvm-as.")
    end
end
