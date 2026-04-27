using Test
using Bennett

# Bennett-heup / U127 — investigation of "_fold_constants mixes three concerns;
# 93-line pass off-by-default". Both load-bearing claims are stale post
# Bennett-epwy / U28 (commit a9dc115, 2026-04-24) which flipped the default
# to true and added benchmarks, and post Bennett-5qrn / U57 trivial-identity
# peepholes (independent reduction layer). This file pins the contracts that
# disprove the bead's premise so any future regression reopens the bead.
#
# Per the chunk-045 calibration: "investigated, doc-only" disposition.
@testset "U127 / Bennett-heup: _fold_constants contract (post-epwy default-true)" begin

    # =========================================================================
    # 1. Default-true contract at every entry point.
    #    The bead headline "off-by-default" must remain false. If a refactor
    #    flips the default, these tests trip.
    # =========================================================================
    @testset "default == fold_constants=true at every entry point" begin
        f(x::Int8) = x * Int8(3)

        # lower() — direct call, no kwargs.
        lr_default = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false))
        lr_on      = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false);
                                   fold_constants=true)
        lr_off     = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}; optimize=false);
                                   fold_constants=false)
        @test length(lr_default.gates) == length(lr_on.gates)
        @test length(lr_default.gates) <  length(lr_off.gates)

        # reversible_compile(::Function, ::Type) inherits the default.
        c = reversible_compile(f, Int8)
        @test verify_reversibility(c)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f(x)
        end
    end

    # =========================================================================
    # 2. Per-gate-type dispatch witnesses.
    #    Hand-built LoweringResults that exercise each arm of `_fold_constants`,
    #    proving the function is a single abstract-interpretation pass over the
    #    `known::Dict{Int,Bool}` state with three operator-dispatch cases —
    #    NOT how the bead framed it (three independent concerns) but how it
    #    actually is (one state, three gate-type cases). Splitting the dispatch
    #    would not cleanly separate concerns; it would just duplicate the
    #    state-update logic three times.
    # =========================================================================
    @testset "per-gate-type dispatch arms" begin
        # NOTGate arm: flip known wire 3 0→1, materialize at end.
        # Net: same gate, just relocated to materialization.
        @testset "NOTGate: flip-then-materialize" begin
            lr = Bennett.LoweringResult(Bennett.ReversibleGate[Bennett.NOTGate(3)],
                                        4, [1, 2], [3], [2], [1], Set{Int}(),
                                        Bennett.GateGroup[], false)
            out = Bennett._fold_constants(lr)
            @test length(out.gates) == 1
            @test out.gates[1] isa Bennett.NOTGate
            @test out.gates[1].target == 3
        end

        # CNOTGate constant-true-control arm: NOT(3); CNOT(3,4) collapses
        # entirely (both known) → 2 NOTs at materialization (CNOT eliminated).
        @testset "CNOTGate: constant-true control collapses to NOT" begin
            lr = Bennett.LoweringResult(Bennett.ReversibleGate[
                                            Bennett.NOTGate(3),
                                            Bennett.CNOTGate(3, 4)],
                                        5, [1, 2], [3, 4], [2], [2], Set{Int}(),
                                        Bennett.GateGroup[], false)
            out = Bennett._fold_constants(lr)
            @test all(g -> g isa Bennett.NOTGate, out.gates)
            @test count(g -> g isa Bennett.CNOTGate, out.gates) == 0
            @test length(out.gates) == 2
        end

        # CNOTGate data-control arm: input wire 1 controls wire 3 (known false).
        # Control is data-dependent → emit CNOT as-is, target leaves `known`.
        @testset "CNOTGate: data control passes through" begin
            lr = Bennett.LoweringResult(Bennett.ReversibleGate[Bennett.CNOTGate(1, 3)],
                                        4, [1, 2], [3], [2], [1], Set{Int}(),
                                        Bennett.GateGroup[], false)
            out = Bennett._fold_constants(lr)
            @test length(out.gates) == 1
            @test out.gates[1] isa Bennett.CNOTGate
            @test out.gates[1].control == 1
            @test out.gates[1].target  == 3
        end

        # ToffoliGate one-control-known-false arm → entire gate is a noop.
        # NOT(3) sets c1=true; c2=4 stays known false; Toffoli is noop.
        @testset "ToffoliGate: one control known-false → noop" begin
            lr = Bennett.LoweringResult(Bennett.ReversibleGate[
                                            Bennett.NOTGate(3),
                                            Bennett.ToffoliGate(3, 4, 5)],
                                        6, [1, 2], [5], [2], [1], Set{Int}(),
                                        Bennett.GateGroup[], false)
            out = Bennett._fold_constants(lr)
            @test count(g -> g isa Bennett.ToffoliGate, out.gates) == 0
            # Only NOT(3) materializes; wire 4 / 5 remain known-false.
            @test length(out.gates) == 1
            @test out.gates[1].target == 3
        end

        # ToffoliGate one-control-true-other-unknown → reduce to CNOT.
        # NOT(3) sets c1=true; c2=1 is input (unknown); Toffoli(3,1,4)
        # reduces to CNOT(1,4). Materialization adds NOT(3) at end.
        @testset "ToffoliGate: one true + one unknown → CNOT reduction" begin
            lr = Bennett.LoweringResult(Bennett.ReversibleGate[
                                            Bennett.NOTGate(3),
                                            Bennett.ToffoliGate(3, 1, 4)],
                                        4, [1, 2], [4], [2], [1], Set{Int}(),
                                        Bennett.GateGroup[], false)
            out = Bennett._fold_constants(lr)
            @test count(g -> g isa Bennett.ToffoliGate, out.gates) == 0
            cnots = filter(g -> g isa Bennett.CNOTGate, out.gates)
            @test length(cnots) == 1
            @test cnots[1].control == 1 && cnots[1].target == 4
        end
    end

    # =========================================================================
    # 3. Self-reversing primitives must short-circuit.
    #    `_fold_constants` reads `lr.self_reversing && return lr` (lower.jl:588);
    #    folding across a Sun-Borissov mul / tabulate primitive would rewrite
    #    its closed gate sequence and break self-uncomputing. CLAUDE.md §6
    #    + Bennett-egu6 / U03 contract.
    # =========================================================================
    @testset "self_reversing short-circuit (Bennett-egu6)" begin
        # 5 NOTs that without short-circuit would collapse to a single materialization.
        lr_sr = Bennett.LoweringResult(Bennett.ReversibleGate[
                                           Bennett.NOTGate(3), Bennett.NOTGate(3),
                                           Bennett.NOTGate(3), Bennett.NOTGate(3),
                                           Bennett.NOTGate(3)],
                                       4, [1, 2], [3], [2], [1], Set{Int}(),
                                       Bennett.GateGroup[], true)  # self_reversing=true
        out = Bennett._fold_constants(lr_sr)
        @test out === lr_sr               # exact pointer-equality short-circuit
        @test out.self_reversing == true
        @test length(out.gates) == 5      # untouched
    end

    # =========================================================================
    # 4. Empirical reduction baselines (post-epwy + post-5qrn live numbers,
    #    measured 2026-04-27). Pin both upper and lower bounds — accidental
    #    "improvement" trips it just like accidental regression.
    #    Pattern borrowed from Bennett-ys0d (chunk 046).
    # =========================================================================
    @testset "empirical reductions (pinned baselines)" begin
        # x*x+3x+1 polynomial: 848 → 482 (43% reduction, Toffoli 352 → 168).
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr_on  = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}; optimize=true);
                               fold_constants=true)
        lr_off = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}; optimize=true);
                               fold_constants=false)
        c_on  = Bennett.bennett(lr_on)
        c_off = Bennett.bennett(lr_off)
        # Pin within ±5% so unrelated improvements don't trip; outside the
        # band is a signal worth investigating per CLAUDE.md §6.
        @test 460 <= gate_count(c_on).total  <= 510
        @test 820 <= gate_count(c_off).total <= 880
        @test 160 <= gate_count(c_on).Toffoli  <= 180
        @test 340 <= gate_count(c_off).Toffoli <= 360
        # Correctness regression guard — exhaustive over Int8.
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_on, x) == g(x)
        end

        # x*3 (optimize=false): off → on ratio ≥ 3× (post-5qrn peephole;
        # pre-5qrn was ~4×). The bead's "no benchmark" claim is rebutted by
        # the pin in test_epwy + this row.
        h(x::Int8) = x * Int8(3)
        lr3_on  = Bennett.lower(Bennett.extract_parsed_ir(h, Tuple{Int8}; optimize=false);
                                fold_constants=true)
        lr3_off = Bennett.lower(Bennett.extract_parsed_ir(h, Tuple{Int8}; optimize=false);
                                fold_constants=false)
        @test length(lr3_off.gates) >= 3 * length(lr3_on.gates)
    end
end
