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
# Current failure root cause for TJ1/TJ2/TJ3/TJ4 (refreshed 2026-05-21 — Bennett-8su4
# de-risking spike):
#   TJ1, TJ2, TJ4 — "inline-asm call is not supported (Bennett-5oyt / U15)".
#     Bennett-8su4 (2026-05-21) relocated the memset volatile-value check so
#     the volatile (`i1 true`) c=0 GC-frame zero-init memset is now silently
#     dropped — that wall is GONE.  The NEW first error for all three
#     functions is the x86-64 TLS read `%thread_ptr = call ptr asm
#     "movq %fs:0, $0"`, caught by the inline-asm guard (Bennett-5oyt/U15).
#     Walls downstream of that (confirmed by the 8su4 spike, in order):
#       (2) `@ijl_gc_small_alloc` — returns a GC-managed heap pointer with no
#           alloca root; Bennett's wire model cannot track it without new
#           machinery.
#       (3) irreversible Julia runtime callees — `j_#_growend!` (array
#           realloc) for TJ1, `j_setindex!` (hash mutation) for TJ2.
#     SROA-dissolution is NOT a factor: Vector/Dict/Array survive as live
#     heap allocations (SROA only dissolves NTuple value-types).  TJ4 is a
#     store-to-load MIRAGE — its `a[i]=x; a[i]` folds to `ret x`, so even a
#     fully-fixed pipeline would compile it to identity (Bennett-890r).
#     Bennett-cc0.5's own description is stale: it cites a `thread_ptr` GEP
#     error, but the actual first wall is the inline-asm read above.  The
#     `@test_throws ErrorException` contract still holds.
#   TJ3      — GREEN since Bennett-cc0.4 (2026-04-21).  See the testset
#     header below for the current oracle.

@testset "T5 corpus — Julia (T5-P2a)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # TJ1 — Vector{Int8} push×3 + reduce(+, v)
    #
    # Pattern: dynamic n_elems (unbounded Vector).
    # Current error (refreshed 2026-05-21 — Bennett-8su4 spike):
    #   ErrorException: "inline-asm call is not supported (Bennett-5oyt / U15)"
    # Surface root cause: Julia's GC/TLS preamble emits `%thread_ptr =
    #   call ptr asm "movq %fs:0, $0"` — an x86-64 TLS read. The volatile
    #   GC-frame memset that used to fail first is now silent-dropped (8su4).
    #   Both `mem=:auto` AND `mem=:persistent, persistent_impl=:linear_scan`
    #   hit this wall — extraction fails before the dispatcher is reached.
    # Downstream root causes (confirmed by the 8su4 spike): past the
    #   inline-asm wall lies `@ijl_gc_small_alloc` (heap pointer, no alloca
    #   root) and then `j_#_growend!` (irreversible array realloc).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ1: Vector{Int8} push×3 + reduce(+, v)" begin
        f_tj1(x::Int8) = let v = Int8[]
            push!(v, x)
            push!(v, x + Int8(1))
            push!(v, x + Int8(2))
            reduce(+, v)
        end

        # RED: today this throws on the inline-asm TLS wall (see above).
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
    # Current error (refreshed 2026-05-21 — Bennett-8su4 spike):
    #   ErrorException: "inline-asm call is not supported (Bennett-5oyt / U15)"
    # Surface root cause: same x86-64 `thread_ptr` TLS-read inline-asm as TJ1
    #   (the volatile GC-frame memset is now silent-dropped — 8su4).
    # Downstream root cause: past the inline-asm wall, `@ijl_gc_small_alloc`
    #   then `j_setindex!` (irreversible hash-table mutation).
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ2: Dict{Int8,Int8} insert + lookup" begin
        f_tj2(k::Int8, v::Int8) = let d = Dict{Int8,Int8}()
            d[k] = v
            get(d, k, Int8(0))
        end

        # RED: today this throws on the inline-asm TLS wall (see TJ1 above).
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
    # Current error (refreshed 2026-05-21 — Bennett-8su4 spike):
    #   ErrorException: "inline-asm call is not supported (Bennett-5oyt / U15)"
    # Surface root cause: same x86-64 `thread_ptr` TLS-read inline-asm as
    #   TJ1/TJ2 (the volatile GC-frame memset is now silent-dropped — 8su4).
    # MIRAGE WARNING (Bennett-890r): even with the whole pipeline fixed,
    #   `a[i]=x; a[i]` is store-to-load-forwarded by LLVM to `ret x` — TJ4
    #   would compile to an identity circuit and NOT actually exercise array
    #   indexing.  A faithful test needs distinct store/load indices.
    # Downstream root cause: past the inline-asm wall, `@ijl_gc_small_alloc`
    #   (heap pointer, no alloca root).  cc0.5's "thread_ptr GEP" description
    #   is stale — the actual first wall is the inline-asm read above.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ4: Array{Int8}(undef, 256) dynamic-idx store+load" begin
        f_tj4(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
            a[mod(i, 256) + 1] = x
            a[mod(i, 256) + 1]
        end

        # RED: today this throws on the inline-asm TLS wall (see above).
        # Pre-9nwt the message was "lower_var_gep!: GEP base thread_ptr not
        # found in variable wires" (cc0.5 root cause, still in-progress).
        @test_throws ErrorException reversible_compile(f_tj4, Int8, Int8)
    end

end
