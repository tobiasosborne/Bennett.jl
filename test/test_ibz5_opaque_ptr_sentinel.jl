# Bennett-ibz5 / U96: OPAQUE_PTR_SENTINEL must not silently flow into
# `resolve!` as the integer 0.
#
# `OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)` is the
# fail-loud-by-name placeholder that `_operand_safe` returns when a
# pointer value can't be wrapped (e.g. unresolvable GlobalAlias chain,
# ConstantExpr with sub-operands the extractor can't peel). Today the
# only consumer of `:const` IROperands is `resolve!` in src/lower.jl,
# which masks `op.value` against the requested width and emits NOT
# gates for set bits — value=0 produces ZERO gates and a wire-vector of
# all-zero wires, silently treating an opaque pointer as the literal
# numeric 0.
#
# Per CLAUDE.md §1 (fail loud), `resolve!` must reject the sentinel by
# name, even though the call path that produces it (`_operand_safe`) is
# currently dead code. The check is a tripwire: future use of
# `_operand_safe` will surface immediately rather than producing a
# circuit that compiles and silently miscomputes.
#
# (The companion half of the bead — `_fold_constexpr_operand` losing
# pointer provenance on ptr icmp — is already handled at
# src/ir_extract.jl:2265, which errors loud when `_ptr_addresses_equal`
# returns `nothing`.)

using Test
using Bennett
using Bennett: WireAllocator, ReversibleGate, IROperand,
               OPAQUE_PTR_SENTINEL, resolve!, allocate!

@testset "Bennett-ibz5 / U96: opaque-ptr sentinel fails loud in resolve!" begin

    @testset "T1: resolve! on the sentinel raises" begin
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        @test_throws ErrorException resolve!(gates, wa, vw, OPAQUE_PTR_SENTINEL, 8)
    end

    @testset "T2: resolve! on a hand-built sentinel-named operand also raises" begin
        # Anything named `:__opaque_ptr__` should trip the tripwire,
        # even if its value isn't 0.
        op = IROperand(:const, :__opaque_ptr__, 42)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        @test_throws ErrorException resolve!(gates, wa, vw, op, 8)
    end

    @testset "T3: regression — ordinary :const operands still resolve" begin
        # Numeric 0 with an empty Symbol("") name (the canonical
        # extractor-produced :const) MUST still resolve normally.
        op = IROperand(:const, Symbol(""), 0)
        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        wires = resolve!(gates, wa, vw, op, 8)
        @test length(wires) == 8
        @test isempty(gates)  # value 0 → no NOT gates
    end

    @testset "T4: regression — non-zero :const still resolves" begin
        op = IROperand(:const, Symbol(""), 5)  # binary 101
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
