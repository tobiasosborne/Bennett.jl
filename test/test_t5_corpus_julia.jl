using Test
using Bennett

# T5 corpus — Julia (T5-P2a)
#
# RED-Green TDD per CLAUDE.md §3.  Every test here is intentionally RED today
# (2026-04-17).  When T5-P6 (`:persistent_tree` arm in `_pick_alloca_strategy`)
# lands, each `@test_throws` block is replaced by the commented-out GREEN block
# immediately beneath it.
#
# Bucket mapping (Bennett-Memory-T5-PRD.md §3):
#   T5 — universal fallback: unbounded dynamic memory
#   (Vector, Dict, mutable recursive types with runtime dispatch)
#
# Current failure root cause for TJ1/TJ2/TJ3/TJ4 (refreshed 2026-05-18 — Bennett-25dm
# triage post-z2dj+smjd):
#   TJ1, TJ2, TJ4 — "llvm.memset.p0.i64: volatile memset is not supported."
#     All three Julia-source dynamic-memory functions emit a volatile
#     (`i1 true`) `llvm.memset` of the GC frame as the first instruction in
#     %top.  Bennett-9nwt Phase 2 (2026-05-03 — landed AFTER the original
#     2026-04-17 comments below) tightened the memset handler to reject
#     volatile memsets at predicate 3, BEFORE the silent-drop fast path
#     (predicate 8) that used to swallow GC-frame zeroing.  This is now the
#     first error encountered — the old root causes (LLVMGlobalAliasValueKind
#     for TJ1/TJ2; thread_ptr GEP for TJ4) still exist downstream but the
#     pipeline never gets that far.  Tracked as Bennett-9nwt-volatile
#     follow-up; the downstream blockers (TJ1/TJ2 LLVMGlobalAlias, TJ4
#     thread_ptr) remain tracked by Bennett-cc0.5.  The `@test_throws
#     ErrorException` contract still holds — both old and new errors are
#     `ErrorException` — but the precise message has changed.
#   TJ3      — GREEN since Bennett-cc0.4 (2026-04-21).  See the testset
#     header below for the current oracle.

@testset "T5 corpus — Julia (T5-P2a)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # TJ1 — Vector{Int8} push×3 + reduce(+, v)
    #
    # Pattern: dynamic n_elems (unbounded Vector).
    # Current error (refreshed 2026-05-18 — Bennett-25dm triage):
    #   ErrorException: "llvm.memset.p0.i64: volatile memset is not supported"
    # Surface root cause: Julia's GC-frame initialization emits a volatile
    #   (`i1 true`) `llvm.memset` of `%gcframe1`, which Bennett-9nwt Phase 2
    #   now rejects at predicate 3.  Both `mem=:auto` AND
    #   `mem=:persistent, persistent_impl=:linear_scan` hit the same wall —
    #   extraction fails before the persistent dispatcher is ever reached.
    # Downstream root cause (unchanged from 2026-04-17): even if the volatile
    #   memset were silent-dropped, `jl_array_push` / `jl_array_del_beg`
    #   produce `LLVMGlobalAliasValueKind` operands that ir_extract.jl does
    #   not yet handle.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ1: Vector{Int8} push×3 + reduce(+, v)" begin
        f_tj1(x::Int8) = let v = Int8[]
            push!(v, x)
            push!(v, x + Int8(1))
            push!(v, x + Int8(2))
            reduce(+, v)
        end

        # RED: today this throws on the volatile GC-frame memset (see above).
        # Pre-9nwt the message was "Unknown value kind LLVMGlobalAliasValueKind".
        @test_throws ErrorException reversible_compile(f_tj1, Int8)

        # POST-T5-P6 GREEN (uncomment when :persistent_tree arm lands):
        # c = reversible_compile(f_tj1, Int8)
        # for x in typemin(Int8):typemax(Int8)
        #     expected = f_tj1(x)  # x + (x+1) + (x+2) = 3x + 3 (mod 256)
        #     @test simulate(c, Int8(x)) == expected
        # end
        # @test verify_reversibility(c; n_tests=3)
        # println("  TJ1: ", gate_count(c))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TJ2 — Dict{Int8,Int8} insert + lookup roundtrip
    #
    # Pattern: dynamic n_elems + hashing (unbounded Dict).
    # Current error (refreshed 2026-05-18 — Bennett-25dm triage):
    #   ErrorException: "llvm.memset.p0.i64: volatile memset is not supported"
    # Surface root cause: same Julia GC-frame volatile memset as TJ1, rejected
    #   at Bennett-9nwt Phase 2 predicate 3.
    # Downstream root cause (unchanged): jl_dict_setindex_r / jl_dict_getindex
    #   produce LLVMGlobalAlias operands.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ2: Dict{Int8,Int8} insert + lookup" begin
        f_tj2(k::Int8, v::Int8) = let d = Dict{Int8,Int8}()
            d[k] = v
            get(d, k, Int8(0))
        end

        # RED: today this throws on the volatile GC-frame memset (see TJ1 above).
        # Pre-9nwt the message was "Unknown value kind LLVMGlobalAliasValueKind".
        @test_throws ErrorException reversible_compile(f_tj2, Int8, Int8)

        # POST-T5-P6 GREEN (uncomment when :persistent_tree arm lands):
        # c = reversible_compile(f_tj2, Int8, Int8)
        # for k in typemin(Int8):typemax(Int8), v in (Int8(-5), Int8(0), Int8(42))
        #     @test simulate(c, (Int8(k), v)) == v  # lookup always returns inserted v
        # end
        # @test verify_reversibility(c; n_tests=3)
        # println("  TJ2: ", gate_count(c))
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TJ3 — mutable singly-linked list (mutable recursive struct)
    #
    # Pattern: mutable recursive type with Union{T,Nothing} field and
    #   isnothing-typed constant pointer comparisons.
    # Note: mutable struct must be at file/module scope (Julia restriction).
    # Current error (2026-04-17):
    #   ErrorException: Unknown operand ref for: i1 icmp eq
    #     (ptr @"+Main.TJ3Node#….jit", ptr @"+Core.Nothing#….jit")
    # Root cause: constant pointer comparisons (GlobalAlias vs GlobalAlias)
    #   used by Julia to implement isnothing() on Union{T,Nothing} fields are
    #   not handled by ir_extract.jl's operand resolver.
    # ─────────────────────────────────────────────────────────────────────────

    # Struct must live at module scope — defined here at file scope.
    # Wrapped in a module to avoid polluting the global namespace across tests.
    # (If this file is included multiple times, Julia will ignore the duplicate.)

end  # close outer testset to allow top-level struct definition

# Define the linked-list node type at file scope (Julia restriction: mutable
# struct cannot be defined inside a function body or local scope).
mutable struct TJ3Node{T}
    val::T
    next::Union{TJ3Node{T},Nothing}
end

@testset "T5 corpus — Julia (T5-P2a) — TJ3 & TJ4" begin

    @testset "TJ3: mutable singly-linked list (3 nodes, isnothing traversal)" begin
        # Appends nodes and traverses via .next.next — forces Julia to emit
        # isnothing checks on Union{TJ3Node,Nothing} as constant-ptr icmp eq.
        function f_tj3(x::Int8)::Int8
            n3 = TJ3Node{Int8}(x + Int8(2), nothing)
            n2 = TJ3Node{Int8}(x + Int8(1), n3)
            n1 = TJ3Node{Int8}(x, n2)
            # traverse: head -> next -> next -> val
            if !isnothing(n1.next) && !isnothing(n1.next.next)
                n1.next.next.val   # should equal x + 2
            else
                Int8(-1)
            end
        end

        # Bennett-cc0.4 (2026-04-21): GREEN. `isnothing()` on a
        # Union{TJ3Node,Nothing} field compiles (post optimize=true) to
        # `select i1 icmp eq (ptr @TJ3Node, ptr @Nothing), ...` — a
        # ConstantExpr operand now folded by `_fold_constexpr_operand` in
        # `src/ir_extract.jl`. Distinct named globals ⇒ icmp eq is statically
        # false ⇒ the whole function reduces to `x + Int8(2)`.
        c = reversible_compile(f_tj3, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, Int8(x)) == (x + Int8(2)) % Int8
        end
        @test verify_reversibility(c; n_tests=3)
        @info "TJ3 gate count: $(gate_count(c))"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TJ4 — Array{Int8}(undef, 256) with dynamic index
    #
    # Pattern: static-sized but N·W > 64 (256×8 = 2048 bits); today hits the
    #   T4 shadow-checkpoint path (M3a, 2026-04-16) for alloca-based patterns.
    #   However, `Array{Int8}(undef, 256)` at the Julia level emits a
    #   `thread_ptr` GEP via Julia's task-local allocator, which is NOT an
    #   alloca and is therefore not handled by any current tier.
    #
    # Borderline note: alloca i8×256 is GREEN via T4 (see test_memory_corpus.jl
    #   L10).  The JULIA-LEVEL form `Array{Int8}(undef, 256)` is RED because the
    #   Julia runtime allocator emits `thread_ptr` GEPs that are outside the
    #   tracked wire set.
    #
    # Current error (refreshed 2026-05-18 — Bennett-25dm triage):
    #   ErrorException: "llvm.memset.p0.i64: volatile memset is not supported"
    # Surface root cause: same Julia GC-frame volatile memset as TJ1/TJ2,
    #   rejected at Bennett-9nwt Phase 2 predicate 3.
    # Downstream root cause (unchanged from 2026-04-20 / Bennett-cc0.5):
    #   "lower_var_gep!: GEP base thread_ptr not found in variable wires" —
    #   the `thread_ptr` intrinsic (Julia's TLS / task-local allocator) is
    #   not a tracked variable wire.  cc0.5 IN-PROGRESS.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ4: Array{Int8}(undef, 256) dynamic-idx store+load" begin
        f_tj4(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
            a[mod(i, 256) + 1] = x
            a[mod(i, 256) + 1]
        end

        # RED: today this throws on the volatile GC-frame memset (see above).
        # Pre-9nwt the message was "lower_var_gep!: GEP base thread_ptr not
        # found in variable wires" (cc0.5 root cause, still in-progress).
        @test_throws ErrorException reversible_compile(f_tj4, Int8, Int8)
    end

end
