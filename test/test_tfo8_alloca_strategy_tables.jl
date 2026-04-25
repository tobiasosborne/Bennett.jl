# Bennett-tfo8 / U113 — single source of truth for the alloca-MUX
# shape set + dispatch tables.
#
# Before this fix, the (elem_w, n) shape set was hardcoded once in
# `_pick_alloca_strategy` and effectively duplicated as elseif arms in
# the load / store dispatchers (`_lower_load_via_mux!`,
# `_lower_store_single_origin!`).  An entry added in one place but
# missed in another would silently route to `:unsupported`.
#
# These tests pin three invariants:
#   1. `_MUX_EXCH_STRATEGY` has all 6 documented shapes mapped to
#      symbols of the form `:mux_exch_NxW`.
#   2. The load and store dispatch dicts have EXACTLY the same key
#      set as `_MUX_EXCH_STRATEGY`'s value set — no orphans, no gaps.
#   3. `_pick_alloca_strategy` round-trips: every shape in the const
#      maps to its expected `:mux_exch_NxW` symbol; oversize shapes
#      route to `:shadow_checkpoint`; const idx always picks `:shadow`.

using Test
using Bennett

@testset "Bennett-tfo8 / U113 — alloca strategy tables consistent" begin

    @testset "_MUX_EXCH_STRATEGY covers all 6 shapes" begin
        expected_shapes = Set([
            (8,  2), (8,  4), (8,  8),
            (16, 2), (16, 4),
            (32, 2),
        ])
        @test Set(keys(Bennett._MUX_EXCH_STRATEGY)) == expected_shapes

        # Symbols must follow the :mux_exch_NxW convention so the test
        # of the round-trip below is meaningful.
        for ((elem_w, n), sym) in Bennett._MUX_EXCH_STRATEGY
            @test sym === Symbol("mux_exch_$(n)x$(elem_w)")
        end
    end

    @testset "load + store dispatch keysets match strategy values" begin
        strategy_syms = Set(values(Bennett._MUX_EXCH_STRATEGY))
        @test Set(keys(Bennett._MUX_EXCH_LOAD_DISPATCH))  == strategy_syms
        @test Set(keys(Bennett._MUX_EXCH_STORE_DISPATCH)) == strategy_syms

        # Each value is a callable (Function), not e.g. nothing or a stub.
        for fn in values(Bennett._MUX_EXCH_LOAD_DISPATCH)
            @test fn isa Function
        end
        for fn in values(Bennett._MUX_EXCH_STORE_DISPATCH)
            @test fn isa Function
        end
    end

    @testset "_pick_alloca_strategy: shape → symbol round-trip" begin
        # Constant index ALWAYS picks :shadow regardless of shape.
        const_idx = Bennett.iconst(0)
        for (shape, _sym) in Bennett._MUX_EXCH_STRATEGY
            @test Bennett._pick_alloca_strategy(shape, const_idx) === :shadow
        end

        # SSA index of an in-range shape picks the matching :mux_exch_NxW.
        ssa_idx = Bennett.ssa(:idx)
        for (shape, sym) in Bennett._MUX_EXCH_STRATEGY
            @test Bennett._pick_alloca_strategy(shape, ssa_idx) === sym
        end

        # Oversize shape (n·elem_w > 64) → :shadow_checkpoint.
        @test Bennett._pick_alloca_strategy((32, 4), ssa_idx) === :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((64, 2), ssa_idx) === :shadow_checkpoint

        # Inside-budget but unmapped shape → :unsupported.  (8,1) and
        # (16,1) fit in 64 bits and are unmapped, exercising the
        # fallthrough when n·elem_w ≤ 64 but the shape isn't in the
        # MUX table.
        @test Bennett._pick_alloca_strategy((8, 1), ssa_idx)  === :unsupported
        @test Bennett._pick_alloca_strategy((16, 1), ssa_idx) === :unsupported
    end
end
