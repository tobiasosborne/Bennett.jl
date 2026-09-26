# Bennett-qa2g: `simulate` silently truncated wide values (Astra 2026-09-26
# B-circuit-core F6).
#
# Two holes in src/simulator.jl:
#   (1) `_assert_input_fits` returned early for widths >= 64, so any Integer
#       (UInt128, Int128, BigInt) fed to a 64-bit input wrapped silently:
#       simulate(reversible_compile(identity, UInt64; strategy=:expression),
#                UInt128(1) << 64) returned 0.
#   (2) `_read_int` accumulated every output element into a UInt64, so a
#       >64-bit output element lost its high bits (a hand-built 128-wire
#       identity returned 0 for UInt128(1) << 100).
#
# Post-fix contract: every Integer input is range-checked against the
# declared width's combined signed/unsigned interval [-2^(w-1), 2^w) at ALL
# widths; output elements wider than 64 bits are rejected loudly (wide
# decoding is not implemented).

using Test
using Bennett
using Bennett: ReversibleCircuit, ReversibleGate, CNOTGate,
               simulate, verify_reversibility, reversible_compile

# w-bit identity: inputs 1:w copied onto outputs w+1:2w.
_qa2g_identity(w) = ReversibleCircuit(2w, ReversibleGate[CNOTGate(i, w + i) for i in 1:w],
                                      collect(1:w), collect(w+1:2w), Int[], [w], [w])
# w-bit input, 1-bit output = top input bit (lets us probe input widths > 64
# without needing a > 64-bit output decode).
_qa2g_topbit(w) = ReversibleCircuit(w + 1, ReversibleGate[CNOTGate(w, w + 1)],
                                    collect(1:w), [w + 1], Int[], [w], [1])

@testset "Bennett-qa2g: simulate rejects wide values instead of truncating" begin

    @testset "63-bit input boundaries" begin
        c = _qa2g_identity(63)
        hi = (UInt64(1) << 63) - 1                # 2^63 - 1: max unsigned
        @test simulate(c, UInt64, hi) == hi
        @test simulate(c, UInt64, UInt64(0)) == 0
        @test_throws ArgumentError simulate(c, UInt64(1) << 63)      # 2^63
        @test_throws ArgumentError simulate(c, typemax(UInt64))
        lo = -(Int64(1) << 62)                    # -2^62: min signed
        @test simulate(c, UInt64, lo) == UInt64(1) << 62   # 63-bit pattern 100…0
        @test_throws ArgumentError simulate(c, lo - 1)
        @test_throws ArgumentError simulate(c, typemin(Int64))
    end

    @testset "64-bit input boundaries" begin
        c = _qa2g_identity(64)
        @test simulate(c, typemax(UInt64)) === typemax(UInt64)
        @test simulate(c, typemin(Int64)) === typemin(Int64)
        @test simulate(c, typemax(Int64)) === typemax(Int64)
        @test simulate(c, UInt64(0)) === UInt64(0)
        # Values outside [-2^63, 2^64) must be rejected, not wrapped.
        @test_throws ArgumentError simulate(c, UInt128(1) << 64)
        @test_throws ArgumentError simulate(c, typemax(UInt128))
        @test_throws ArgumentError simulate(c, typemin(Int128))
        @test_throws ArgumentError simulate(c, Int128(typemin(Int64)) - 1)
        @test_throws ArgumentError simulate(c, big(2)^64)
        @test_throws ArgumentError simulate(c, -big(2)^63 - 1)
        # In-range wide-typed values are accepted and ingested bit-exactly.
        @test simulate(c, UInt64, UInt128(typemax(UInt64))) === typemax(UInt64)
        @test simulate(c, UInt64, big(2)^64 - 1) === typemax(UInt64)
        @test simulate(c, Int64, -big(2)^63) === typemin(Int64)
        @test simulate(c, Int64, Int128(-5)) === Int64(-5)
        @test simulate(c, UInt64, big(12345)) === UInt64(12345)
        err = try simulate(c, UInt128(1) << 64); nothing catch e; e end
        @test err isa ArgumentError && occursin("does not fit in 64 bits",
                                                sprint(showerror, err))
    end

    @testset "65-bit input boundaries (1-bit output)" begin
        c = _qa2g_topbit(65)
        @test simulate(c, (big(2)^65 - 1,)) == 1
        @test simulate(c, (big(2)^64,)) == 1
        @test simulate(c, (typemax(UInt64),)) == 0
        @test simulate(c, (UInt128(1) << 64,)) == 1
        @test simulate(c, (-big(2)^64,)) == 1          # sign bit of 65-bit two's complement
        @test simulate(c, (typemin(Int64),)) == 1      # sign-extended into bit 64
        @test simulate(c, (Int64(-1),)) == 1
        @test_throws ArgumentError simulate(c, (big(2)^65,))
        @test_throws ArgumentError simulate(c, (UInt128(1) << 65,))
        @test_throws ArgumentError simulate(c, (-big(2)^64 - 1,))
        @test_throws ArgumentError simulate(c, (typemin(Int128),))
    end

    @testset "public API: 64-bit compiled identity" begin
        c = reversible_compile(identity, UInt64; strategy=:expression)
        @test simulate(c, typemax(UInt64)) === typemax(UInt64)
        @test simulate(c, UInt64(1) << 63) === UInt64(1) << 63
        @test_throws ArgumentError simulate(c, UInt128(1) << 64)
        @test_throws ArgumentError simulate(c, typemin(Int128))
        @test simulate(c, UInt64, big(2)^64 - 1) === typemax(UInt64)
        @test verify_reversibility(c)
    end

    @testset "output elements wider than 64 bits are rejected loudly" begin
        # Hand-built 128-wire identity (inputs alias outputs, no gates).
        c = ReversibleCircuit(128, ReversibleGate[], collect(1:128), collect(1:128),
                              Int[], [128], [128])
        @test_throws ArgumentError simulate(c, UInt128(1) << 100)
        @test_throws ArgumentError simulate(c, UInt128(1))
        @test_throws ArgumentError simulate(c, UInt128, UInt128(1) << 100)
        err = try simulate(c, UInt128(1) << 100); nothing catch e; e end
        @test err isa ArgumentError && occursin("64", sprint(showerror, err))
        # 65-bit output element: also rejected rather than wrapped.
        @test_throws ArgumentError simulate(_qa2g_identity(65), (1,))
        # Tuple output with one wide element.
        c2 = ReversibleCircuit(130, ReversibleGate[CNOTGate(1, 2)], [1], collect(2:130),
                               Int[], [1], [1, 128])
        @test_throws ArgumentError simulate(c2, 1)
    end

    @testset "wide total wire count is fine: two-UInt64 adder" begin
        c = reversible_compile((x, y) -> x + y, UInt64, UInt64)
        @test c.n_wires > 64
        @test simulate(c, (typemax(UInt64), UInt64(1))) === UInt64(0)
        @test simulate(c, (typemax(UInt64), typemax(UInt64))) === typemax(UInt64) - 1
        @test simulate(c, (UInt64(1) << 63, UInt64(1) << 63)) === UInt64(0)
        for (x, y) in ((UInt64(0), UInt64(0)), (UInt64(123456789), UInt64(987654321)),
                       (UInt64(0xdeadbeefcafebabe), UInt64(0x0123456789abcdef)))
            @test simulate(c, (x, y)) === x + y
        end
        @test_throws ArgumentError simulate(c, (UInt128(1) << 64, UInt64(0)))
        @test verify_reversibility(c)
    end
end
