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
# Current failure root cause for TJ1/TJ2/TJ3/TJ4:
#   TJ1, TJ2 — "Unknown value kind LLVMGlobalAliasValueKind"
#     ir_extract.jl does not handle LLVMGlobalAliasValueKind, which appears in
#     the LLVM IR for Vector/Dict runtime calls (via jl_array_push etc).
#   TJ3      — "Unknown operand ref for: i1 icmp eq (ptr @…RNode…, ptr @…Nothing…)"
#     Constant pointer comparisons in Union{T,Nothing} isnothing checks are not
#     handled by ir_extract.jl.
#   TJ4      — "GEP base thread_ptr not found in variable wires"
#     The `thread_ptr` intrinsic (used by Julia's TLS / task-local allocator for
#     Array{T}(undef, N)) is not a tracked variable wire; the GEP into it crashes.

@testset "T5 corpus — Julia (T5-P2a)" begin

    # ─────────────────────────────────────────────────────────────────────────
    # TJ1 — Vector{Int8} push×3 + reduce(+, v)
    #
    # Pattern: dynamic n_elems (unbounded Vector).
    # Current error (2026-04-17):
    #   ErrorException: Unknown value kind LLVMGlobalAliasValueKind
    # Root cause: jl_array_push / jl_array_del_beg generate global-alias
    #   references in LLVM IR that ir_extract.jl does not yet handle.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ1: Vector{Int8} push×3 + reduce(+, v)" begin
        f_tj1(x::Int8) = let v = Int8[]
            push!(v, x)
            push!(v, x + Int8(1))
            push!(v, x + Int8(2))
            reduce(+, v)
        end

        # RED: today this throws because Vector uses dynamic-n_elems allocation
        # that produces LLVMGlobalAliasValueKind in the extracted IR.
        # Current error: "Unknown value kind LLVMGlobalAliasValueKind"
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
    # Current error (2026-04-17):
    #   ErrorException: Unknown value kind LLVMGlobalAliasValueKind
    # Root cause: same as TJ1 — jl_dict_setindex_r / jl_dict_getindex produce
    #   global-alias refs in LLVM IR.
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ2: Dict{Int8,Int8} insert + lookup" begin
        f_tj2(k::Int8, v::Int8) = let d = Dict{Int8,Int8}()
            d[k] = v
            get(d, k, Int8(0))
        end

        # RED: today this throws for the same reason as TJ1.
        # Current error: "Unknown value kind LLVMGlobalAliasValueKind"
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

        # RED: today this throws because isnothing() on a Union{TJ3Node,Nothing}
        # field compiles to a constant-pointer icmp eq that ir_extract.jl cannot
        # resolve.
        # Current error: "Unknown operand ref for: i1 icmp eq
        #   (ptr @\"+Main.TJ3Node#….jit\", ptr @\"+Core.Nothing#….jit\")"
        @test_throws ErrorException reversible_compile(f_tj3, Int8)

        # POST-T5-P6 GREEN (uncomment when constant-ptr operand handling lands):
        # c = reversible_compile(f_tj3, Int8)
        # for x in typemin(Int8):typemax(Int8)
        #     @test simulate(c, Int8(x)) == x + Int8(2)
        # end
        # @test verify_reversibility(c; n_tests=3)
        # println("  TJ3: ", gate_count(c))
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
    # Current error (2026-04-17):
    #   ErrorException: GEP base thread_ptr not found in variable wires
    # ─────────────────────────────────────────────────────────────────────────
    @testset "TJ4: Array{Int8}(undef, 256) dynamic-idx store+load" begin
        f_tj4(x::Int8, i::Int8) = let a = Array{Int8}(undef, 256)
            a[mod(i, 256) + 1] = x
            a[mod(i, 256) + 1]
        end

        # RED: today this throws because Array{T}(undef, N) uses Julia's TLS
        # allocator, emitting a `thread_ptr` GEP that is not a tracked wire.
        # An alloca-based formulation would be GREEN via T4 (see L10 in
        # test_memory_corpus.jl).
        # Current error: "GEP base thread_ptr not found in variable wires"
        @test_throws ErrorException reversible_compile(f_tj4, Int8, Int8)

        # POST-T5-P6 GREEN (uncomment when T5 `:persistent_tree` arm lands,
        # or when thread_ptr is mapped to the T4 shadow-checkpoint allocator):
        # c = reversible_compile(f_tj4, Int8, Int8)
        # for x in (Int8(-5), Int8(0), Int8(7), Int8(127)),
        #     i in (Int8(0), Int8(1), Int8(100), Int8(-1))
        #     @test simulate(c, (x, i)) == x
        # end
        # @test verify_reversibility(c; n_tests=3)
        # println("  TJ4: ", gate_count(c))
    end

end
