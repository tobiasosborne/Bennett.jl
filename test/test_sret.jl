using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir

# The simulator unconditionally returns signed Int{8,16,32,64} for tuple
# elements (LLVM IR is signless; Bennett's output type is a deliberate pick).
# For unsigned comparisons, reinterpret both sides to the same unsigned type.
_match(result::Tuple, expected::Tuple) =
    all(reinterpret(unsigned(typeof(e)), r % unsigned(typeof(e))) ===
        reinterpret(unsigned(typeof(e)), e)
        for (r, e) in zip(result, expected))

@testset "sret aggregate returns (Bennett-dv1z)" begin

    @testset "n=3 UInt32 identity (smallest sret)" begin
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        circuit = reversible_compile(f, UInt32, UInt32, UInt32)
        @test verify_reversibility(circuit)
        for (a, b, c) in [
                (UInt32(0),           UInt32(0),          UInt32(0)),
                (UInt32(1),           UInt32(2),          UInt32(3)),
                (typemax(UInt32),     typemax(UInt32),    typemax(UInt32)),
                (UInt32(0x12345678),  UInt32(0xCAFEBABE), UInt32(0xDEADBEEF)),
            ]
            @test _match(simulate(circuit, (a, b, c)), (a, b, c))
        end
    end

    @testset "n=4 UInt32 with arithmetic" begin
        f(a::UInt32, b::UInt32, c::UInt32, d::UInt32) = (a + b, c ⊻ d, a & c, b | d)
        circuit = reversible_compile(f, UInt32, UInt32, UInt32, UInt32)
        @test verify_reversibility(circuit)
        for (a, b, c, d) in [
                (UInt32(1), UInt32(2), UInt32(3), UInt32(4)),
                (UInt32(0x11111111), UInt32(0x22222222), UInt32(0x33333333), UInt32(0x44444444)),
                (typemax(UInt32), UInt32(1), UInt32(0xF0F0F0F0), UInt32(0x0F0F0F0F)),
            ]
            expected = f(a, b, c, d)
            @test _match(simulate(circuit, (a, b, c, d)), expected)
        end
    end

    @testset "n=8 UInt32 (SHA-256 output shape)" begin
        f(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
          e::UInt32, f_::UInt32, g::UInt32, h::UInt32) =
            (a, b, c, d, e, f_, g, h)
        circuit = reversible_compile(f, UInt32, UInt32, UInt32, UInt32,
                                        UInt32, UInt32, UInt32, UInt32)
        @test verify_reversibility(circuit)
        inp = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
               UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19))
        @test _match(simulate(circuit, inp), inp)
    end

    @testset "n=3 UInt8 (smaller element width)" begin
        f(a::UInt8, b::UInt8, c::UInt8) = (a + UInt8(1), b ⊻ UInt8(0x55), c & UInt8(0x0f))
        circuit = reversible_compile(f, UInt8, UInt8, UInt8)
        @test verify_reversibility(circuit)
        # exhaustive — 256^3 too many; sample
        for a in UInt8(0):UInt8(15), b in UInt8(0):UInt8(15), c in UInt8(0):UInt8(15)
            @test _match(simulate(circuit, (a, b, c)), f(a, b, c))
        end
    end

    @testset "n=3 UInt64 (largest element width)" begin
        f(a::UInt64, b::UInt64, c::UInt64) = (a ⊻ b, b + c, a & c)
        circuit = reversible_compile(f, UInt64, UInt64, UInt64)
        @test verify_reversibility(circuit)
        for (a, b, c) in [
                (UInt64(0), UInt64(0), UInt64(0)),
                (UInt64(1), UInt64(2), UInt64(3)),
                (typemax(UInt64), UInt64(1), UInt64(0xCAFEBABE_DEADBEEF)),
            ]
            @test _match(simulate(circuit, (a, b, c)), f(a, b, c))
        end
    end

    @testset "n=3 Int32 (signed elements)" begin
        f(a::Int32, b::Int32, c::Int32) = (a - b, b * c, a + c)
        circuit = reversible_compile(f, Int32, Int32, Int32)
        @test verify_reversibility(circuit)
        for (a, b, c) in [
                (Int32(1), Int32(2), Int32(3)),
                (Int32(-1), Int32(-2), Int32(-3)),
                (Int32(100), Int32(-50), Int32(7)),
            ]
            @test simulate(circuit, (a, b, c)) == f(a, b, c)
        end
    end

    @testset "mixed arg widths, homogeneous return" begin
        f(a::UInt8, b::UInt16, c::UInt32) = (UInt32(a), UInt32(b), c)
        circuit = reversible_compile(f, UInt8, UInt16, UInt32)
        @test verify_reversibility(circuit)
        for (a, b, c) in [
                (UInt8(0x42),  UInt16(0x1234),     UInt32(0xDEADBEEF)),
                (UInt8(0xFF),  UInt16(0xFFFF),     UInt32(0xFFFFFFFF)),
                (UInt8(0),     UInt16(0),          UInt32(0)),
            ]
            @test _match(simulate(circuit, (a, b, c)), f(a, b, c))
        end
    end

    @testset "regression: n=2 by-value path still works" begin
        # Existing tests in test_tuple.jl cover this but we re-assert here to
        # lock the invariant: the sret detection must NOT fire on n=2 returns.
        swap2(a::Int8, b::Int8) = (b, a)
        circuit = reversible_compile(swap2, Int8, Int8)
        for a in Int8(0):Int8(7), b in Int8(0):Int8(7)
            @test simulate(circuit, (a, b)) == (b, a)
        end
        @test verify_reversibility(circuit)
        # Gate-count baseline (regression guard per CLAUDE.md rule 6).
        # Measured pre-sret-fix; sret detection must leave this byte-identical.
        @test gate_count(circuit).total == 82
    end

    @testset "error: struct-typed sret (heterogeneous tuple)" begin
        # Tuple{UInt32, UInt64} produces sret({i32, i64}) — not [N x iM]
        f(a::UInt32, b::UInt64) = (a, b)
        @test_throws ErrorException reversible_compile(f, UInt32, UInt64)
    end

    @testset "optimize=false memcpy form auto-canonicalised (Bennett-uyf9)" begin
        # Prior behaviour: errored with "sret with llvm.memcpy form is not
        # supported". Bennett-uyf9 added auto-SROA when sret is detected;
        # optimize=false now extracts successfully.
        f(a::UInt32, b::UInt32, c::UInt32) = (a, b, c)
        pir = extract_parsed_ir(f, Tuple{UInt32, UInt32, UInt32}; optimize=false)
        @test pir.ret_width == 96
        @test pir.ret_elem_widths == [32, 32, 32]
    end
end
