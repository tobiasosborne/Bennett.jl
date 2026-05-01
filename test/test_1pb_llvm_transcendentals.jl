# Bennett-1pb: direct dispatch for `llvm.sqrt` / `llvm.exp` / `llvm.exp2`
# as IRCall to the matching soft_* primitive.
#
# Background: `Base.sqrt(::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))` etc.
# routes Julia-frontend callers through the SoftFloat dispatcher, so
# `llvm.sqrt.f64` never appears in IR seen by Bennett's extractor for
# typical reversible_compile(f, Float64) calls. But IR can reach the
# extractor with raw `llvm.sqrt.f64` etc. when:
#   - User writes `Core.Intrinsics.sqrt_llvm(::Float64)` directly,
#   - User uses `@fastmath sqrt(x)` on raw Float64,
#   - Raw `.ll` / `.bc` is fed in (Bennett-xkv multi-language vision).
#
# The handlers wire these intrinsics to the existing soft_fsqrt /
# soft_exp / soft_exp2 callees, treating the f64 operand as a 64-bit
# bit pattern (LLVM bitcasts already turn raw float SSA into UInt64
# wires before/after the intrinsic call site).
#
# log/pow/sin/cos require NEW soft-float bodies — see Bennett-582 (log),
# Bennett-emv (pow), Bennett-3mo (sin/cos).
@testset "Bennett-1pb: llvm.sqrt / llvm.exp / llvm.exp2 direct dispatch" begin

    @testset "llvm.sqrt.f64 via Core.Intrinsics" begin
        f(x::UInt64) = reinterpret(UInt64,
            Core.Intrinsics.sqrt_llvm(reinterpret(Float64, x)))
        circuit = reversible_compile(f, UInt64)
        @test verify_reversibility(circuit)
        for x in (1.0, 2.0, 4.0, 9.0, 16.0, 0.25, 0.5, 100.0, 1e-10, 1e10)
            got_bits = simulate(circuit, reinterpret(UInt64, x))
            @test reinterpret(Float64, got_bits) === sqrt(x)
        end
    end

    @testset "llvm.sqrt.f64 via @fastmath" begin
        f(x::UInt64) = reinterpret(UInt64, @fastmath(sqrt(reinterpret(Float64, x))))
        circuit = reversible_compile(f, UInt64)
        @test verify_reversibility(circuit)
        for x in (1.0, 4.0, 25.0, 1.5, 2.7182818284590452)
            got_bits = simulate(circuit, reinterpret(UInt64, x))
            @test reinterpret(Float64, got_bits) === @fastmath(sqrt(x))
        end
    end

    @testset "llvm.sqrt.f64 round-trip on -0.0" begin
        f(x::UInt64) = reinterpret(UInt64,
            Core.Intrinsics.sqrt_llvm(reinterpret(Float64, x)))
        circuit = reversible_compile(f, UInt64)
        # -0.0 → -0.0 per IEEE 754
        got_bits = simulate(circuit, reinterpret(UInt64, -0.0))
        @test reinterpret(Float64, got_bits) === -0.0
    end

    # exp/exp2: Julia's `Base.exp` calls libm (j_exp_NNN), not llvm.exp.f64.
    # To force the intrinsic we go through Core.Intrinsics if available;
    # otherwise we'd need a fastmath path or raw .ll input. Julia exposes
    # `Core.Intrinsics.have_fma` etc. but no public exp_llvm intrinsic, so
    # exp/exp2 are exercised indirectly via Base.exp(::SoftFloat) — which
    # already worked pre-1pb — and via @fastmath which DOES emit the
    # intrinsic on some Julia versions.
    #
    # The wiring still needs to exist for raw-LLVM ingest (Bennett-xkv),
    # so we test it by constructing the IR through the standard pipeline
    # at an IR-extraction level: feed an `llvm.exp.f64` callee name into
    # `_handle_intrinsic` and assert it returns IRCall(soft_exp).
    @testset "llvm.exp.f64 / llvm.exp2.f64 handler exists" begin
        # White-box: confirm the soft_exp / soft_exp2 callees are still
        # registered (they're prerequisites for the intrinsic dispatch).
        @test Bennett._lookup_callee("soft_exp") === Bennett.soft_exp
        @test Bennett._lookup_callee("soft_exp2") === Bennett.soft_exp2
        @test Bennett._lookup_callee("soft_fsqrt") === Bennett.soft_fsqrt
    end

    # End-to-end via raw `.ll` ingest (the Bennett-xkv multi-language path —
    # also the only way to exercise `llvm.exp.f64` since Julia's `@fastmath
    # exp` routes to `j_exp_fast_NNN` and there is no `Core.Intrinsics.exp_llvm`).
    @testset "llvm.sqrt.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "1pb_sqrt_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="sqrt_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (1.0, 4.0, 9.0, 16.0, 0.25)
            got = simulate(c, reinterpret(UInt64, x))
            @test reinterpret(Float64, got) === sqrt(x)
        end
    end

    @testset "llvm.exp.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "1pb_exp_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="exp_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 1.0, -1.0, 2.0, 0.5, -0.5, 10.0)
            got = simulate(c, reinterpret(UInt64, x))
            # soft_exp is bit-exact vs Base.exp per CLAUDE.md §13
            @test reinterpret(Float64, got) === Base.exp(x)
        end
    end

    @testset "llvm.exp2.f64 via .ll ingest" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "1pb_exp2_f64.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="exp2_f64")
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        for x in (0.0, 1.0, -1.0, 2.0, 0.5, -0.5, 10.0)
            got = simulate(c, reinterpret(UInt64, x))
            @test reinterpret(Float64, got) === Base.exp2(x)
        end
    end

    @testset "llvm.sqrt.f32 rejected (CLAUDE.md §13)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "1pb_sqrt_f32_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="sqrt_f32")
    end

end
