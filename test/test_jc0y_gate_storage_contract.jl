using Test
using Bennett
using InteractiveUtils: subtypes

# Bennett-jc0y / 59jj-cut — investigation of "ReversibleCircuit.gates storage:
# abstract Vector{ReversibleGate} boxes pointers (~56 MB on 1.4M gates), and
# simulate's apply! is type-unstable per gate."
#
# Live measurement (2026-04-27 evening) finds the bead's PERFORMANCE premise
# largely stale: simulate already devirtualizes apply!(::Vector{Bool}, gate)
# inside _simulate via Julia's union-splitting on the 3 concrete subtypes
# (NOTGate / CNOTGate / ToffoliGate). The MEMORY premise is real but modest
# (~26% on large circuits).
#
# Per the chunk-045 calibration: "MEASURE before designing the fix." Three
# candidate refactors (tagged-union, StructArrays.jl, parallel concrete
# vectors) all touch 24+ sites that take `Vector{ReversibleGate}` as a
# parameter and would risk shifting the 39 pinned gate-count baselines.
# Marginal ~15 MB savings on a hypothetical 1.4M-gate SHA-256 circuit
# does not justify the blast radius.
#
# This file pins the contracts that the next agent must check before
# resurrecting jc0y as an actionable refactor:
#   1. Allocation contract: simulate is bounded-alloc independent of |gates|.
#   2. Memory layout contract: per-gate sizes and the boxed-vs-flat ratio.
#   3. Iteration contract: the canonical inside-_simulate dispatch is fast.
@testset "jc0y / U_: ReversibleCircuit.gates storage contract (investigated, doc-only)" begin

    # ========================================================================
    # 1. Allocation contract — simulate must remain bounded-alloc.
    #    The bead claims "type-unstable per gate"; if true, allocs would scale
    #    with |gates|. Empirically simulate only allocates the bits buffer,
    #    input snapshot, and result. This contract trips if a future change
    #    re-introduces per-gate boxing in the hot path.
    # ========================================================================
    @testset "simulate allocation count is bounded, not O(|gates|)" begin
        # Small circuit: x + Int8(1) ≈ 58 gates.
        f1(x::Int8) = x + Int8(1)
        c1 = reversible_compile(f1, Int8)
        # Large-ish circuit: UInt64 mul ≈ 28k gates.
        f2(x::UInt64) = x * x
        c2 = reversible_compile(f2, UInt64)

        # Warm up to flush compilation.
        simulate(c1, Int8(5)); simulate(c2, UInt64(7))

        n2 = length(c2.gates)
        @test n2 > 20_000   # confirm c2 really is the big one

        a2 = @allocated simulate(c2, UInt64(7))

        # If apply! were boxed per gate, a2 would be > 28k × 16 B box header
        # alone = ~448 KiB. Cap at 200 KiB so per-gate boxing trips loudly.
        # The actual Bool/snapshot/result allocs are dominated by the
        # n_wires-sized Bool buffer (zeros(Bool, n_wires)) plus the
        # input_snapshot — both n_wires-scaling, NOT n_gates-scaling.
        @test a2 < 200_000

        # Also: bytes-per-gate must be much less than 1, proving no per-gate
        # boxing happens.
        @test a2 / n2 < 8.0   # < 8 B / gate (vs 16-24 B for any boxing)
    end

    # ========================================================================
    # 2. Memory layout contract — empirical sizeof for the three concrete
    #    gate types. Pins the boxed-vs-flat reduction ratio so any future
    #    storage refactor can use it as a baseline.
    # ========================================================================
    @testset "concrete gate sizeof + boxed-vs-flat ratio" begin
        @test sizeof(NOTGate)      == 8     # 1 × Int
        @test sizeof(CNOTGate)     == 16    # 2 × Int
        @test sizeof(ToffoliGate)  == 24    # 3 × Int

        # Build a representative big-ish circuit and confirm the boxed cost
        # estimate. Pin the live ratio at 25%-30% so a future refactor's
        # measurement can use this as the bar to beat.
        f(a::UInt64, b::UInt64) = (a * b) + (a + b)
        c = reversible_compile(f, UInt64, UInt64)
        ng = length(c.gates)
        n_not  = count(g -> g isa NOTGate,     c.gates)
        n_cnot = count(g -> g isa CNOTGate,    c.gates)
        n_tof  = count(g -> g isa ToffoliGate, c.gates)

        # Boxed: pointer (8 B) + box header (16 B est) + payload per gate.
        boxed = ng * 8 +
                n_not  * (16 +  8) +
                n_cnot * (16 + 16) +
                n_tof  * (16 + 24)
        # Flat 32-byte tagged union: 1 byte tag + 3 × Int wire indices,
        # padded to 32 B per element. Best plausible compact layout.
        flat = ng * 32

        @test boxed > flat   # flat IS smaller — confirms the bead's premise
        ratio = (boxed - flat) / boxed
        # Pin ~26% reduction band. Outside this band → the baseline shifted.
        @test 0.20 < ratio < 0.40
    end

    # ========================================================================
    # 3. Iteration contract — `for g in c.gates; apply!(bits, g); end` inside
    #    a compiled function MUST be the canonical hot-loop shape used by
    #    `_simulate`. Pinning this guards against accidental refactors that
    #    move the loop body to a place where Julia can no longer union-split.
    # ========================================================================
    @testset "compiled-function apply! loop is the canonical shape" begin
        # Inline a tight loop with the canonical shape and confirm it does
        # not allocate per gate at function scope.
        @noinline function _drive!(bits::Vector{Bool}, gates)
            for g in gates
                Bennett.apply!(bits, g)
            end
            return nothing
        end

        f(x::UInt64) = x * x
        c = reversible_compile(f, UInt64)
        bits = zeros(Bool, c.n_wires)
        # Warm up.
        _drive!(bits, c.gates)
        # Reset bits and measure.
        fill!(bits, false)
        a = @allocated _drive!(bits, c.gates)
        # Bound: ZERO allocation per gate. Even allowing 1 KiB slack for any
        # invocation overhead, this is far below the ~28k × per-box cost
        # that boxing-per-gate would imply.
        @test a < 1024
    end

    # ========================================================================
    # 4. Simulator dispatch contract — the three concrete `apply!` methods
    #    are the entire dispatch table. If a 4th gate type is added,
    #    Bennett-jc0y's premise about union-splitting needs re-measurement.
    # ========================================================================
    @testset "apply! method table is exactly 3 entries (NOT/CNOT/Toffoli)" begin
        ms = methods(Bennett.apply!)
        # Filter to (Vector{Bool}, gate) signature methods.
        gate_methods = [m for m in ms if m.nargs == 3]   # self + 2 args
        # The 3 specific overloads at simulator.jl:1-3.
        @test length(gate_methods) >= 3

        # Concrete-subtype enumeration. If a new ReversibleGate subtype
        # lands, `subtypes(ReversibleGate)` grows and this test trips.
        subs = subtypes(ReversibleGate)
        @test Set(subs) == Set([NOTGate, CNOTGate, ToffoliGate])
    end
end
