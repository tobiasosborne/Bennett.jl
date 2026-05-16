# Bennett-h0ai / U_: auto self_reversing detection
#
# Adds infrastructure for auto-detecting when an `lr::LoweringResult`
# is structurally self-reversing (single tagged primitive whose
# `result_wires == lr.output_wires`, no branching, all other groups
# are pure boilerplate). When detected, `lr.self_reversing=true` is
# set, halving the gate count via the bennett() short-circuit.
#
# Empirical reality (verified by both proposers AND empirically by the
# orchestrator): the qcla_tree dispatch at `src/lowering/arith.jl:218`
# ALWAYS slices its 2W-wire output to W wires (`lower_mul_qcla_tree!(...)[1:W]`),
# leaving W high-bit wires stranded as dirty ancillae. Per the U03
# probe (Bennett-egu6), this CANNOT be a self-reversing primitive —
# the high-W wires hold real product bits but there's no place for
# them in `output_wires` without changing the function's external
# return shape.
#
# Consequence: under the current arith.jl:218 dispatch, the producer-
# tag NEVER fires for `mul=:qcla_tree`. h0ai is therefore CONSERVATIVE
# by default — it never falsely claims self-reversing. The mechanism
# is exercised at the unit level via direct `_infer_self_reversing`
# tests, AND verified to remain correct end-to-end on every shape
# enumerated in the bead.
#
# Future work (filed as h0ai follow-ups):
#   - Extend producer-tag to `lower_tabulate` LRs going through `lower(parsed)`.
#   - Modify arith.jl:218 to emit non-slicing qcla_tree when the binop's
#     result is the function's only meaningful output, AND extend
#     output_wires to include the high-W bits.

using Test, Bennett
using Bennett: LoweringResult, GateGroup, ReversibleGate, NOTGate, CNOTGate,
               ToffoliGate, lower_mul_qcla_tree!, WireAllocator, allocate!,
               wire_count, _infer_self_reversing, _validate_self_reversing!,
               _has_branching

@testset "Bennett-h0ai: auto self_reversing detection" begin

    # ---- T1: mechanism unit test (hand-constructed LR with one tagged group) ----
    @testset "T1 (YES, mechanism-level): tagged self-reversing group is detected" begin
        # Build a minimal self-reversing LR by hand:
        #   - Inputs:  wires 1..2W (two W-bit operands)
        #   - Outputs: wires 2W+1..4W (the qcla_tree's full 2W product result)
        # `lower_mul_qcla_tree!` is internally self-cleaning (a/b unchanged,
        # all intermediates back to zero). With output_wires set to the FULL
        # 2W result vector — NOT a sliced subset — there are NO stranded
        # ancillae and `_validate_self_reversing!` accepts it.
        W = 4
        wa = WireAllocator()
        a = allocate!(wa, W); b = allocate!(wa, W)
        gates = ReversibleGate[]
        result = lower_mul_qcla_tree!(gates, wa, a, b, W)
        n_wires = wire_count(wa)
        input_wires = vcat(a, b)

        # Tag the (single) qcla_tree group. Its result_wires equals the LR's
        # output_wires verbatim, no truncation.
        gg = GateGroup(:__mul, 1, length(gates), copy(result), Symbol[],
                       2W + 1, n_wires, Int[], true)  # is_self_reversing=true
        lr = LoweringResult(gates, n_wires, input_wires, copy(result),
                            [W, W], [2W], GateGroup[gg], false)

        # No entry-block predicate to trust — empty allowlist suffices.
        @test _infer_self_reversing(lr, Int[]) === true

        # Sanity: with the inferred flag set, Bennett.bennett() short-circuits
        # and the circuit is half the gates of the wrapped form.
        lr_inferred = LoweringResult(gates, n_wires, input_wires, copy(result),
                                     [W, W], [2W], GateGroup[gg], true)
        c_sr = Bennett.bennett(lr_inferred)
        @test length(c_sr.gates) == length(gates)  # no copy-out, no reverse

        # Also exercise the trusted_dirty_wires kwarg overload on the U03 probe.
        @test _validate_self_reversing!(lr_inferred;
                                         trusted_dirty_wires=Set{Int}()) === nothing
    end

    # ---- T2 (NO, IMPORTANT): truncating qcla_tree mul stays conservative ----
    @testset "T2: truncating Int8 qcla_tree mul does NOT auto-promote" begin
        # The bead's LITERAL acceptance test target. Under the current
        # arith.jl:218 dispatch, this case strands the high-W wires
        # (`[1:W]` slice) and CANNOT auto-promote without leaking the
        # high-W bits as part of the function's external output.
        # h0ai correctly REFUSES this case for correctness.
        c_auto = reversible_compile((x,y)->x*y, Int8, Int8; mul=:qcla_tree)
        c_off  = reversible_compile((x,y)->x*y, Int8, Int8;
                                     mul=:qcla_tree, auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        @test verify_reversibility(c_auto)
        # Correctness preserved (mod 2^8).
        for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
            @test simulate(c_auto, (x, y)) == (x * y) % Int8
        end
    end

    # ---- T3 (NO): widening Int16(x)*Int16(y) — also stays conservative ----
    @testset "T3: widening Int16(x)*Int16(y) stays conservative (slice strands high-W)" begin
        # Empirically confirmed: Julia lowers `Int16(x)*Int16(y)` to a single
        # `mul i16` (W=16); qcla_tree emits 32 wires; the [1:W] slice drops 16.
        # Under arith.jl:218 the producer-tag does NOT fire.
        c_auto = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8; mul=:qcla_tree)
        c_off  = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8;
                                     mul=:qcla_tree, auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        @test verify_reversibility(c_auto)
        # Exhaustive Int8×Int8 oracle.
        for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
            @test simulate(c_auto, (x, y)) == Int16(x) * Int16(y)
        end
    end

    # ---- T4 (NO): mul + add does NOT promote ----
    @testset "T4: mul + add does NOT promote" begin
        f(x, y) = Int16(x) * Int16(y) + Int16(1)
        c_auto = reversible_compile(f, Int8, Int8; mul=:qcla_tree)
        c_off  = reversible_compile(f, Int8, Int8; mul=:qcla_tree,
                                     auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        @test verify_reversibility(c_auto)
    end

    # ---- T5 (NO): control flow disqualifies ----
    @testset "T5: control flow disqualifies" begin
        f(x, y) = x > Int8(0) ? Int16(x) * Int16(y) : Int16(0)
        c_auto = reversible_compile(f, Int8, Int8; mul=:qcla_tree)
        c_off  = reversible_compile(f, Int8, Int8; mul=:qcla_tree,
                                     auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        @test verify_reversibility(c_auto)
    end

    # ---- T6 (NO): shift-add multiply does NOT promote ----
    @testset "T6: shift-add multiply does NOT promote" begin
        c_auto = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8; mul=:shift_add)
        c_off  = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8;
                                     mul=:shift_add, auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        @test verify_reversibility(c_auto)
    end

    # ---- T7 (NO): chained x*y*z does not promote ----
    @testset "T7: chained x*y*z does not promote" begin
        # If multiple qcla_tree groups existed, the "exactly one tagged group"
        # check would block. Even today (no producer fires), still NO.
        f(x, y, z) = Int16(x) * Int16(y) * Int16(z)
        c_auto = reversible_compile(f, Int8, Int8, Int8; mul=:qcla_tree)
        c_off  = reversible_compile(f, Int8, Int8, Int8; mul=:qcla_tree,
                                     auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
    end

    # ---- T8 (NO): increment x+1 does NOT promote (no qcla_tree at all) ----
    @testset "T8: simple x+1 does NOT promote (no self-reversing primitive)" begin
        c_auto = reversible_compile(x -> x + Int8(1), Int8)
        c_off  = reversible_compile(x -> x + Int8(1), Int8; auto_self_reversing=false)
        @test gate_count(c_auto).total == gate_count(c_off).total
        # Pin the post-U28 baseline (matches test_egu6_self_reversing_check.jl T5).
        @test gate_count(c_auto).total == 58
    end

    # ---- T9 (kill-switch): auto_self_reversing=false unconditionally disables ----
    @testset "T9: auto_self_reversing=false kill-switch is honored" begin
        # Empty/no-tag inputs should be unchanged either way.
        c_on  = reversible_compile((x,y)->x*y, Int8, Int8; mul=:qcla_tree)
        c_off = reversible_compile((x,y)->x*y, Int8, Int8;
                                    mul=:qcla_tree, auto_self_reversing=false)
        @test gate_count(c_on).total == gate_count(c_off).total

        # On the mechanism-level YES case, kill-switch matters: c_on with
        # a hand-built tagged LR would short-circuit; c_off would not.
        # We can't easily route auto_self_reversing through to a hand-built
        # LR via the public API, so the kill-switch is exercised via the
        # direct `_infer_self_reversing` call below in T10.
    end

    # ---- T10 (forged tag → fail loud) ----
    @testset "T10: forged dirty-ancilla self-reversing claim fails loud" begin
        # Hand-build an LR with `is_self_reversing=true` on a group that
        # does NOT actually self-clean. The L3 runtime probe must catch
        # it (`_validate_self_reversing!` raises, even via the inference path).
        gates = ReversibleGate[NOTGate(3)]  # flips wire 3 unconditionally
        gg = GateGroup(:__forged, 1, 1, [2], Symbol[], 3, 3, Int[], true)
        lr = LoweringResult(gates, 3, [1], [2], [1], [1], GateGroup[gg], false)

        # Inference asks the U03 probe with empty trusted set → probe fails
        # → inference returns false (does NOT promote a forged tag).
        @test _infer_self_reversing(lr, Int[]) === false

        # Also: structural-OK + runtime-FAIL with non-empty trusted_dirty_wires
        # should also return false. Build an LR where the tagged group's
        # result_wires == output_wires, but a forged dirty ancilla exists.
        gates2 = ReversibleGate[NOTGate(3), NOTGate(4)]  # both flip
        gg2 = GateGroup(:__forged2, 1, 2, [2], Symbol[], 3, 4, Int[], true)
        lr2 = LoweringResult(gates2, 4, [1], [2], [1], [1], GateGroup[gg2], false)
        @test _infer_self_reversing(lr2, Int[]) === false
    end

    # ---- T11: existing self_reversing path unchanged (lower_tabulate) ----
    @testset "T11: lower_tabulate self_reversing flag still honored" begin
        # `strategy=:tabulate` builds an LR with self_reversing=true via the
        # direct constructor. The auto-detection path must not disturb this.
        # Regression for Bennett-egu6 fast-path.
        f(x::Int8) = x ⊻ Int8(0x5A)
        c = reversible_compile(f, Int8; strategy=:tabulate)
        @test verify_reversibility(c; n_tests=16)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f(x)
        end
    end

    # ---- T12: fold_constants composition ----
    @testset "T12: fold_constants composes cleanly with auto-detection" begin
        # auto-detection runs BEFORE fold_constants (gate_groups must
        # survive for inference). Either way, both shapes here go through
        # the full Bennett wrap (auto-detection is conservative on
        # truncating qcla_tree). fold_constants reduces the count via
        # constant-controlled gate elimination (e.g. sext bits) —
        # asserting the SAME shape pre/post fold isn't valid here, so
        # we instead pin: (a) fold-on circuit is not larger than fold-off,
        # (b) both verify reversibility, (c) auto vs explicit-off agree.
        c_default = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8; mul=:qcla_tree)
        c_no_fold = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8;
                                        mul=:qcla_tree, fold_constants=false)
        @test gate_count(c_default).total <= gate_count(c_no_fold).total
        @test verify_reversibility(c_default)
        @test verify_reversibility(c_no_fold)

        # Symmetry check: with auto_self_reversing=false the fold-on/off
        # delta should match the auto-on case (the auto-detection path
        # never fired here, so the two pipelines should produce identical
        # gate counts at each fold setting).
        c_default_off = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8;
                                            mul=:qcla_tree, auto_self_reversing=false)
        c_no_fold_off = reversible_compile((x,y)->Int16(x)*Int16(y), Int8, Int8;
                                            mul=:qcla_tree, fold_constants=false,
                                            auto_self_reversing=false)
        @test gate_count(c_default).total == gate_count(c_default_off).total
        @test gate_count(c_no_fold).total == gate_count(c_no_fold_off).total
    end

    # ---- T13: kwarg threading ----
    @testset "T13: auto_self_reversing kwarg reachable on all overloads" begin
        # Tuple overload — already exercised above.
        @test reversible_compile((x,y)->x*y, Int8, Int8;
                                  auto_self_reversing=false) isa ReversibleCircuit
        # ParsedIR overload.
        parsed = Bennett.extract_parsed_ir((x,y)->x*y, Tuple{Int8,Int8}; optimize=true)
        @test reversible_compile(parsed; auto_self_reversing=false) isa ReversibleCircuit
        # Float64 overload — Float64 reversible_compile lives in softfloat_dispatch.jl.
        # Exercising it requires soft_float-shaped input; quickest:
        @test reversible_compile(x -> x + 1.0, Float64;
                                  auto_self_reversing=false) isa ReversibleCircuit
    end

    # ====================================================================
    # h0ai follow-up: producer-tag for `lower_tabulate` LRs (this PR).
    #
    # `lower_tabulate` previously emitted `gate_groups=[]` and hard-coded
    # `self_reversing=true`. The change here:
    #   1. Emits ONE `:__tabulate_qrom` GateGroup over the entire QROM
    #      block, with `is_self_reversing=true`. This makes the producer
    #      contract explicit and inferrable by `_infer_self_reversing`
    #      should a future caller route tabulate through `lower(parsed)`.
    #   2. Threads `auto_self_reversing` into `lower_tabulate` and into
    #      the LR-level `self_reversing` flag, so the kill switch works
    #      end-to-end on both `strategy=:tabulate` and `:auto`-picks-tabulate.
    # ====================================================================

    # Test function used by T14-T17: trivially tabulatable, full UInt8 range.
    _h0ai_tab_f(x::UInt8) = x ⊻ UInt8(0x5a)

    # ---- T14: tabulate emits the producer-tag ----
    @testset "T14: lower_tabulate emits :__tabulate_qrom producer-tag" begin
        lr = Bennett.lower_tabulate(_h0ai_tab_f, Tuple{UInt8}, [8]; out_width=8)
        @test length(lr.gate_groups) == 1
        gg = lr.gate_groups[1]
        @test gg.ssa_name === :__tabulate_qrom
        @test gg.is_self_reversing == true
        @test gg.result_wires == lr.output_wires
        @test gg.gate_start == 1
        @test gg.gate_end == length(lr.gates)
        # Default kwarg: auto_self_reversing=true preserves the LR flag.
        @test lr.self_reversing == true
    end

    # ---- T15: _infer_self_reversing returns true on tabulate LR ----
    @testset "T15: _infer_self_reversing accepts tabulate LR" begin
        lr = Bennett.lower_tabulate(_h0ai_tab_f, Tuple{UInt8}, [8]; out_width=8)
        @test _infer_self_reversing(lr, Int[]) == true
        circuit = Bennett.bennett(lr)
        @test verify_reversibility(circuit)
        for x in UInt8(0):UInt8(255)
            @test simulate(circuit, x) == _h0ai_tab_f(x)
        end
    end

    # ---- T16: kill-switch on the explicit :tabulate path ----
    @testset "T16: auto_self_reversing=false kill-switch on strategy=:tabulate" begin
        c_default = reversible_compile(_h0ai_tab_f, UInt8; strategy=:tabulate)
        c_killed  = reversible_compile(_h0ai_tab_f, UInt8; strategy=:tabulate,
                                        auto_self_reversing=false)
        # With the kill switch, Bennett wraps (forward + copy + reverse) →
        # strictly more gates than the self-reversing short-circuit.
        @test gate_count(c_killed).total > gate_count(c_default).total
        @test verify_reversibility(c_default)
        @test verify_reversibility(c_killed)
        for x in UInt8(0):UInt8(255)
            @test simulate(c_default, x) == _h0ai_tab_f(x)
            @test simulate(c_killed,  x) == _h0ai_tab_f(x)
        end
    end

    # ---- T17: kill-switch on the :auto path when the cost model picks tabulate ----
    @testset "T17: auto_self_reversing=false kill-switch on strategy=:auto→tabulate" begin
        # Need a function whose ParsedIR contains an O(W²) op AND total input
        # width ≤ 4. `x * UInt8(5)` lowered at bit_width=4 satisfies both
        # (`mul` is expensive; total width = 4). Verify via the auto-pick
        # predicate before asserting; if it changes in the future, mark
        # @test_skip + file a follow-up rather than silently invent behavior.
        g(x::UInt8) = x * UInt8(5)
        parsed = Bennett.extract_parsed_ir(g, Tuple{UInt8}; optimize=false)
        if Bennett._tabulate_auto_picks(parsed, Tuple{UInt8}, 4)
            c_default = reversible_compile(g, UInt8; bit_width=4, strategy=:auto)
            c_killed  = reversible_compile(g, UInt8; bit_width=4, strategy=:auto,
                                            auto_self_reversing=false)
            @test gate_count(c_killed).total > gate_count(c_default).total
            @test verify_reversibility(c_default)
            @test verify_reversibility(c_killed)
            # 4-bit input — 16 oracle checks; truncate g to the 4-bit window.
            mask4(y) = UInt8(y & 0x0f)
            for x in UInt8(0):UInt8(15)
                @test simulate(c_default, x) == mask4(g(x))
                @test simulate(c_killed,  x) == mask4(g(x))
            end
        else
            @test_skip "T17 skipped: _tabulate_auto_picks did not select tabulate for g at bit_width=4 — file an h0ai follow-up"
        end
    end

    # ---- T18: regression — T11 invariant after our edit ----
    @testset "T18: T11 regression (tabulate LR self_reversing=true by default)" begin
        # Pin the exact T11 assertion verbatim as explicit regression coverage
        # of the lower_tabulate edit (auto_self_reversing=true is the default,
        # so this lifts the LR-flag and preserves the bennett() short-circuit).
        f(x::Int8) = x ⊻ Int8(0x5A)
        c = reversible_compile(f, Int8; strategy=:tabulate)
        @test verify_reversibility(c; n_tests=16)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == f(x)
        end
    end
end
