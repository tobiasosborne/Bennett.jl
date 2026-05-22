# Bennett-s0tn (P1, bug): fail-loud loop-overflow detection.
#
# `lower_loop!` unrolls a data-dependent loop to exactly K =
# max_loop_iterations MUX-guarded body copies, then STOPS. There is no
# check that the loop's exit condition holds after iteration K. An input
# that needs K+1+ iterations gets the after-K state — a silent wrong
# answer. CLAUDE.md §1 (fail loud) violation.
#
# Fix: emit a convergence-detection wire (`conv_w`) in the forward block
# that holds 1 iff the loop exited within K iterations. Bennett's copy-out
# is extended to copy `conv_w` into a fourth-class `loop_check` wire that
# survives the reverse pass exactly as `f(x)` does. `simulate` checks each
# loop-check wire and `error()`s loud on overflow.
#
# Consensus design: docs/design/s0tn_loop_overflow_consensus_design_2026-05-22.md

using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility, gate_count,
               lower, extract_parsed_ir, bennett, LoweringResult, LoopGuard,
               EagerStrategy, ValueEagerStrategy, PebbledStrategy,
               CheckpointStrategy, PebbledGroupStrategy,
               IRCall, ssa, lower_call!, WireAllocator, ReversibleGate,
               register_callee!

# Deterministic iteration count: countdown(x) runs exactly max(x, 0)
# iterations. The convergence bound is exactly predictable, unlike Collatz.
function countdown(x::Int8)
    n = x
    steps = Int8(0)
    while n > Int8(0)
        n -= Int8(1)
        steps += Int8(1)
    end
    return steps
end

# Inner function with a data-dependent loop that survives LLVM
# optimization (genuinely non-closed-form — collatz-style). Used as a
# registered callee to pin the call.jl LoopGuard wire-remap.
function _s0tn_inner_collatz(x::Int8)
    steps = Int8(0)
    val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val >> Int8(1)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end

@testset "Bennett-s0tn: fail-loud loop-overflow detection" begin

    # NOTE: every loop test passes optimize=false. With LLVM's default
    # optimizer, `countdown` is recognised as a closed form (`smax(x,0)`)
    # and the loop is eliminated entirely — no back-edge, no loop guard.
    # CLAUDE.md §5: use optimize=false for predictable loop IR.

    @testset "RED: undersized K throws instead of silent wrong answer" begin
        c = reversible_compile(countdown, Int8; max_loop_iterations=4,
                               optimize=false)

        # K=4 input runs exactly 4 iterations and converges — no throw.
        @test simulate(c, Int8(4)) == 4

        # K+1 and far-over inputs MUST throw, not silently return wrong.
        @test_throws ErrorException simulate(c, Int8(5))
        @test_throws ErrorException simulate(c, Int8(10))

        # The error message must name the bound and the failure mode.
        err = try
            simulate(c, Int8(5))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("max_loop_iterations=4", sprint(showerror, err))
        @test occursin("did not converge", sprint(showerror, err))
    end

    @testset "GREEN: sufficient K computes correct answer for all in-range x" begin
        c = reversible_compile(countdown, Int8; max_loop_iterations=20,
                               optimize=false)
        for x in Int8(0):Int8(20)
            @test simulate(c, x) == countdown(x)
        end
        # A negative Int8 needs zero iterations (n>0 false at entry) — also
        # converges. NOTE: verify_reversibility does random 8-bit sweeps and
        # would hit inputs > 20 that genuinely overflow K=20; that throw is
        # correct loud behaviour, not a bug — so we verify convergence on
        # the in-range subset explicitly instead of a bare random sweep.
        for x in Int8(-30):Int8(-1)
            @test simulate(c, x) == countdown(x)
        end
    end

    @testset "Collatz: undersized K throws, sufficient K correct" begin
        function collatz_steps(x::Int8)
            steps = Int8(0)
            val = x
            while val > Int8(1) && steps < Int8(20)
                if val % Int8(2) == Int8(0)
                    val = val >> Int8(1)
                else
                    val = Int8(3) * val + Int8(1)
                end
                steps += Int8(1)
            end
            return steps
        end

        # NOTE: collatz keeps default optimize=true — under optimize=false
        # the `&&` short-circuit emits an `__unreachable__` block that
        # `_collect_loop_body_blocks` rejects (pre-existing, unrelated to
        # s0tn). The loop genuinely survives optimization (not closed-form),
        # matching test/test_loop_explicit.jl's collatz_steps test.

        # Int8(27) needs many steps; K=3 cannot converge.
        c_small = reversible_compile(collatz_steps, Int8; max_loop_iterations=3)
        @test_throws ErrorException simulate(c_small, Int8(27))

        # K=20 is enough for all x in 1:30 (the loop self-caps at steps<20).
        c_big = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)
        for x in Int8(1):Int8(30)
            @test simulate(c_big, x) == collatz_steps(x)
        end
        # Collatz self-caps at steps<20, so every Int8 converges within
        # K=20 — a full random verify_reversibility sweep is safe here.
        @test verify_reversibility(c_big; n_tests=16)
    end

    @testset "Contract: loop_guards survive lowering + constant folding" begin
        parsed = extract_parsed_ir(countdown, Tuple{Int8}; optimize=false)
        lr_nofold = lower(parsed; max_loop_iterations=8, fold_constants=false)
        @test !isempty(lr_nofold.loop_guards)
        @test lr_nofold.loop_guards[1] isa LoopGuard

        lr_fold = lower(parsed; max_loop_iterations=8, fold_constants=true)
        @test !isempty(lr_fold.loop_guards)
        @test lr_fold.loop_guards[1].K == 8
    end

    @testset "Contract: circuit carries loop_check_wires" begin
        c = reversible_compile(countdown, Int8; max_loop_iterations=8,
                               optimize=false)
        @test !isempty(c.loop_check_wires)
        @test c.loop_check_wires[1] isa LoopGuard
        # loop-check wires must be disjoint from input/output/ancilla.
        lc = Set(lg.wire for lg in c.loop_check_wires)
        @test isempty(intersect(lc, Set(c.input_wires)))
        @test isempty(intersect(lc, Set(c.output_wires)))
        @test isempty(intersect(lc, Set(c.ancilla_wires)))
    end

    @testset "Contract: four-set partition rejects overlapping loop-check wire" begin
        # A loop-check wire that aliases an input wire must fail loud at
        # ReversibleCircuit construction.
        gates = Bennett.ReversibleGate[Bennett.NOTGate(2)]
        @test_throws Exception Bennett.ReversibleCircuit(
            3, gates, [1], [2], Int[3], [1], [1],
            LoopGuard[LoopGuard(1, :hdr, 4)])  # wire 1 aliases input
    end

    @testset "Alternate strategies: loop LR falls back, overflow still caught" begin
        parsed = extract_parsed_ir(countdown, Tuple{Int8}; optimize=false)
        lr = lower(parsed; max_loop_iterations=4)
        for strat in (EagerStrategy(), ValueEagerStrategy(),
                      CheckpointStrategy(), PebbledStrategy(8),
                      PebbledGroupStrategy(8))
            c = bennett(lr; strategy=strat)
            @test !isempty(c.loop_check_wires)
            @test simulate(c, Int8(4)) == 4
            @test_throws ErrorException simulate(c, Int8(7))
        end
    end

    @testset "Nested call: callee loop guard remapped into caller" begin
        # call.jl inlines a callee via lower(callee; max_loop_iterations=64).
        # If the callee has a data-dependent loop, its LoopGuard references
        # callee-numbered wires; lower_call! MUST remap each guard wire by
        # the callee→caller wire offset and append it to the caller's
        # accumulator. Test lower_call! directly (the IR-level contract),
        # mirroring test/test_atf4_lower_call_nontrivial_args.jl.
        register_callee!(_s0tn_inner_collatz)

        gates = ReversibleGate[]
        wa = WireAllocator()
        vw = Dict{Symbol,Vector{Int}}()
        # Allocate a caller input wire range for :x.
        x_wires = Bennett.allocate!(wa, 8)
        vw[:x] = x_wires

        caller_guards = LoopGuard[]
        inst = IRCall(:res, _s0tn_inner_collatz, [ssa(:x)], [8], 8)
        lower_call!(gates, wa, vw, inst; loop_guards=caller_guards)

        # The callee's data-dependent loop must surface exactly one guard,
        # remapped into the caller's wire space (wire index > x's range).
        @test length(caller_guards) == 1
        @test caller_guards[1] isa LoopGuard
        @test caller_guards[1].K == 64        # call.jl hardcoded bound
        @test caller_guards[1].wire > maximum(x_wires)
    end
end
