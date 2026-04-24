using Test
using Bennett

# T1c.2: lower_var_gep! routes compile-time-constant tables through QROM.
# A Julia function that indexes a tuple of constants produces LLVM IR like:
#   @"_j_const#1" = private constant [4 x i8] c"\x63\x7c\x77\x7b"
#   %4 = getelementptr inbounds i8, ptr @"_j_const#1", i64 %3
#   %val = load i8, ptr %4
# We must:
#   (a) extract the global's constant data into ParsedIR.globals
#   (b) emit a QROM circuit in lower_var_gep! when base is a known global
#   (c) end-to-end correct: simulate matches Julia eval for every input.

@testset "T1c.2 QROM dispatch for compile-time-const tables" begin

    @testset "tiny 4-entry lookup, Int8 element" begin
        # First 4 bytes of the AES S-box (0x63, 0x7c, 0x77, 0x7b)
        f(x::UInt8) = let tbl = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))
            tbl[(x & UInt8(0x3)) + 1]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        # Gate count should be ≤ 250 — QROM at L=4, W=8 is ~56 gates plus index masking.
        # Mux-tree path (if QROM failed to dispatch) would produce > 1500 gates.
        @test gate_count(c).total < 300
        # Correctness across all 256 inputs
        for x in UInt8(0):UInt8(255)
            expected = f(x)
            got = simulate(c, x)
            @test got == expected
        end
    end

    @testset "8-entry lookup" begin
        f(x::UInt8) = let tbl = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b),
                                  UInt8(0xf2), UInt8(0x6b), UInt8(0x6f), UInt8(0xc5))
            tbl[(x & UInt8(0x7)) + 1]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        @test gate_count(c).total < 500
        for x in UInt8(0):UInt8(255)
            @test simulate(c, x) == f(x)
        end
    end

    @testset "16-entry lookup still small" begin
        # 16-byte prefix of a real S-box; QROM scaling should be linear, MUX quadratic.
        # Tuple declared INSIDE f so Julia can bake it as a module-level @_j_const
        # without leaving a free-variable lookup. Module-level tuples get passed
        # by-ref and break const-pool extraction.
        f(x::UInt8) = let sbox16 = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b),
                                     UInt8(0xf2), UInt8(0x6b), UInt8(0x6f), UInt8(0xc5),
                                     UInt8(0x30), UInt8(0x01), UInt8(0x67), UInt8(0x2b),
                                     UInt8(0xfe), UInt8(0xd7), UInt8(0xab), UInt8(0x76))
            sbox16[(x & UInt8(0xf)) + 1]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        @test gate_count(c).total < 1200
        for x in UInt8(0):UInt8(255)
            @test simulate(c, x) == f(x)
        end
    end
end
