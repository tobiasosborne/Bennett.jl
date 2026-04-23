using Test
using Bennett

# Helper: build a minimal ReversibleCircuit carrying only a gate list.
# Metrics under test don't inspect inputs/outputs/ancillae, only gates + n_wires.
function _mk(n_wires::Int, gates::Vector{<:Bennett.ReversibleGate})
    return Bennett.ReversibleCircuit(
        n_wires,
        Vector{Bennett.ReversibleGate}(gates),
        Int[],          # input_wires
        Int[],          # output_wires
        Int[],          # ancilla_wires
        Int[],          # input_widths
        Int[],          # output_elem_widths
    )
end

@testset "toffoli_depth: basic shapes" begin
    # No Toffolis at all → depth 0
    c0 = _mk(3, Bennett.ReversibleGate[Bennett.CNOTGate(1,2), Bennett.NOTGate(3)])
    @test Bennett.toffoli_depth(c0) == 0

    # One Toffoli → depth 1
    c1 = _mk(3, Bennett.ReversibleGate[Bennett.ToffoliGate(1,2,3)])
    @test Bennett.toffoli_depth(c1) == 1

    # Three sequential Toffolis sharing target wire → depth 3
    # (each targets wire 3, so the data dependency is strictly sequential)
    c3seq = _mk(3, Bennett.ReversibleGate[
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(1,2,3),
    ])
    @test Bennett.toffoli_depth(c3seq) == 3

    # Three parallel Toffolis on fully disjoint qubits → depth 1
    c3par = _mk(9, Bennett.ReversibleGate[
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(4,5,6),
        Bennett.ToffoliGate(7,8,9),
    ])
    @test Bennett.toffoli_depth(c3par) == 1

    # Mix: 2 parallel Toffolis (disjoint), then 1 Toffoli depending on both
    # First two: {1,2,3} and {4,5,6}. Third reads wires 3 and 6 → must wait.
    cmix = _mk(7, Bennett.ReversibleGate[
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(4,5,6),
        Bennett.ToffoliGate(3,6,7),
    ])
    @test Bennett.toffoli_depth(cmix) == 2

    # CNOTs between Toffolis do NOT advance Toffoli-depth
    cintercut = _mk(4, Bennett.ReversibleGate[
        Bennett.ToffoliGate(1,2,3),
        Bennett.CNOTGate(3,4),   # targets wire 4, not in next Toffoli's wires
        Bennett.ToffoliGate(1,2,3),
    ])
    @test Bennett.toffoli_depth(cintercut) == 2
end

@testset "t_depth: decomposition kwarg" begin
    c = _mk(3, Bennett.ReversibleGate[
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(1,2,3),
        Bennett.ToffoliGate(1,2,3),
    ])
    td = Bennett.toffoli_depth(c)
    @test td == 3

    # Default decomposition is :ammr (Amy-Maslov-Mosca-Roetteler 2013)
    # contributing T-depth 1 per Toffoli. Preserves the pre-M1 semantics.
    @test Bennett.t_depth(c) == td
    @test Bennett.t_depth(c; decomp=:ammr) == td

    # Nielsen-Chuang 7-T classical decomposition: T-depth 3 per Toffoli.
    @test Bennett.t_depth(c; decomp=:nc_7t) == 3 * td

    # Unknown decomposition must fail loudly (principle 1).
    @test_throws Exception Bennett.t_depth(c; decomp=:not_a_real_decomp)
end

@testset "toffoli_depth agrees with legacy t_depth on compiled circuits" begin
    # Any real circuit: toffoli_depth(c) must equal t_depth(c) under :ammr,
    # since :ammr is the decomposition the legacy t_depth implicitly assumed.
    # Bennett-11xt / U23: verify each compiled circuit's Bennett invariants
    # — toffoli-depth alone doesn't prove correctness.
    for (f, T) in [
        (x -> x + Int8(3),      Int8),
        (x -> x * x,             Int8),
        (x -> x > Int8(5) ? x : -x, Int8),
    ]
        c = reversible_compile(f, T)
        @test Bennett.verify_reversibility(c)
        @test Bennett.toffoli_depth(c) == Bennett.t_depth(c; decomp=:ammr)
        @test Bennett.t_depth(c)       == Bennett.t_depth(c; decomp=:ammr)
        @test Bennett.t_depth(c; decomp=:nc_7t) == 3 * Bennett.toffoli_depth(c)
    end
end
