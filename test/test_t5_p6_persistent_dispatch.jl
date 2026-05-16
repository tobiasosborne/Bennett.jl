# Bennett-z2dj — T5-P6 `:persistent_tree` dispatcher arm (Step 1 RED test).
#
# This is the RED step of red-green TDD per CLAUDE.md §3 for the persistent
# alloca dispatcher described in `docs/design/p6_consensus.md §4`. The six
# testsets below are expected to FAIL until Steps 2-9 of the consensus
# implementation sequence land. See also:
#
#   * `docs/design/p6_consensus.md`  — chosen design (B-primary, A-supplemental)
#   * `BennettIR-v05-PRD.md`         — broader T5 surface area
#   * Bennett-z2dj                   — bead tracking this workstream
#
# Per CLAUDE.md §1 (fail fast / fail loud) every NYI surface is expected to
# throw with a clear message naming the offending kwarg / impl. We assert via
# `@test_throws` and (where the message contract is load-bearing) substring
# checks on `sprint(showerror, e)`.
#
# Per CLAUDE.md §4 (exhaustive verification) the roundtrip testset checks
# `verify_reversibility` AND semantic agreement against `pmap_demo_oracle`,
# not just "runs without error".
#
# CRITICAL: linear_scan's `max_n = 4` (see `src/persistent/linear_scan.jl`).
# Tests insert at most 3 distinct keys (consensus §4 explicitly corrects
# proposer B's wider sweep down to this cap).

using Test
using Bennett

# ----------------------------------------------------------------------------
# Top-level demo function used by testset 2 (3-key roundtrip).
# Mirrors `_ls_demo` in test/test_persistent_interface.jl but is given a
# z2dj-specific name to avoid collision when both test files load.
# Per CLAUDE.md §5 / the task spec, Bennett.jl extracts LLVM IR best from
# top-level (not closure) definitions.
# ----------------------------------------------------------------------------
function _z2dj_ls_demo(k1::Int8, v1::Int8, k2::Int8, v2::Int8,
                       k3::Int8, v3::Int8, lookup::Int8)::Int8
    s = Bennett.linear_scan_pmap_new()
    s = Bennett.linear_scan_pmap_set(s, k1, v1)
    s = Bennett.linear_scan_pmap_set(s, k2, v2)
    s = Bennett.linear_scan_pmap_set(s, k3, v3)
    return Bennett.linear_scan_pmap_get(s, lookup)
end

# ----------------------------------------------------------------------------
# Diamond-CFG helper for testset 3: a persistent store occurs only in the
# `then` branch (non-entry block). Consensus §3 R1 + §4 require this to be
# refused at `lower_alloca!`-time so Bennett's reverse pass never sees an
# unguarded persistent store.
# ----------------------------------------------------------------------------
function _z2dj_diamond_persistent(cond::Int8, k::Int8, v::Int8, lookup::Int8)::Int8
    s = Bennett.linear_scan_pmap_new()
    if cond > Int8(0)
        # persistent store ONLY in this branch — non-entry block.
        s = Bennett.linear_scan_pmap_set(s, k, v)
    end
    return Bennett.linear_scan_pmap_get(s, lookup)
end

# ----------------------------------------------------------------------------
# Const-n helper for testset 5: a tiny Ref-backed function whose alloca has
# a compile-time-known shape. Same shape as
# `test/test_universal_dispatch.jl:32-41`. Pass `mem=:persistent` and assert
# the persistent arm does NOT hijack it (it must stay in the MUX-EXCH regime).
# ----------------------------------------------------------------------------
function _z2dj_const_n_ref(x::UInt8)
    r = Ref(UInt8(0))
    r[] = x
    return r[]
end

@testset "T5-P6 (Bennett-z2dj) — :persistent_tree dispatcher arm (RED)" begin

    # -------------------------------------------------------------------------
    # Testset 1 — dispatcher-level `mem=:auto` must hard-error on dynamic-n.
    # Per consensus §1 ("Default `mem=`") and §4 item 1. The error message
    # MUST mention `mem=:persistent` so the user is told how to opt in.
    # -------------------------------------------------------------------------
    @testset "1. mem=:auto hard-errors on dynamic-n alloca (mentions mem=:persistent)" begin
        # The demo function has a dynamic-n persistent alloca (NTuple state).
        # `:auto` (the new default once Step 2 lands) refuses to dispatch
        # silently — it must error and direct the user at `mem=:persistent`.
        local err = nothing
        try
            reversible_compile(_z2dj_ls_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8;
                               mem=:auto)
        catch e
            err = e
        end
        @test err !== nothing
        if err !== nothing
            msg = sprint(showerror, err)
            @test occursin("mem=:persistent", msg)
        end
    end

    # -------------------------------------------------------------------------
    # Testset 2 — 3-key roundtrip under `:linear_scan`. Reference oracle is
    # `pmap_demo_oracle` (src/persistent/harness.jl:154). Per consensus §4
    # item 2 the test must include concrete corner cases (zeros, hit, miss)
    # AND a small random sweep, AND call `verify_reversibility`.
    #
    # Signature: per the task spec, the first arg type is the NTuple state.
    # `_z2dj_ls_demo` itself constructs the state internally via
    # `linear_scan_pmap_new`, but the explicit-NTuple-prefix signature
    # exercises the kwarg dispatcher surface that Step 2 introduces.
    # -------------------------------------------------------------------------
    @testset "2. 3-key roundtrip via :linear_scan (compiles, reversible, matches oracle)" begin
        c = reversible_compile(_z2dj_ls_demo,
                               Int8, Int8, Int8, Int8, Int8, Int8, Int8;
                               mem=:persistent, persistent_impl=:linear_scan)

        # Reversibility — Bennett's correctness invariant.
        @test Bennett.verify_reversibility(c)

        # Concrete corner cases.
        # (a) All zeros: insert 3 zero pairs, lookup zero. Oracle returns V(0).
        let args = (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end
        # (b) HIT: lookup matches a stored key (the middle one).
        let args = (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(2))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test expected == Int8(22)  # sanity-check the oracle
            @test Bennett.simulate(c, args) == expected
        end
        # (c) MISS: lookup matches no stored key.
        let args = (Int8(1), Int8(11), Int8(2), Int8(22), Int8(3), Int8(33), Int8(99))
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test expected == Int8(0)  # sanity-check the oracle
            @test Bennett.simulate(c, args) == expected
        end

        # Small random sweep. linear_scan max_n=4 — we insert exactly 3
        # distinct keys per trial (consensus §4 explicit cap).
        for _trial in 1:10
            k1, k2, k3 = rand(Int8), rand(Int8), rand(Int8)
            v1, v2, v3 = rand(Int8), rand(Int8), rand(Int8)
            # Lookup: half-likely a stored key, half-likely a fresh draw.
            lookup = rand([k1, k2, k3, rand(Int8)])
            args = (k1, v1, k2, v2, k3, v3, lookup)
            expected = Bennett.pmap_demo_oracle(Int8, Int8, args...)
            @test Bennett.simulate(c, args) == expected
        end
    end

    # -------------------------------------------------------------------------
    # Testset 3 — diamond CFG: persistent store in non-entry block.
    # Per consensus §3 R1: refused at `lower_alloca!`-time to keep Bennett's
    # reverse pass safe from unguarded persistent stores.
    # -------------------------------------------------------------------------
    @testset "3. Diamond CFG persistent store in non-entry block hard-errors" begin
        @test_throws Exception reversible_compile(
            _z2dj_diamond_persistent, Int8, Int8, Int8, Int8;
            mem=:persistent, persistent_impl=:linear_scan)
    end

    # -------------------------------------------------------------------------
    # Testset 4 — regression on existing `_pick_alloca_strategy` arms.
    # COPIED VERBATIM from `test/test_universal_dispatch.jl:90-115` per
    # consensus §4 item 4. After Steps 3+4 land, these must still pass,
    # proving the new dispatcher arm is strictly additive (no behaviour
    # change for const-idx or const-n cases).
    # -------------------------------------------------------------------------
    @testset "strategy picker returns :shadow for static idx" begin
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.iconst(2)) == :shadow
        @test Bennett._pick_alloca_strategy((8, 16), Bennett.iconst(0)) == :shadow
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.iconst(0)) == :shadow
    end

    @testset "strategy picker returns :mux_exch_* for dynamic idx on supported shapes" begin
        @test Bennett._pick_alloca_strategy((8, 4), Bennett.ssa(:idx)) == :mux_exch_4x8
        @test Bennett._pick_alloca_strategy((8, 8), Bennett.ssa(:idx)) == :mux_exch_8x8
        # M1 additions (Bennett-cc0): N·W ≤ 64 single-UInt64 shapes.
        @test Bennett._pick_alloca_strategy((8, 2),  Bennett.ssa(:idx)) == :mux_exch_2x8
        @test Bennett._pick_alloca_strategy((16, 2), Bennett.ssa(:idx)) == :mux_exch_2x16
        @test Bennett._pick_alloca_strategy((16, 4), Bennett.ssa(:idx)) == :mux_exch_4x16
        @test Bennett._pick_alloca_strategy((32, 2), Bennett.ssa(:idx)) == :mux_exch_2x32
    end

    @testset "strategy picker returns :shadow_checkpoint for dynamic idx on N·W > 64 shapes" begin
        # Bennett-cc0 M3a (Bennett-jqyt): multi-word shapes (N·W > 64) now
        # dispatch to the T4 shadow-checkpoint MVP fallback rather than
        # :unsupported. MUX EXCH is still preferred for N·W ≤ 64 shapes
        # (cheaper per-op cost); T4 is the universal correctness fallback.
        @test Bennett._pick_alloca_strategy((8, 100), Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((16, 8),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((32, 4),  Bennett.ssa(:idx)) == :shadow_checkpoint
        @test Bennett._pick_alloca_strategy((64, 2),  Bennett.ssa(:idx)) == :shadow_checkpoint
    end

    # -------------------------------------------------------------------------
    # Testset 5 — `mem=:persistent` + const-n is a no-op. Per consensus §1
    # ("Semantics of `mem=:persistent`") and §4 item 5: const-n allocas
    # still route through shadow / MUX-EXCH / shadow_checkpoint. The
    # persistent arm must NOT hijack const-n cases.
    # -------------------------------------------------------------------------
    @testset "5. mem=:persistent leaves const-n functions in the MUX-EXCH regime" begin
        c = reversible_compile(_z2dj_const_n_ref, UInt8; mem=:persistent)
        # Gate count must stay in the MUX-EXCH regime (well under 10k).
        @test gate_count(c).total < 10_000
        # And the circuit must still verify.
        @test Bennett.verify_reversibility(c)
        # Semantic spot-check across all 256 UInt8 inputs.
        for x in UInt8(0):UInt8(255)
            @test Bennett.simulate(c, x) == x
        end
    end

    # -------------------------------------------------------------------------
    # Testset 6 — NYI kwargs fail loud. Per consensus §1 ("Impls in MVP")
    # and §4 item 6: only `:linear_scan` + `hashcons=:none` are wired in
    # this step. Every other (impl, hashcons) value must throw an
    # ArgumentError, NOT silently fall through.
    # -------------------------------------------------------------------------
    @testset "6. NYI persistent_impl / hashcons kwargs throw ArgumentError" begin
        @test_throws ArgumentError reversible_compile(
            _z2dj_ls_demo, Int8, Int8, Int8, Int8, Int8, Int8, Int8;
            mem=:persistent, persistent_impl=:okasaki)
        @test_throws ArgumentError reversible_compile(
            _z2dj_ls_demo, Int8, Int8, Int8, Int8, Int8, Int8, Int8;
            mem=:persistent, hashcons=:naive)
    end
end
