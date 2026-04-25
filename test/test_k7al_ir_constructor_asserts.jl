# Bennett-k7al / U99 — ir_types.jl constructors used to accept any
# Symbol or Int.  A typo (`:slt` → `:lt`, `:zext` → `:zxt`) or a
# stray `width=0` would silently produce an IR that crashed 500 lines
# later in `lower.jl`'s elseif-chain fallthrough — far from the
# emitter that actually constructed the bad value.
#
# The fix adds inner constructors that:
#   - reject op / predicate / kind symbols not in the canonical set
#   - reject any width <= 0
#   - reject IRCall with mismatched args / arg_widths
#   - reject IRPhi with empty incoming list
#
# These tests exercise the happy path (construction succeeds with
# canonical inputs) and the rejection paths (each assertion has its
# own @test_throws so a future loosening of the check surfaces here).

using Test
using Bennett

@testset "Bennett-k7al / U99 — IR constructor asserts" begin

    @testset "validation tables exist + non-empty" begin
        @test !isempty(Bennett._IR_OPERAND_KINDS)
        @test !isempty(Bennett._IR_BINOP_OPS)
        @test !isempty(Bennett._IR_ICMP_PREDS)
        @test !isempty(Bennett._IR_CAST_OPS)
        # Sanity: each table is a Tuple of Symbols.
        for tbl in (Bennett._IR_OPERAND_KINDS, Bennett._IR_BINOP_OPS,
                    Bennett._IR_ICMP_PREDS, Bennett._IR_CAST_OPS)
            @test tbl isa Tuple
            for s in tbl
                @test s isa Symbol
            end
        end
    end

    @testset "IROperand: kind validation" begin
        # Happy paths — both helpers and the raw constructor.
        @test Bennett.ssa(:x) isa Bennett.IROperand
        @test Bennett.iconst(7) isa Bennett.IROperand
        @test Bennett.IROperand(:ssa, :x, 0) isa Bennett.IROperand

        @test_throws "kind=:bogus" Bennett.IROperand(:bogus, :x, 0)
        @test_throws "kind=:" Bennett.IROperand(:notakind, :x, 0)
    end

    @testset "IRBinOp: op + width validation" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)
        # Each canonical op constructs.
        for op in Bennett._IR_BINOP_OPS
            @test Bennett.IRBinOp(:r, op, a, b, 8) isa Bennett.IRBinOp
        end
        # Bogus op rejected.
        @test_throws "op=:bogus" Bennett.IRBinOp(:r, :bogus, a, b, 8)
        # width <= 0 rejected.
        @test_throws "width=0" Bennett.IRBinOp(:r, :add, a, b, 0)
        @test_throws "width=-1" Bennett.IRBinOp(:r, :add, a, b, -1)
    end

    @testset "IRICmp: predicate + width validation" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)
        for p in Bennett._IR_ICMP_PREDS
            @test Bennett.IRICmp(:r, p, a, b, 8) isa Bennett.IRICmp
        end
        @test_throws "predicate=:lt" Bennett.IRICmp(:r, :lt, a, b, 8)
        @test_throws "width=0"       Bennett.IRICmp(:r, :eq, a, b, 0)
    end

    @testset "IRCast: op + from_width + to_width validation" begin
        a = Bennett.ssa(:a)
        for op in Bennett._IR_CAST_OPS
            @test Bennett.IRCast(:r, op, a, 8, 16) isa Bennett.IRCast
        end
        @test_throws "op=:fpext"    Bennett.IRCast(:r, :fpext, a, 32, 64)
        @test_throws "from_width=0" Bennett.IRCast(:r, :sext, a, 0, 8)
        @test_throws "to_width=0"   Bennett.IRCast(:r, :sext, a, 8, 0)
    end

    @testset "IRSelect / IRRet: width validation" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b); c = Bennett.ssa(:c)
        @test Bennett.IRSelect(:r, c, a, b, 8) isa Bennett.IRSelect
        # IRSelect: width=0 is the Bennett-cc0 M2b pointer-typed sentinel.
        @test Bennett.IRSelect(:p, c, a, b, 0) isa Bennett.IRSelect
        @test_throws "width=-1" Bennett.IRSelect(:r, c, a, b, -1)
        @test Bennett.IRRet(a, 8) isa Bennett.IRRet
        @test_throws "width=0" Bennett.IRRet(a, 0)
    end

    @testset "IRLoad / IRStore / IRAlloca: width >= 1" begin
        p = Bennett.ssa(:ptr); v = Bennett.ssa(:v); n = Bennett.iconst(4)
        @test Bennett.IRLoad(:r, p, 8) isa Bennett.IRLoad
        @test Bennett.IRStore(p, v, 8) isa Bennett.IRStore
        @test Bennett.IRAlloca(:a, 8, n) isa Bennett.IRAlloca
        @test_throws "width=0"      Bennett.IRLoad(:r, p, 0)
        @test_throws "width=0"      Bennett.IRStore(p, v, 0)
        @test_throws "elem_width=0" Bennett.IRAlloca(:a, 0, n)
    end

    @testset "IRPhi: width + non-empty incoming" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)
        good_incoming = [(a, :L1), (b, :L2)]
        @test Bennett.IRPhi(:r, 8, good_incoming) isa Bennett.IRPhi
        # width=0 is the M2b pointer-typed sentinel; allowed.
        @test Bennett.IRPhi(:p, 0, good_incoming) isa Bennett.IRPhi
        @test_throws "width=-1"        Bennett.IRPhi(:r, -1, good_incoming)
        @test_throws "incoming is empty" Bennett.IRPhi(:r, 8,
                                                        Tuple{Bennett.IROperand,Symbol}[])
    end

    @testset "IRCall: arity match + ret_width + arg_widths" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)
        @test Bennett.IRCall(:r, soft_fadd, [a, b], [64, 64], 64) isa Bennett.IRCall
        @test_throws "length(args)" Bennett.IRCall(:r, soft_fadd, [a], [64, 64], 64)
        @test_throws "ret_width=0"  Bennett.IRCall(:r, soft_fadd, [a, b], [64, 64], 0)
        @test_throws "arg_widths[1]=0" Bennett.IRCall(:r, soft_fadd, [a, b], [0, 64], 64)
    end

    @testset "end-to-end: real compile still works" begin
        # If any IR emitter site in ir_extract.jl was passing garbage
        # through the old default constructors, the new asserts would
        # fire here instead of in lower.jl.  The canonical i8 x+1
        # circuit is the smallest end-to-end probe.
        circuit = reversible_compile(x -> x + Int8(1), Int8)
        @test gate_count(circuit).total == 58
        @test verify_reversibility(circuit)
    end
end
