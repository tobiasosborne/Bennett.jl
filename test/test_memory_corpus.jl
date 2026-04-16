using Test
using Bennett
using LLVM

# Bennett-cc0 memory corpus — PRD §7 ladder.
#
# Each level L<n> is ONE test exercising a specific LLVM memory pattern.
# Current RED/GREEN state is asserted directly:
#   - GREEN cases use `@test` + correctness sweep.
#   - RED cases use `@test_throws Exception` documenting the current crash.
#     When the corresponding milestone lands, the @test_throws is replaced
#     with @test + verify_reversibility + input sweep.
#
# Bucket mapping (see Bennett-Memory-PRD.md §4):
#   A — shape gap (dynamic idx, (N,W) ∉ {(8,4),(8,8)})       → M1 fix
#   C — dataflow gap (phi-merged pointer, no ptr_provenance) → M2 fix
#   B — dynamic-size gap (Vector{T}(), push!, Dict)          → M3 fix
#
# Shape scope note (M1): the MUX primitives pack the array into a single
# UInt64 register, so N·W ≤ 64. Shapes with N·W > 64 (e.g. (8,16) = 128 bits,
# (32,8) = 256 bits) need multi-word representation and are deferred to
# M1b (tracked as a PRD addendum).

function _compile_ir(ir_string::String)
    c = nothing
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        parsed = Bennett._module_to_parsed_ir(mod)
        lr = Bennett.lower(parsed)
        c = Bennett.bennett(lr)
        dispose(mod)
    end
    return c
end

@testset "Bennett-cc0 memory corpus" begin

    # ─────────────────────────────────────────────────────────────────────
    # Baseline (already GREEN — regression guard).
    # ─────────────────────────────────────────────────────────────────────

    @testset "L0 — Ref{Int8} scalar mutation (shadow, static idx)" begin
        f(x::UInt8) = let r = Ref(UInt8(0))
            r[] = x
            r[]
        end
        c = reversible_compile(f, UInt8)
        @test verify_reversibility(c)
        for x in UInt8(0):UInt8(255)
            @test simulate(c, x) == reinterpret(Int8, x)
        end
    end

    @testset "L1 — alloca i8×4 with const idx (shadow)" begin
        ir = """
        define i8 @julia_f_1(i8 %x) {
        top:
          %p = alloca i8, i32 4
          %g = getelementptr i8, ptr %p, i32 2
          store i8 %x, ptr %g
          %v = load i8, ptr %g
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == x
        end
    end

    @testset "L2 — alloca i8×4 with dynamic idx (mux_4x8)" begin
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i8 %y, i8 %z, i8 %w, i8 %i) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          %g1 = getelementptr i8, ptr %p, i32 1
          %g2 = getelementptr i8, ptr %p, i32 2
          %g3 = getelementptr i8, ptr %p, i32 3
          store i8 %x, ptr %g0
          store i8 %y, ptr %g1
          store i8 %z, ptr %g2
          store i8 %w, ptr %g3
          %idx = zext i8 %i to i32
          %gv = getelementptr i8, ptr %p, i32 %idx
          %v = load i8, ptr %gv
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        tbl = (Int8(3), Int8(-5), Int8(42), Int8(127))
        for i in 0:3
            @test simulate(c, (tbl..., Int8(i))) == tbl[i+1]
        end
    end

    @testset "L3 — alloca i8×8 with dynamic idx (mux_8x8)" begin
        ir = raw"""
        define i8 @julia_f_1(i8 %x0, i8 %x1, i8 %x2, i8 %x3, i8 %x4, i8 %x5, i8 %x6, i8 %x7, i8 %i) {
        top:
          %p  = alloca i8, i32 8
          %g0 = getelementptr i8, ptr %p, i32 0
          %g1 = getelementptr i8, ptr %p, i32 1
          %g2 = getelementptr i8, ptr %p, i32 2
          %g3 = getelementptr i8, ptr %p, i32 3
          %g4 = getelementptr i8, ptr %p, i32 4
          %g5 = getelementptr i8, ptr %p, i32 5
          %g6 = getelementptr i8, ptr %p, i32 6
          %g7 = getelementptr i8, ptr %p, i32 7
          store i8 %x0, ptr %g0
          store i8 %x1, ptr %g1
          store i8 %x2, ptr %g2
          store i8 %x3, ptr %g3
          store i8 %x4, ptr %g4
          store i8 %x5, ptr %g5
          store i8 %x6, ptr %g6
          store i8 %x7, ptr %g7
          %idx = zext i8 %i to i32
          %gv = getelementptr i8, ptr %p, i32 %idx
          %v = load i8, ptr %gv
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        vals = (Int8(1), Int8(2), Int8(3), Int8(4), Int8(5), Int8(6), Int8(7), Int8(8))
        for i in 0:7
            @test simulate(c, (vals..., Int8(i))) == vals[i+1]
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Bucket A — shape gap (dynamic idx, unsupported (N,W)).
    # Current: crashes at `src/lower.jl:1836` with
    #   "lower_store!: unsupported (elem_width=..., n_elems=...) for dynamic idx"
    # M1 fix: parametric MUX EXCH across (N,W) with N·W ≤ 64.
    # ─────────────────────────────────────────────────────────────────────

    @testset "L4 — alloca i16×4 dynamic idx (GREEN, bucket A, M1)" begin
        # shape (16, 4) = 64 bits; UInt64-packable; mux_exch_4x16.
        ir = raw"""
        define i16 @julia_f_1(i16 %x, i8 %i) {
        top:
          %p   = alloca i16, i32 4
          %idx = zext i8 %i to i32
          %g   = getelementptr i16, ptr %p, i32 %idx
          store i16 %x, ptr %g
          %v   = load i16, ptr %g
          ret i16 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int16(-1000):Int16(321):Int16(1000), i in Int8(0):Int8(3)
            @test simulate(c, (x, i)) == x
        end
    end

    @testset "L5 — alloca i8×2 dynamic idx (GREEN, bucket A, M1)" begin
        # shape (8, 2) = 16 bits; UInt64-packable; mux_exch_2x8.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i8 %i) {
        top:
          %p   = alloca i8, i32 2
          %idx = zext i8 %i to i32
          %g   = getelementptr i8, ptr %p, i32 %idx
          store i8 %x, ptr %g
          %v   = load i8, ptr %g
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int8(-8):Int8(1):Int8(8), i in Int8(0):Int8(1)
            @test simulate(c, (x, i)) == x
        end
    end

    @testset "L6 — alloca i32×2 dynamic idx (GREEN, bucket A, M1)" begin
        # shape (32, 2) = 64 bits; UInt64-packable; mux_exch_2x32.
        ir = raw"""
        define i32 @julia_f_1(i32 %x, i8 %i) {
        top:
          %p   = alloca i32, i32 2
          %idx = zext i8 %i to i32
          %g   = getelementptr i32, ptr %p, i32 %idx
          store i32 %x, ptr %g
          %v   = load i32, ptr %g
          ret i32 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int32(-1_000_000):Int32(250_000):Int32(1_000_000), i in Int8(0):Int8(1)
            @test simulate(c, (x, i)) == x
        end
    end

    @testset "L4b — alloca i16×2 dynamic idx (GREEN, bucket A, M1 bonus)" begin
        # shape (16, 2) = 32 bits; mux_exch_2x16. Not in PRD §7 but covered.
        ir = raw"""
        define i16 @julia_f_1(i16 %x, i8 %i) {
        top:
          %p   = alloca i16, i32 2
          %idx = zext i8 %i to i32
          %g   = getelementptr i16, ptr %p, i32 %idx
          store i16 %x, ptr %g
          %v   = load i16, ptr %g
          ret i16 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int16(-1000):Int16(321):Int16(1000), i in Int8(0):Int8(1)
            @test simulate(c, (x, i)) == x
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Bucket C — dataflow gap. Split into three sub-buckets after M2a:
    #
    #   C1 (M2a, GREEN): ptr_provenance state scoped per-function (not per-block).
    #     Previously: lower_block_insts! at src/lower.jl:558 constructed a FRESH
    #     LoweringCtx each block, so allocas in block N were invisible in block
    #     N+1. Fix: thread alloca_info + ptr_provenance through as kwargs from
    #     lower() — matches the existing pattern for ssa_liveness, inst_counter,
    #     gate_groups. L7a and L7b below exercise this fix.
    #
    #   C2 (M2b, RED): pointer-typed phi/select not supported by ir_extract.jl.
    #     Error: "Unsupported LLVM type for width: LLVM.PointerType(ptr)".
    #     Affects SSA-level pointer merging (phi ptr, select ptr). L7c, L7d.
    #
    #   C3 (M2c, BROKEN): conditional-store semantics. A store inside a branch
    #     block currently fires unconditionally — the alloca's primal wires are
    #     mutated regardless of the block predicate. `verify_reversibility`
    #     still passes (the Bennett reverse undoes the unconditional write) but
    #     simulation returns the wrong value on the inactive-branch path.
    #     L7e exercises this (marked @test_broken until fixed).
    # ─────────────────────────────────────────────────────────────────────

    @testset "L7a — alloca+store in top, load in L-branch (GREEN, C1, M2a)" begin
        # Cross-block use of ptr_provenance: alloca + GEP + store happen in
        # `top` (unconditional), load happens in the `L` branch. Before M2a
        # this crashed in the load with "no provenance for ptr %g0" because
        # L's fresh LoweringCtx had an empty ptr_provenance Dict.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          store i8 %x, ptr %g0
          br i1 %c, label %L, label %R
        L:
          %v = load i8, ptr %g0
          ret i8 %v
        R:
          ret i8 0
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int8(-8):Int8(1):Int8(8), b in (true, false)
            @test simulate(c, (x, b)) == (b ? x : Int8(0))
        end
    end

    @testset "L7b — alloca+GEPs in top, load from two branches (GREEN, C1, M2a)" begin
        # Two GEP entries in `top`; each branch loads from a different slot.
        # Exercises both %g0 and %g1 persisting across three blocks.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i8 %y, i1 %c) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          %g1 = getelementptr i8, ptr %p, i32 1
          store i8 %x, ptr %g0
          store i8 %y, ptr %g1
          br i1 %c, label %L, label %R
        L:
          %vL = load i8, ptr %g0
          ret i8 %vL
        R:
          %vR = load i8, ptr %g1
          ret i8 %vR
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int8(-4):Int8(2):Int8(4), y in Int8(-4):Int8(2):Int8(4), b in (true, false)
            @test simulate(c, (x, y, b)) == (b ? x : y)
        end
    end

    @testset "L7e — conditional store semantics (BROKEN, C3, M2c deferred)" begin
        # Store is INSIDE a branch — expected to fire only when c=true. Currently
        # the primal wires get mutated unconditionally (no block-predicate gating
        # in _lower_store_via_shadow! or _lower_store_via_mux_*!). So when c=false,
        # the load still sees the stored value instead of the initial 0.
        # Marked broken until M2c lands path-predicate guarding for store ops.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c) {
        top:
          %p  = alloca i8, i32 4
          %g0 = getelementptr i8, ptr %p, i32 0
          br i1 %c, label %L, label %R
        L:
          store i8 %x, ptr %g0
          br label %J
        R:
          br label %J
        J:
          %v = load i8, ptr %g0
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)  # reversibility holds even with wrong semantics
        # Broken: expected 0 on c=false path, currently returns x.
        @test_broken simulate(c, (Int8(5), false)) == Int8(0)
        # The c=true path is correct today.
        @test simulate(c, (Int8(5), true)) == Int8(5)
    end

    @testset "L7c — pointer-typed phi (RED, C2, M2b target)" begin
        # Different allocas selected by branch + phi — needs ir_extract.jl to
        # accept pointer-typed phi values, THEN lowering/MemSSA to disambiguate.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c) {
        top:
          %a = alloca i8, i32 4
          %b = alloca i8, i32 4
          br i1 %c, label %L, label %R
        L:
          br label %J
        R:
          br label %J
        J:
          %p = phi ptr [ %a, %L ], [ %b, %R ]
          store i8 %x, ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        @test_throws Exception _compile_ir(ir)
    end

    @testset "L7d — pointer-select (RED, C2, M2b target)" begin
        # Same structural issue as L7c but via `select ptr` in a single block.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i1 %c) {
        top:
          %a = alloca i8, i32 4
          %b = alloca i8, i32 4
          %p = select i1 %c, ptr %a, ptr %b
          store i8 %x, ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        @test_throws Exception _compile_ir(ir)
    end

    @testset "L8 — GEP-offset-0 alias (baseline GREEN)" begin
        # NOT actually a bucket-C case: lower_ptr_offset! propagates provenance
        # through const-offset GEPs including offset=0, so this compiles today.
        # Kept as a regression pin for the propagation path.
        ir = raw"""
        define i8 @julia_f_1(i8 %x) {
        top:
          %a = alloca i8, i32 4
          %b = getelementptr i8, ptr %a, i32 0
          store i8 %x, ptr %b
          %v = load i8, ptr %a
          ret i8 %v
        }
        """
        c = _compile_ir(ir)
        @test verify_reversibility(c)
        for x in Int8(-16):Int8(4):Int8(16)
            @test simulate(c, x) == x
        end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Bucket B — dynamic-size gap.
    # Current: crashes at `src/lower.jl:1759` with
    #   "lower_alloca!: dynamic n_elems not supported"
    # M3 fix (partial): T4 shadow-checkpoint + re-exec for bounded cases.
    # Unbounded Vector{T}/Dict → T5, deferred to post-MD5 PRD.
    # ─────────────────────────────────────────────────────────────────────

    @testset "L9 — alloca with runtime n_elems (RED, bucket B, deferred)" begin
        # Dynamic allocation size; hits the hard-reject at src/lower.jl:1759.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i32 %n) {
        top:
          %p = alloca i8, i32 %n
          store i8 %x, ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        @test_throws Exception _compile_ir(ir)
    end

    @testset "L10 — multi-word shape (N·W > 64) (RED, bucket A-wide, M1b target)" begin
        # shape (8, 16) = 128 bits; needs Tuple{UInt64, UInt64} MUX primitive.
        # Deferred to M1b. The M1 single-UInt64 primitives cannot cover this.
        ir = raw"""
        define i8 @julia_f_1(i8 %x, i8 %i) {
        top:
          %p   = alloca i8, i32 16
          %idx = zext i8 %i to i32
          %g   = getelementptr i8, ptr %p, i32 %idx
          store i8 %x, ptr %g
          %v   = load i8, ptr %g
          ret i8 %v
        }
        """
        @test_throws Exception _compile_ir(ir)
    end

    # L11 (MD5 full) is a benchmark target, not a unit test.
    # Tracked in benchmark/bc_md5_full.jl (to be created in M3).
end
