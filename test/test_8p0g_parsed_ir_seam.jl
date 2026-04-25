# Bennett-8p0g / U147 — hand-built ParsedIR → lower seam test.
#
# Every other test in this suite reaches lower.jl through the LLVM-IR
# extraction frontend (`extract_parsed_ir(f, arg_types)` walking
# Julia-emitted bitcode). That couples lowering coverage to LLVM's
# IR-shape choices: we can't unit-test a specific lowering path
# without inducing the right LLVM output, which means changes to
# Julia's codegen can shift coverage in surprising ways.
#
# This file exercises the lower → bennett → simulate seam directly
# by hand-constructing minimal ParsedIR fixtures. Catches lowering
# regressions independent of LLVM, and makes the contract between
# ir_extract.jl and lower.jl visible: ANY ParsedIR satisfying the
# documented invariants must round-trip through lower → bennett →
# simulate.

using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRBinOp, IRICmp, IRCast, IRRet,
                IROperand, ssa, iconst, lower, bennett

@testset "Bennett-8p0g / U147 — hand-built ParsedIR seam" begin

    @testset "single IRBinOp: f(x::Int8) = x + 3" begin
        # Construct ParsedIR(ret_width=8, args=[(:x, 8)],
        #                    blocks=[entry: r = x + 3; ret r])
        block = IRBasicBlock(:entry,
                             [IRBinOp(:r, :add, ssa(:x), iconst(3), 8)],
                             IRRet(ssa(:r), 8))
        parsed = ParsedIR(8, [(:x, 8)], [block], [8])

        lr = lower(parsed)
        @test lr isa Bennett.LoweringResult
        @test length(lr.input_widths) == 1
        @test lr.input_widths[1] == 8
        @test length(lr.output_wires) == 8
        @test !isempty(lr.gates)

        circuit = bennett(lr)
        @test circuit isa ReversibleCircuit
        @test verify_reversibility(circuit)

        # Simulate against the reference: every Int8 round-trips to x + 3 mod 256.
        for x in Int8(-3):Int8(4)
            @test simulate(circuit, x) == (x + Int8(3)) % Int8
        end
    end

    @testset "two-arg IRBinOp: f(x, y) = x + y" begin
        block = IRBasicBlock(:entry,
                             [IRBinOp(:r, :add, ssa(:x), ssa(:y), 8)],
                             IRRet(ssa(:r), 8))
        parsed = ParsedIR(8, [(:x, 8), (:y, 8)], [block], [8])

        lr = lower(parsed)
        @test length(lr.input_widths) == 2
        @test all(w -> w == 8, lr.input_widths)

        circuit = bennett(lr)
        @test verify_reversibility(circuit)

        for (x, y) in [(Int8(0), Int8(0)), (Int8(5), Int8(7)),
                       (Int8(-3), Int8(2)), (Int8(127), Int8(1))]
            @test simulate(circuit, (x, y)) == (x + y) % Int8
        end
    end

    @testset "IRBinOp xor + IRRet: f(x, y) = x ⊻ y" begin
        block = IRBasicBlock(:entry,
                             [IRBinOp(:r, :xor, ssa(:x), ssa(:y), 8)],
                             IRRet(ssa(:r), 8))
        parsed = ParsedIR(8, [(:x, 8), (:y, 8)], [block], [8])

        circuit = bennett(lower(parsed))
        @test verify_reversibility(circuit)
        for (x, y) in [(Int8(0), Int8(0)), (Int8(0xa), Int8(0x5)),
                       (Int8(127), Int8(-128))]
            @test simulate(circuit, (x, y)) == xor(x, y)
        end
    end

    @testset "IRCast :zext: f(x::Int8) → Int16" begin
        # zext from i8 to i16 — exercises the lower_cast! :zext branch
        # without going through LLVM's cast handlers.
        block = IRBasicBlock(:entry,
                             [IRCast(:r, :zext, ssa(:x), 8, 16)],
                             IRRet(ssa(:r), 16))
        parsed = ParsedIR(16, [(:x, 8)], [block], [16])

        circuit = bennett(lower(parsed))
        @test verify_reversibility(circuit)
        # zero-extend: positive i8 stays positive in i16.
        @test simulate(circuit, Int8(0))   == Int16(0)
        @test simulate(circuit, Int8(1))   == Int16(1)
        @test simulate(circuit, Int8(127)) == Int16(127)
        # zero-extend of a negative i8 keeps the bits — Int8(-1) == 0xff
        # interpreted as i16 unsigned = 255.
        @test simulate(circuit, Int8(-1))  == Int16(255)
    end

    @testset "IRICmp :eq: f(x, y) = (x == y) :: i1" begin
        # icmp produces a 1-bit result. We compose with an i1 → i8 zext
        # so the return is in a more natural shape for simulate.
        block = IRBasicBlock(:entry,
                             [IRICmp(:cmp, :eq, ssa(:x), ssa(:y), 8),
                              IRCast(:r, :zext, ssa(:cmp), 1, 8)],
                             IRRet(ssa(:r), 8))
        parsed = ParsedIR(8, [(:x, 8), (:y, 8)], [block], [8])

        circuit = bennett(lower(parsed))
        @test verify_reversibility(circuit)
        @test simulate(circuit, (Int8(5), Int8(5)))   == Int8(1)
        @test simulate(circuit, (Int8(5), Int8(6)))   == Int8(0)
        @test simulate(circuit, (Int8(-3), Int8(-3))) == Int8(1)
    end

    @testset "constructor validation surfaces invalid hand-built IR" begin
        # Bennett-k7al / U99 invariants: invalid op symbols / widths
        # caught at IR construction, NOT later in lower.jl.
        @test_throws "op=:bogus" IRBinOp(:r, :bogus, ssa(:x), ssa(:y), 8)
        @test_throws "width=0"   IRBinOp(:r, :add, ssa(:x), ssa(:y), 0)
        @test_throws "op=:fpadd" IRCast(:r, :fpadd, ssa(:x), 8, 16)
        @test_throws "predicate=:lt" IRICmp(:r, :lt, ssa(:x), ssa(:y), 8)
    end
end
