# Bennett-fidj / U217 — liveness × :auto add dispatcher matrix.
#
# The catalogue (#05 F18) flagged that the `:auto` add dispatcher is
# never tested against the liveness=true / liveness=false (use_inplace)
# split. Per Bennett-spa8 / U27 the post-D1 `:auto` dispatcher returns
# `:ripple` regardless of liveness analysis, so both paths should
# produce the same gate count. Pin that contract here so a future
# change to `_pick_add_strategy(:auto)` that re-introduces a liveness
# branch fails loudly instead of silently shifting gate counts.
#
# Loop-test-widths half of fidj is already covered by Bennett-kv7b
# (test_loop.jl spans Int8/Int16/Int32/Int64).

using Test
using Bennett

@testset "Bennett-fidj / U217 — liveness × :auto add dispatcher" begin

    # x + 1 — single-block straight-line; `:auto` should be ripple-equivalent.
    @testset "x + 1 (Int8): :auto matches :ripple under both liveness modes" begin
        f = x -> x + Int8(1)
        parsed = extract_parsed_ir(f, Tuple{Int8})

        # Compile the four corners of (use_inplace × strategy):
        lr_auto_live = Bennett.lower(parsed; use_inplace = true,  add = :auto)
        lr_auto_dead = Bennett.lower(parsed; use_inplace = false, add = :auto)
        lr_rip_live  = Bennett.lower(parsed; use_inplace = true,  add = :ripple)
        lr_rip_dead  = Bennett.lower(parsed; use_inplace = false, add = :ripple)

        # `:auto` is ripple-equivalent regardless of liveness.
        @test length(lr_auto_live.gates) == length(lr_rip_live.gates)
        @test length(lr_auto_dead.gates) == length(lr_rip_dead.gates)

        # Liveness analysis itself does not alter the ripple lowering at this site
        # (single-use args have no in-place opportunity to take).
        @test length(lr_auto_live.gates) == length(lr_auto_dead.gates)
    end

    # x*x + x — multi-use variable; liveness CAN matter for `:cuccaro`
    # (Cuccaro can in-place a dead operand). For `:auto` (= ripple) the
    # gate count must still match across liveness modes.
    @testset "x*x + x (Int8): :auto identical across liveness modes" begin
        g = x -> x * x + x
        parsed = extract_parsed_ir(g, Tuple{Int8})

        lr_auto_live = Bennett.lower(parsed; use_inplace = true,  add = :auto)
        lr_auto_dead = Bennett.lower(parsed; use_inplace = false, add = :auto)

        @test length(lr_auto_live.gates) == length(lr_auto_dead.gates)
    end

    # End-to-end: reversible_compile (which goes through `lower(; use_inplace=true)`
    # by default) on the :auto and :ripple paths must agree.
    @testset "reversible_compile-level :auto matches :ripple" begin
        c_auto = reversible_compile(x -> x + Int8(1), Int8; add = :auto)
        c_rip  = reversible_compile(x -> x + Int8(1), Int8; add = :ripple)
        @test gate_count(c_auto) == gate_count(c_rip)
        @test verify_reversibility(c_auto)

        for x in Int8(-5):Int8(5)
            @test simulate(c_auto, x) == x + Int8(1)
        end
    end
end
