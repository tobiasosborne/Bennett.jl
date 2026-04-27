@testset "Bennett-y986 / U05-followup-2 — loop-header dispatch fix" begin

    # Pre-y986: src/lower.jl:944-950 hard-coded a 4-type cascade
    # (IRBinOp / IRICmp / IRSelect / IRCast) for header non-phi
    # instructions, with NO `else`. Any other IR type appearing in the
    # header (IRCall, IRLoad, IRStore, IRAlloca, IRPtrOffset, IRVarGEP,
    # IRExtractValue, IRInsertValue) was silently dropped — the original
    # defect-1 from Bennett-httg / U05, deliberately preserved to protect
    # gate-count baselines for header-only loops (Collatz, soft_fdiv).
    #
    # Post-y986: route through `_lower_inst!` with iteration-LOCAL guards
    # (empty ssa_liveness, fresh inst_counter, forced add=:ripple) — the
    # same ctx pattern body blocks already use, hoisted to the iteration
    # top. The catch-all at lower.jl:190 gives the fail-loud guarantee per
    # CLAUDE.md §1.
    #
    # We test via TWO routes:
    # (A) Hand-built ParsedIR with an IRCall in the loop header — directly
    #     exercises the new dispatch path (test_8p0g pattern). Bypasses LLVM,
    #     so the fixture is deterministic regardless of Julia codegen choices.
    # (B) LLVM-extracted fixtures + pinned baselines — proves the fix doesn't
    #     break the four canonical loop-touching test files.

    using Bennett: ParsedIR, IRBasicBlock, IRBinOp, IRICmp, IRPhi, IRBranch,
                   IRRet, IRCall, IROperand, ssa, iconst, lower, bennett,
                   _soft_udiv_compile

    # -------- (A) Hand-built fixtures: header contains IRCall --------

    @testset "T1: single-block loop with IRCall in header (pre-fix: silently dropped)" begin
        # CFG:
        #   entry:    br L
        #   L:        acc = phi(0 [entry], acc'  [L])
        #             i   = phi(0 [entry], i'    [L])
        #             d   = call _soft_udiv_compile(x, y)   <-- the dropped one
        #             acc'= acc + d
        #             i'  = i + 1
        #             c   = (i' < n)
        #             br c L L_exit
        #   L_exit:   ret acc
        #
        # Pre-fix: IRCall(:d) is silently dropped → vw[:d] missing → resolve!
        # crashes when lowering acc' = acc + d. Post-fix: IRCall dispatches
        # through `_lower_inst!` → lower_call!(soft_udiv) → vw[:d] populated.
        W = 64
        entry = IRBasicBlock(:entry, Bennett.IRInst[],
                             IRBranch(nothing, :L, nothing))
        body = IRBasicBlock(:L,
            Bennett.IRInst[
                IRPhi(:acc, W, [(iconst(0), :entry), (ssa(:acc_next), :L)]),
                IRPhi(:i,   W, [(iconst(0), :entry), (ssa(:i_next),   :L)]),
                IRCall(:d, _soft_udiv_compile,
                       IROperand[ssa(:x), ssa(:y)], [W, W], W),
                IRBinOp(:acc_next, :add, ssa(:acc), ssa(:d), W),
                IRBinOp(:i_next,   :add, ssa(:i),   iconst(1), W),
                IRICmp(:c, :ult, ssa(:i_next), ssa(:n), W),
            ],
            IRBranch(ssa(:c), :L, :L_exit))
        exit = IRBasicBlock(:L_exit, Bennett.IRInst[], IRRet(ssa(:acc), W))

        parsed = ParsedIR(W, [(:x, W), (:y, W), (:n, W)],
                          [entry, body, exit], [W])

        # CFG semantics: do-while with K-bounded unroll and MUX-freeze on
        # false. icmp `c = (i_next < n)` lives AFTER `i_next = i + 1`, so
        # iteration k commits IFF k < n. After K unrolls, effective number
        # of committed iterations = max(0, min(K, n) - 1). acc = effective
        # * (x ÷ y).
        oracle(K, x, y, n) = UInt64(max(0, min(K, Int(n)) - 1)) * (x ÷ y)
        for K in (1, 2, 4)
            lr = lower(parsed; max_loop_iterations=K)
            c  = bennett(lr)
            @test verify_reversibility(c; n_tests=4)
            for (x, y, n) in [(UInt64(10), UInt64(3), UInt64(0)),
                              (UInt64(10), UInt64(3), UInt64(1)),
                              (UInt64(10), UInt64(3), UInt64(K)),
                              (UInt64(20), UInt64(7), UInt64(K))]
                got = simulate(c, UInt64, (x, y, n))
                @test got == oracle(K, x, y, n)
            end
        end
    end

    @testset "T2: K-scaling on hand-built single-block loop" begin
        # Pre-fix: IRCall in header silently dropped → gate count K-independent.
        # Post-fix: IRCall lowers each iteration → gates grow strictly with K.
        W = 64
        entry = IRBasicBlock(:entry, Bennett.IRInst[],
                             IRBranch(nothing, :L, nothing))
        body = IRBasicBlock(:L,
            Bennett.IRInst[
                IRPhi(:acc, W, [(iconst(0), :entry), (ssa(:acc_next), :L)]),
                IRPhi(:i,   W, [(iconst(0), :entry), (ssa(:i_next),   :L)]),
                IRCall(:d, _soft_udiv_compile,
                       IROperand[ssa(:x), ssa(:y)], [W, W], W),
                IRBinOp(:acc_next, :add, ssa(:acc), ssa(:d), W),
                IRBinOp(:i_next,   :add, ssa(:i),   iconst(1), W),
                IRICmp(:c, :ult, ssa(:i_next), ssa(:n), W),
            ],
            IRBranch(ssa(:c), :L, :L_exit))
        exit = IRBasicBlock(:L_exit, Bennett.IRInst[], IRRet(ssa(:acc), W))
        parsed = ParsedIR(W, [(:x, W), (:y, W), (:n, W)],
                          [entry, body, exit], [W])

        c1 = bennett(lower(parsed; max_loop_iterations=1))
        c4 = bennett(lower(parsed; max_loop_iterations=4))
        @test gate_count(c4).total > gate_count(c1).total
        # Each extra iteration adds a full _soft_udiv_compile inlining
        # (~thousands of gates), so K=4 should easily 2× K=1.
        @test gate_count(c4).total > 2 * gate_count(c1).total
    end

    # -------- (B) LLVM-extracted regression fixtures --------

    function _y986_acc(x::Int8, n::Int8)
        a = Int8(0); i = Int8(0)
        while i < n
            a = a + x
            i = i + Int8(1)
        end
        return a
    end

    function collatz_steps(x::Int8)
        steps = Int8(0); val = x
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

    @testset "T3: REGRESSION — Collatz gate count + sim agreement" begin
        # Header-only loop with all-fast-path types (IRBinOp / IRICmp / IRSelect / IRCast).
        # Pre-y986 baseline; post-y986 the dispatch routes through
        # `_lower_inst!` with `add=:ripple` forced. Byte-identical because
        # `_pick_add_strategy(:auto)` returns `:ripple` post-U27 and
        # `ssa_liveness` is empty (so Cuccaro's op2_dead heuristic doesn't
        # fire either way). Pinned values measured on main pre-patch.
        c = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)
        gc = gate_count(c)
        @test gc.total == 14074
        @test gc.Toffoli == 2320
        @test ancilla_count(c) == 8868
        for x in Int8(1):Int8(30)
            @test simulate(c, Int8, x) == collatz_steps(x)
        end
        @test verify_reversibility(c; n_tests=16)
    end

    @testset "T4: REGRESSION — non-loop x+1 baseline pinned (58/12)" begin
        # Sanity: the y986 fix only touches lower_loop!. Non-loop paths
        # remain on the canonical lower_block_insts! route.
        c = reversible_compile(x -> x + Int8(1), Int8)
        gc = gate_count(c)
        @test gc.total == 58
        @test gc.Toffoli == 12
    end

    @testset "T5: Cuccaro-corruption guard (explicit add=:cuccaro)" begin
        # If the implementer drops `:ripple` from the iter ctx, an explicit
        # caller-passed `add=:cuccaro` would let Cuccaro see phi destinations
        # as dead and write in-place, corrupting the accumulator. The iter
        # ctx's `:ripple` override prevents this. Test: simple accumulator
        # with `add=:cuccaro` must still produce correct sums.
        c = reversible_compile(_y986_acc, Tuple{Int8, Int8};
                               max_loop_iterations=5, add=:cuccaro)
        for x in Int8(-2):Int8(2), n in Int8(0):Int8(5)
            @test simulate(c, Int8, (x, n)) == _y986_acc(x, n)
        end
        @test verify_reversibility(c; n_tests=16)
    end
end
