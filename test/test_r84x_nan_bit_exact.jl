using Test
using Bennett: soft_fadd, soft_fsub, soft_fmul, soft_fdiv, soft_fma, soft_fsqrt,
               soft_trunc, soft_floor, soft_ceil, soft_fptosi

# Bennett-r84x / U08 — NaN bit patterns and invalid-op results must be
# bit-exact against x86 hardware (Julia's native Float64 ops on x86_64 /
# LLVM `fsqrt` / LLVM `fptosi i64`) per CLAUDE.md §13.
#
# Pre-fix: every NaN-producing path returned a canonical `0x7FF8...`,
# dropping input NaN payloads and the x86 "indefinite" sign; `soft_fptosi`
# returned 0 on overflow/NaN rather than saturating to INT_MIN.
#
# Reference pattern — x86 SSE:
#   invalid-op result  : 0xFFF8000000000000 (negative qNaN, payload 0)
#   NaN propagation    : first-operand rule; preserve sign + payload;
#                        OR the quiet bit (bit 51) to canonicalise sNaN.
#   fptosi overflow/NaN: 0x8000000000000000 (INT_MIN = -2^63).

const PINF    = UInt64(0x7FF0000000000000)
const NINF    = UInt64(0xFFF0000000000000)
const PZERO   = UInt64(0x0000000000000000)
const NZERO   = UInt64(0x8000000000000000)
const INDEF   = UInt64(0xFFF8000000000000)
const QUIET   = UInt64(0x0008000000000000)
const SNAN_P1 = UInt64(0x7FF0000000000001)   # sNaN: quiet bit 51 clear, payload = 1
const SNAN_N1 = UInt64(0xFFF0000000000001)
# qNaN: quiet bit 51 set + a distinguishing payload in bits 50..0 so that
# a correct implementation preserves payload rather than canonicalising.
const QNAN_P  = UInt64(0x7FFC000000000000)
const QNAN_N  = UInt64(0xFFFC000000000000)
const ONE     = reinterpret(UInt64, 1.0)
const TWO     = reinterpret(UInt64, 2.0)
const THREE   = reinterpret(UInt64, 3.0)

# Hardware ground truth helpers — bypass Julia's DomainError/argument checks.
@inline hw_sqrt_bits(x::Float64) = reinterpret(UInt64, Base.sqrt_llvm(x))
@inline function hw_fptosi(x::Float64)::Int64
    Base.llvmcall("""
        %r = fptosi double %0 to i64
        ret i64 %r
    """, Int64, Tuple{Float64}, x)
end

@testset "Bennett-r84x NaN + invalid-op bit-exactness" begin

    # T1 — invalid-op producers must emit the x86 indefinite value.
    @testset "T1 invalid-op producers → 0xFFF8000000000000" begin
        # fadd / fsub: Inf − Inf
        @test soft_fadd(PINF, NINF) == INDEF
        @test soft_fadd(NINF, PINF) == INDEF
        @test soft_fsub(PINF, PINF) == INDEF
        @test soft_fsub(NINF, NINF) == INDEF
        # fmul: ±Inf × ±0
        @test soft_fmul(PINF, PZERO) == INDEF
        @test soft_fmul(PINF, NZERO) == INDEF
        @test soft_fmul(NINF, PZERO) == INDEF
        @test soft_fmul(PZERO, PINF) == INDEF
        @test soft_fmul(NZERO, NINF) == INDEF
        # fdiv: 0/0 and Inf/Inf
        @test soft_fdiv(PZERO, PZERO) == INDEF
        @test soft_fdiv(NZERO, PZERO) == INDEF
        @test soft_fdiv(PZERO, NZERO) == INDEF
        @test soft_fdiv(PINF, PINF) == INDEF
        @test soft_fdiv(NINF, PINF) == INDEF
        @test soft_fdiv(PINF, NINF) == INDEF
        # fsqrt: negative finite and -Inf
        @test soft_fsqrt(reinterpret(UInt64, -1.0)) == INDEF
        @test soft_fsqrt(reinterpret(UInt64, -2.5)) == INDEF
        @test soft_fsqrt(NINF) == INDEF
        # fma: prod_is_inf + c_inf opposite signs  (Inf·1 + (-Inf) etc.)
        @test soft_fma(PINF, ONE, NINF) == INDEF
        @test soft_fma(NINF, ONE, PINF) == INDEF
        # fma: 0·Inf invalid regardless of c (when c is not NaN)
        @test soft_fma(PZERO, PINF, ONE) == INDEF
        @test soft_fma(NINF, PZERO, ONE) == INDEF
    end

    # T2 — sqrt(-0) = -0 (IEEE 754 §5.4.1); NOT an invalid op.
    @testset "T2 sqrt(-0) preserved" begin
        @test soft_fsqrt(NZERO) == NZERO
        @test soft_fsqrt(PZERO) == PZERO
    end

    # T3 — NaN propagation: first-operand rule, preserve sign + payload,
    #       quiet sNaN.
    @testset "T3 NaN passthrough — fadd / fsub / fmul / fdiv" begin
        # qNaN preserved exactly (quiet bit already set).
        @test soft_fadd(QNAN_P, ONE)    == QNAN_P
        @test soft_fadd(ONE, QNAN_P)    == QNAN_P
        @test soft_fadd(QNAN_N, ONE)    == QNAN_N
        @test soft_fmul(QNAN_P, TWO)    == QNAN_P
        @test soft_fdiv(QNAN_P, TWO)    == QNAN_P
        @test soft_fsub(QNAN_P, ONE)    == QNAN_P
        # sNaN input must emerge quieted (payload + sign preserved).
        @test soft_fadd(SNAN_P1, ONE)   == (SNAN_P1 | QUIET)
        @test soft_fadd(ONE, SNAN_P1)   == (SNAN_P1 | QUIET)
        @test soft_fmul(SNAN_N1, TWO)   == (SNAN_N1 | QUIET)
        @test soft_fdiv(SNAN_P1, TWO)   == (SNAN_P1 | QUIET)
        # Two NaNs: first operand wins (x86 SSE rule).
        @test soft_fadd(QNAN_P, QNAN_N) == QNAN_P
        @test soft_fmul(QNAN_N, QNAN_P) == QNAN_N
    end

    # T4 — fma NaN propagation: a-first, then b, then c.
    @testset "T4 NaN passthrough — fma" begin
        @test soft_fma(QNAN_P, TWO,   THREE)    == QNAN_P
        @test soft_fma(TWO,    QNAN_N, THREE)    == QNAN_N
        @test soft_fma(TWO,    THREE,  QNAN_P)   == QNAN_P
        @test soft_fma(SNAN_P1, TWO,   THREE)    == (SNAN_P1 | QUIET)
        @test soft_fma(TWO,    SNAN_N1, THREE)   == (SNAN_N1 | QUIET)
        @test soft_fma(TWO,    THREE,  SNAN_P1)  == (SNAN_P1 | QUIET)
        # NaN wins over invalid-op.
        @test soft_fma(PINF, PZERO, QNAN_P)      == QNAN_P
        @test soft_fma(PINF, ONE,   QNAN_N)      == QNAN_N
    end

    # T5 — fsqrt NaN quieted; negative NaN sign preserved.
    @testset "T5 NaN passthrough — fsqrt" begin
        @test soft_fsqrt(QNAN_P)  == QNAN_P
        @test soft_fsqrt(QNAN_N)  == QNAN_N
        @test soft_fsqrt(SNAN_P1) == (SNAN_P1 | QUIET)
        @test soft_fsqrt(SNAN_N1) == (SNAN_N1 | QUIET)
        # Hardware cross-check (sqrt_llvm).
        for bits in UInt64[QNAN_P, QNAN_N, SNAN_P1, SNAN_N1]
            @test soft_fsqrt(bits) == hw_sqrt_bits(reinterpret(Float64, bits))
        end
    end

    # T6 — trunc / floor / ceil: sNaN must quiet; ±Inf must pass through
    #       unchanged (Inf is NOT NaN).
    @testset "T6 rounding quiets sNaN, preserves Inf" begin
        @test soft_trunc(QNAN_P)  == QNAN_P
        @test soft_trunc(QNAN_N)  == QNAN_N
        @test soft_trunc(SNAN_P1) == (SNAN_P1 | QUIET)
        @test soft_trunc(SNAN_N1) == (SNAN_N1 | QUIET)
        @test soft_floor(QNAN_P)  == QNAN_P
        @test soft_floor(SNAN_P1) == (SNAN_P1 | QUIET)
        @test soft_ceil(QNAN_P)   == QNAN_P
        @test soft_ceil(SNAN_N1)  == (SNAN_N1 | QUIET)
        # Inf stays Inf (the Inf-vs-NaN split inside is_special).
        @test soft_trunc(PINF) == PINF
        @test soft_trunc(NINF) == NINF
        @test soft_floor(PINF) == PINF
        @test soft_ceil(NINF)  == NINF
    end

    # T7 — fptosi saturates to INT_MIN = 0x8000000000000000 on NaN/Inf/OOB.
    @testset "T7 fptosi saturates to INT_MIN" begin
        cases = [Inf, -Inf, NaN, 1e30, -1e30, 2.0^63, -2.0^63 - 2.0^11]
        for x in cases
            @test reinterpret(Int64, soft_fptosi(reinterpret(UInt64, x))) ==
                  hw_fptosi(x)
        end
        # In-range round-trip anchors.
        for x in Float64[0.0, -0.0, 1.0, -1.0, 1.5, -1.5, 2.0^62, -2.0^62, 12345.678]
            @test reinterpret(Int64, soft_fptosi(reinterpret(UInt64, x))) ==
                  hw_fptosi(x)
        end
    end

    # T8 — regression anchors: non-NaN paths unaffected by the fix.
    @testset "T8 non-NaN regression" begin
        for (a, b) in [(1.0, 2.0), (3.14, -1.0), (0.1, 0.2), (1e-200, 2e-200)]
            ab = reinterpret(UInt64, a); bb = reinterpret(UInt64, b)
            @test soft_fadd(ab, bb) == reinterpret(UInt64, a + b)
            @test soft_fsub(ab, bb) == reinterpret(UInt64, a - b)
            @test soft_fmul(ab, bb) == reinterpret(UInt64, a * b)
            @test soft_fdiv(ab, bb) == reinterpret(UInt64, a / b)
        end
        @test soft_fsqrt(reinterpret(UInt64, 2.0)) == reinterpret(UInt64, sqrt(2.0))
        @test soft_fsqrt(reinterpret(UInt64, 0.25)) == reinterpret(UInt64, sqrt(0.25))
    end
end
