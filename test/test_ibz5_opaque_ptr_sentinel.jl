# Bennett-ibz5 / U96 + Bennett-v958 / U68: OpaquePtrSentinel must not
# silently flow into `resolve!` as the integer 0.
#
# `OPAQUE_PTR_SENTINEL = OpaquePtrSentinel()` is the fail-loud-by-type
# singleton that `_operand_safe` returns when a pointer value can't be
# wrapped (e.g. unresolvable GlobalAlias chain, ConstantExpr with
# sub-operands the extractor can't peel). Pre-v958 it was a tagged-union
# `IROperand(:const, :__opaque_ptr__, 0)` with name-based dispatch; v958
# replaced it with its own subtype so the tripwire is now a method on
# `OpaquePtrSentinel`, not a Symbol-name comparison. Any instance of
# `OpaquePtrSentinel` (canonical singleton or otherwise) trips it.
#
# Per CLAUDE.md §1 (fail loud), `resolve!` rejects the sentinel even
# though the call path that produces it (`_operand_safe`) is currently
# dead code. The check is a tripwire: future use of `_operand_safe` will
# surface immediately rather than producing a circuit that compiles and
# silently miscomputes.

using Test
using Bennett
using Bennett: WireAllocator, ReversibleGate, IROperand, OpaquePtrSentinel,
               ConstOperand, OPAQUE_PTR_SENTINEL, resolve!, allocate!

@testset "Bennett-ibz5 / U96: opaque-ptr sentinel fails loud in resolve!" begin

    @testset "T1: resolve! on the canonical singleton raises" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        @test_throws AssertionError resolve!(gates, wa, vw, OPAQUE_PTR_SENTINEL, 8)
    end

    @testset "T2: resolve! on a hand-built OpaquePtrSentinel also raises" begin
        # Any instance of OpaquePtrSentinel (not just the canonical const)
        # trips the tripwire — dispatch is on the type, not on identity.
        op = OpaquePtrSentinel()
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        @test_throws AssertionError resolve!(gates, wa, vw, op, 8)
    end

    @testset "T3: regression — ordinary ConstOperand still resolves" begin
        # Numeric 0 (the canonical extractor-produced ConstOperand) MUST
        # still resolve normally.
        op = ConstOperand(0)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        wires = resolve!(gates, wa, vw, op, 8)
        @test length(wires) == 8
        @test isempty(gates)  # value 0 → no NOT gates
    end

    @testset "T4: regression — non-zero ConstOperand still resolves" begin
        op = ConstOperand(5)  # binary 101
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        wires = resolve!(gates, wa, vw, op, 8)
        @test length(wires) == 8
        @test length(gates) == 2  # bits 0 and 2 set → 2 NOT gates
    end

    @testset "T5: regression — end-to-end compilation still works" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test simulate(c, Int8, Int8(5)) == Int8(6)
    end
end
