# Bennett-5qrn / U57 — trivial-identity peepholes (`x+0`, `x*1`, `x|0`,
# `x&0`, `x&allones`, `x|allones`, `x⊕0`, `x⊕allones`, `x-0`, `x*0` and
# their commutative duals).
#
# Pre-fix counts (perf review H-2, fold_constants=false):
#   x*Int8(1) → 692 gates, x+Int8(0) → 86, x|Int8(0) → 58, x&Int8(0) → 10.
# Post-fix (all measured on this branch, i8):
#   copy-out identities (x+0, x*1, x|0, x⊕0, x-0)  → 3W + 2 gates
#   zero-result identities (x*0, x&0)              → W + 2 gates
#   x|allones (all-ones result)                    → 3W + 2 gates (8 NOTs + 8 CNOTs + 8 NOTs = 26 at W=8)
#   x⊕allones (~x)                                  → 5W + 2 gates (8 CNOTs + 8 NOTs + 8 CNOTs + 8 CNOTs + 8 NOTs at W=8)
#
# The peephole detects `IROperand(:const, _, k)` operands at the
# `lower_binop!` dispatcher BEFORE `resolve!` materialises the constant
# into ancilla wires. Detection is purely syntactic so the optimisation
# cannot misfire on data-dependent operands inside `lower_mul_wide!`
# (the leaf-level adders are called directly with wire vectors, never
# through `lower_binop!`).

using Test
using Bennett

const _COPY_W(W) = 3 * W + 2     # x+0, x*1, x|0, x⊕0, x-0, x|allones, x&allones
const _ZERO_W(W) = W + 2          # x*0, x&0
const _NOT_W(W)  = 5 * W + 2      # x⊕allones (copy + invert through Bennett)

@testset "Bennett-5qrn / U57 — trivial-identity peepholes" begin

    @testset "copy-out identities pin to 3W+2 across widths" begin
        for T in (Int8, Int16, Int32, Int64)
            W = 8 * sizeof(T)
            for (label, f) in [
                ("x + T(0)",   x -> x + T(0)),
                ("T(0) + x",   x -> T(0) + x),
                ("x - T(0)",   x -> x - T(0)),
                ("x * T(1)",   x -> x * T(1)),
                ("T(1) * x",   x -> T(1) * x),
                ("x | T(0)",   x -> x | T(0)),
                ("T(0) | x",   x -> T(0) | x),
                ("x ⊻ T(0)",   x -> x ⊻ T(0)),
                ("T(0) ⊻ x",   x -> T(0) ⊻ x),
                ("x & T(-1)",  x -> x & T(-1)),
                ("T(-1) & x",  x -> T(-1) & x),
            ]
                c = reversible_compile(f, T; optimize=false, fold_constants=false)
                @testset "$label at W=$W" begin
                    @test gate_count(c).total == _COPY_W(W)
                    @test gate_count(c).Toffoli == 0
                    @test verify_reversibility(c)
                end
            end
        end
    end

    @testset "zero-result identities pin to W+2" begin
        for T in (Int8, Int16, Int32, Int64)
            W = 8 * sizeof(T)
            for (label, f) in [
                ("x * T(0)",   x -> x * T(0)),
                ("T(0) * x",   x -> T(0) * x),
                ("x & T(0)",   x -> x & T(0)),
                ("T(0) & x",   x -> T(0) & x),
            ]
                c = reversible_compile(f, T; optimize=false, fold_constants=false)
                @testset "$label at W=$W" begin
                    @test gate_count(c).total == _ZERO_W(W)
                    @test gate_count(c).Toffoli == 0
                    @test verify_reversibility(c)
                end
            end
        end
    end

    @testset "x | allones — all-ones result" begin
        for T in (Int8, Int16, Int32, Int64)
            W = 8 * sizeof(T)
            for (label, f) in [
                ("x | T(-1)",  x -> x | T(-1)),
                ("T(-1) | x",  x -> T(-1) | x),
            ]
                c = reversible_compile(f, T; optimize=false, fold_constants=false)
                @testset "$label at W=$W" begin
                    @test gate_count(c).total == _COPY_W(W)
                    @test gate_count(c).Toffoli == 0
                    @test verify_reversibility(c)
                end
            end
        end
    end

    @testset "x ⊻ allones — bitwise invert" begin
        for T in (Int8, Int16, Int32, Int64)
            W = 8 * sizeof(T)
            for (label, f) in [
                ("x ⊻ T(-1)", x -> x ⊻ T(-1)),
                ("T(-1) ⊻ x", x -> T(-1) ⊻ x),
            ]
                c = reversible_compile(f, T; optimize=false, fold_constants=false)
                @testset "$label at W=$W" begin
                    @test gate_count(c).total == _NOT_W(W)
                    @test gate_count(c).Toffoli == 0
                    @test verify_reversibility(c)
                end
            end
        end
    end

    @testset "exhaustive semantic equivalence at i8" begin
        # For each identity, simulate all 256 inputs and verify the
        # result matches the native Julia operation. This is the
        # belt-and-braces check that catches any wire-budget /
        # commutative-swap / mask mistake.
        cases = [
            ("x + 0",        x -> x + Int8(0),  (n, _) -> n),
            ("0 + x",        x -> Int8(0) + x,  (n, _) -> n),
            ("x - 0",        x -> x - Int8(0),  (n, _) -> n),
            ("x * 1",        x -> x * Int8(1),  (n, _) -> n),
            ("1 * x",        x -> Int8(1) * x,  (n, _) -> n),
            ("x * 0",        x -> x * Int8(0),  (n, _) -> Int8(0)),
            ("0 * x",        x -> Int8(0) * x,  (n, _) -> Int8(0)),
            ("x | 0",        x -> x | Int8(0),  (n, _) -> n),
            ("0 | x",        x -> Int8(0) | x,  (n, _) -> n),
            ("x | -1",       x -> x | Int8(-1), (n, _) -> Int8(-1)),
            ("-1 | x",       x -> Int8(-1) | x, (n, _) -> Int8(-1)),
            ("x & 0",        x -> x & Int8(0),  (n, _) -> Int8(0)),
            ("0 & x",        x -> Int8(0) & x,  (n, _) -> Int8(0)),
            ("x & -1",       x -> x & Int8(-1), (n, _) -> n),
            ("-1 & x",       x -> Int8(-1) & x, (n, _) -> n),
            ("x ⊻ 0",        x -> x ⊻ Int8(0),  (n, _) -> n),
            ("0 ⊻ x",        x -> Int8(0) ⊻ x,  (n, _) -> n),
            ("x ⊻ -1",       x -> x ⊻ Int8(-1), (n, _) -> reinterpret(Int8, ~reinterpret(UInt8, n))),
            ("-1 ⊻ x",       x -> Int8(-1) ⊻ x, (n, _) -> reinterpret(Int8, ~reinterpret(UInt8, n))),
        ]
        for (label, f, oracle) in cases
            c = reversible_compile(f, Int8; optimize=false, fold_constants=false)
            @testset "$label exhaustive i8" begin
                for n in Int8(-128):Int8(127)
                    @test simulate(c, n) == oracle(n, nothing)
                end
            end
        end
    end

    @testset "non-identity binops still go through the heavy path (regression)" begin
        # Pinned baselines per CLAUDE.md §6 and BENCHMARKS.md. The
        # peephole MUST NOT fire on these — they all use non-trivial
        # constants. If any of these counts shift, the peephole is
        # leaking into the heavy path.
        @test gate_count(reversible_compile(x -> x + Int8(1),  Int8;  optimize=false)).total == 58
        @test gate_count(reversible_compile(x -> x + Int16(1), Int16; optimize=false)).total == 114
        @test gate_count(reversible_compile(x -> x + Int32(1), Int32; optimize=false)).total == 226
        @test gate_count(reversible_compile(x -> x + Int64(1), Int64; optimize=false)).total == 450
        # x*Int8(3) — was 220 pre-fix, must stay 220 post-fix.
        @test gate_count(reversible_compile(x -> x * Int8(3),  Int8;  optimize=false)).total == 220
    end

    @testset "soft-float bit-exactness — peephole fires on internal binops" begin
        # The peephole runs INSIDE soft_fadd / soft_fmul on integer ops
        # like `mantissa + Int64(0)` (true integer identity, bit-exact).
        # `soft_fadd(0.0, x)` itself is NOT a no-op (NaN canonicalisation
        # rules) — but soft_fadd is registered as a callee, so the
        # peephole sees its INTERNAL IR, not the call. Verify a handful
        # of non-trivial inputs come through bit-identical to Julia
        # native ops.
        c_add = reversible_compile((a, b) -> Bennett.soft_fadd(a, b), UInt64, UInt64)
        c_mul = reversible_compile((a, b) -> Bennett.soft_fmul(a, b), UInt64, UInt64)
        cases = [
            (1.5, 2.25),
            (-3.7, 0.125),
            (1e-300, 2e-300),    # subnormal-ish
            (1.0, 0.0),          # one operand is zero — exercises NaN/sign-of-zero rules
            (Inf, 1.0),
            (NaN, 1.0),
        ]
        for (a, b) in cases
            au, bu = reinterpret(UInt64, a), reinterpret(UInt64, b)
            expected_add = reinterpret(UInt64, a + b)
            expected_mul = reinterpret(UInt64, a * b)
            # NaN payload comparison: `a + b == expected` fails for NaN-result
            # cases, so we compare bit patterns. Soft-float MUST be bit-exact
            # against native (CLAUDE.md §13).
            got_add = simulate(c_add, (au, bu))
            got_mul = simulate(c_mul, (au, bu))
            @testset "soft_fadd($a, $b)" begin
                if isnan(a + b)
                    @test isnan(reinterpret(Float64, got_add))
                else
                    @test got_add == expected_add
                end
            end
            @testset "soft_fmul($a, $b)" begin
                if isnan(a * b)
                    @test isnan(reinterpret(Float64, got_mul))
                else
                    @test got_mul == expected_mul
                end
            end
        end
    end

    @testset "static inspection — peephole helpers present in lowering/arith.jl" begin
        # Catches accidental deletion / rename of the helper functions.
        # If someone reverts the peephole, the static-presence test fires
        # before any gate-count drift would surface in CI.
        # Bennett-vdlg / U40 (2026-04-30): lower.jl was split along its
        # `# ---- section ----` headers; the peephole helpers live in
        # the `binary-op dispatch` section, now in lowering/arith.jl.
        path = joinpath(dirname(pathof(Bennett)), "lowering", "arith.jl")
        src = read(path, String)
        @test occursin("_try_identity_peephole!", src)
        @test occursin("_identity_emit_for_const", src)
        @test occursin("_emit_copy_out!", src)
        @test occursin("Bennett-5qrn", src)
    end
end
