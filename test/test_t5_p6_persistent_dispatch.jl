# Bennett-z2dj / Bennett-smjd — T5-P6 `:persistent_tree` dispatcher arm.
#
# History:
#   * Original RED suite for Bennett-z2dj (2026-05-16): 6 testsets covering
#     the kwarg surface + 3-key roundtrip + diamond-CFG refusal.
#   * Testsets 1 + 3 rewritten for Bennett-smjd (2026-05-18): the original
#     Julia-source probes had their NTuple state SROA'd by the Julia frontend
#     before any alloca materialised, so `reversible_compile`'s normal path
#     never reached the persistent dispatcher. The smjd rewrite uses hand-
#     built `.ll` fixtures (parsed via `LLVM.Context` + `parse(LLVM.Module, …)`
#     + `_module_to_parsed_ir`) to drop the dynamic-n alloca shape directly
#     into the lowering pipeline. This is the same fixture pattern used by
#     `test/test_memory_corpus.jl::_compile_ir`.
#
# Testset 3 (Diamond CFG persistent store) is the load-bearing acceptance
# test for Bennett-smjd: it must flip from RED (refused at memory.jl:312-319)
# to GREEN, with gate count within a constant factor of an equivalent
# shadow-memory diamond-CFG baseline (`.ll` fixture 2).
#
# Per CLAUDE.md §4 (exhaustive verification) every persistent test calls
# `verify_reversibility` AND checks against an explicit oracle.
#
# CRITICAL: linear_scan's `max_n = 4` (see `src/persistent/linear_scan.jl`).
# Tests insert at most 3 distinct keys (consensus §4 explicitly corrects
# proposer B's wider sweep down to this cap).

using Test
using Bennett
using LLVM

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

# ----------------------------------------------------------------------------
# Helper: compile a hand-built `.ll` string through the persistent dispatcher.
# Mirrors `test/test_memory_corpus.jl::_compile_ir` but threads the
# `mem=:persistent` kwarg through `Bennett.lower`. Returns the
# `ReversibleCircuit` produced by `bennett()`.
# ----------------------------------------------------------------------------
function _compile_ir_persistent(ir_string::String;
                                mem::Symbol=:persistent,
                                persistent_impl::Symbol=:linear_scan,
                                hashcons::Symbol=:none)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        parsed = Bennett._module_to_parsed_ir(mod)
        lr = Bennett.lower(parsed; mem=mem,
                            persistent_impl=persistent_impl,
                            hashcons=hashcons)
        c = Bennett.bennett(lr)
        dispose(mod)
    end
    return c::Bennett.ReversibleCircuit
end

# ----------------------------------------------------------------------------
# `.ll` fixtures.
# ----------------------------------------------------------------------------

# Fixture 1: single-block dynamic-n alloca with a persistent store + load.
# This is the testset-1 probe. Compiling with `mem=:auto` MUST hard-error
# at `_pick_alloca_strategy_dynamic_n` (memory.jl:181) with a message
# mentioning `mem=:persistent`. Compiling with `mem=:persistent` must
# succeed (it's the entry-block fast path, no smjd extension needed).
const _SMJD_FIXTURE_ENTRY_BLOCK = raw"""
define i8 @julia_smjd_entry_block(i32 %n, i8 %k, i8 %v, i8 %lookup) {
top:
  %slab = alloca i64, i32 %n
  %gep_st = getelementptr i64, ptr %slab, i8 %k
  store i8 %v, ptr %gep_st
  %gep_ld = getelementptr i64, ptr %slab, i8 %lookup
  %r = load i8, ptr %gep_ld
  ret i8 %r
}
"""

# Fixture 2: diamond CFG with a persistent store in the `then` block (a
# non-entry block). The acceptance fixture for Bennett-smjd: pre-smjd this
# is refused at memory.jl:312-319; post-smjd it lowers via
# `_lower_store_via_persistent_guarded!` (MUX between pre- and post-state).
#
# Semantics:
#   if cond > 0: state.set(k, v); else: state unchanged (empty).
#   return state.get(lookup)
#
# Oracle (matches `linear_scan_pmap_get` semantics):
#   if cond > 0 and lookup == k:  return v
#   else:                          return 0
const _SMJD_FIXTURE_DIAMOND_PERSISTENT = raw"""
define i8 @julia_smjd_diamond_persistent(i8 %cond, i32 %n, i8 %k, i8 %v, i8 %lookup) {
top:
  %slab = alloca i64, i32 %n
  %cmp = icmp sgt i8 %cond, 0
  br i1 %cmp, label %then, label %join

then:
  %gep_st = getelementptr i64, ptr %slab, i8 %k
  store i8 %v, ptr %gep_st
  br label %join

join:
  %gep_ld = getelementptr i64, ptr %slab, i8 %lookup
  %r = load i8, ptr %gep_ld
  ret i8 %r
}
"""

# Fixture 3: shadow-memory diamond CFG baseline. Same diamond shape as
# fixture 2, but uses a constant-size `i8 x 256` alloca that routes through
# the existing shadow-checkpoint path (no persistent dispatcher). Used as
# the gate-count reference point — persistent must be within a constant
# factor of shadow on the same control-flow shape.
const _SMJD_FIXTURE_DIAMOND_SHADOW = raw"""
define i8 @julia_smjd_diamond_shadow(i8 %cond, i8 %k, i8 %v, i8 %lookup) {
top:
  %slab = alloca i8, i32 256
  %cmp = icmp sgt i8 %cond, 0
  br i1 %cmp, label %then, label %join

then:
  %gep_st = getelementptr i8, ptr %slab, i8 %k
  store i8 %v, ptr %gep_st
  br label %join

join:
  %gep_ld = getelementptr i8, ptr %slab, i8 %lookup
  %r = load i8, ptr %gep_ld
  ret i8 %r
}
"""

# Diamond-CFG oracle for the persistent fixture.
function _smjd_diamond_persistent_oracle(cond::Int8, n::Int32, k::Int8, v::Int8,
                                          lookup::Int8)::Int8
    s = Bennett.linear_scan_pmap_new()
    if cond > Int8(0)
        s = Bennett.linear_scan_pmap_set(s, k, v)
    end
    return Bennett.linear_scan_pmap_get(s, lookup)
end

# Shadow-CFG oracle: store v at slot k (if cond>0), else leave zero; read slot lookup.
function _smjd_diamond_shadow_oracle(cond::Int8, k::Int8, v::Int8, lookup::Int8)::Int8
    arr = zeros(Int8, 256)
    if cond > Int8(0)
        # k is Int8 (signed) but used as a byte index — interpret as UInt8.
        arr[reinterpret(UInt8, k) + 1] = v
    end
    return arr[reinterpret(UInt8, lookup) + 1]
end

@testset "T5-P6 (Bennett-z2dj / Bennett-smjd) — :persistent_tree dispatcher arm" begin

    # -------------------------------------------------------------------------
    # Testset 1 — dispatcher-level `mem=:auto` must hard-error on dynamic-n.
    # Per consensus §1 ("Default `mem=`") and §4 item 1. The error message
    # MUST mention `mem=:persistent` so the user is told how to opt in.
    #
    # Bennett-smjd: switched from a Julia-source probe (which the frontend
    # SROA'd away) to a hand-built `.ll` fixture that drops the dynamic-n
    # alloca shape directly into the lowering pipeline.
    # -------------------------------------------------------------------------
    @testset "1. mem=:auto hard-errors on dynamic-n alloca (mentions mem=:persistent)" begin
        local err = nothing
        try
            _compile_ir_persistent(_SMJD_FIXTURE_ENTRY_BLOCK; mem=:auto)
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
    # Unchanged: this is the entry-block path that already greens via
    # `reversible_compile` of the top-level Julia function (the function's
    # internal NTuple state THREADS THROUGH `linear_scan_pmap_set` calls
    # rather than living in an alloca, so SROA doesn't bite — the IRCall
    # machinery handles state explicitly).
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
    #
    # Bennett-smjd (2026-05-18): rewritten from a `@test_throws` (the prior
    # refusal contract under z2dj) to a positive correctness test. Option A
    # (output-MUX) emits the IRCall to `impl.pmap_set` unconditionally, then
    # MUXes the post-state against the pre-state using the block predicate.
    # Bennett's reverse pass cleans up the MUX (self-inverse) and the unused
    # post-state wires.
    # -------------------------------------------------------------------------
    @testset "3. Diamond CFG persistent store via block-pred-guarded MUX" begin
        c = _compile_ir_persistent(_SMJD_FIXTURE_DIAMOND_PERSISTENT)
        @test Bennett.verify_reversibility(c)

        # Concrete corner cases — args = (cond, n, k, v, lookup).
        # n is unused at runtime (the persistent slab's wire count is decided
        # at compile time via _state_len_bits(impl) = 576). Pass a small
        # positive value to keep the simulator's input parsing happy.
        let n = Int32(4)
            # (a) cond=+1, lookup==k → return v.
            for (k, v) in [(Int8(0), Int8(0)), (Int8(7), Int8(42)),
                           (Int8(-1), Int8(99)), (Int8(127), Int8(-1))]
                args = (Int8(1), n, k, v, k)
                expected = _smjd_diamond_persistent_oracle(args...)
                @test expected == v          # sanity
                @test Bennett.simulate(c, args) == expected
            end
            # (b) cond=+1, lookup ≠ k → return 0 (no matching key).
            let args = (Int8(1), n, Int8(5), Int8(99), Int8(6))
                expected = _smjd_diamond_persistent_oracle(args...)
                @test expected == Int8(0)    # sanity
                @test Bennett.simulate(c, args) == expected
            end
            # (c) cond=-1, lookup arbitrary → return 0 (empty map).
            for lookup in [Int8(0), Int8(5), Int8(-1), Int8(127)]
                args = (Int8(-1), n, Int8(5), Int8(99), lookup)
                expected = _smjd_diamond_persistent_oracle(args...)
                @test expected == Int8(0)
                @test Bennett.simulate(c, args) == expected
            end
            # (d) cond=0 (≤0) → return 0 even if lookup==k=0.
            let args = (Int8(0), n, Int8(0), Int8(123), Int8(0))
                expected = _smjd_diamond_persistent_oracle(args...)
                @test expected == Int8(0)
                @test Bennett.simulate(c, args) == expected
            end
        end

        # Random sweep — 8 trials.
        let n = Int32(4)
            for _trial in 1:8
                cond   = rand(Int8)
                k      = rand(Int8)
                v      = rand(Int8)
                # Half the time, lookup the stored key (when cond>0 → HIT).
                lookup = rand() < 0.5 ? k : rand(Int8)
                args = (cond, n, k, v, lookup)
                expected = _smjd_diamond_persistent_oracle(args...)
                @test Bennett.simulate(c, args) == expected
            end
        end

        # Gate-count comparison vs the shadow-memory diamond baseline.
        # Both circuits share the same CFG (entry → then → join) and the
        # same I/O shape (store one slot, load one slot). The shadow
        # baseline uses an i8x256 alloca → :shadow_checkpoint strategy.
        c_shadow = nothing
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, _SMJD_FIXTURE_DIAMOND_SHADOW)
            parsed = Bennett._module_to_parsed_ir(mod)
            lr = Bennett.lower(parsed)        # mem=:auto, shadow path
            c_shadow = Bennett.bennett(lr)
            dispose(mod)
        end
        persistent_total = Bennett.gate_count(c).total
        shadow_total     = Bennett.gate_count(c_shadow).total
        # Sanity: both circuits are non-trivial.
        @test persistent_total > 0
        @test shadow_total > 0
        # Looseness: 4x is a starting tolerance per the implementer plan;
        # tighten once we have empirical data.
        @test persistent_total <= 4 * shadow_total
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
    # and §4 item 6: only WIRED (impl, hashcons) values may succeed; every
    # other combination must throw an ArgumentError, NOT silently fall
    # through.
    #
    # Bennett-6883 (2026-05-18): :okasaki is now wired, so the probe was
    # updated to a still-NYI impl (:hamt). When the :hamt / :cf follow-up
    # beads land they will substitute the next still-NYI impl, or — once
    # all four impls are wired — drop the impl probe and keep only the
    # hashcons probe (hashcons :naive / :feistel remain NYI).
    # -------------------------------------------------------------------------
    @testset "6. NYI persistent_impl / hashcons kwargs throw ArgumentError" begin
        @test_throws ArgumentError reversible_compile(
            _z2dj_ls_demo, Int8, Int8, Int8, Int8, Int8, Int8, Int8;
            mem=:persistent, persistent_impl=:hamt)
        @test_throws ArgumentError reversible_compile(
            _z2dj_ls_demo, Int8, Int8, Int8, Int8, Int8, Int8, Int8;
            mem=:persistent, hashcons=:naive)
    end
end
