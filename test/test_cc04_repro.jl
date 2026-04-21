using Test
using Bennett

# Bennett-cc0.4 — constant-pointer icmp eq (ConstantExpr) in ir_extract.
#
# Minimal RED repro: `isnothing(x.next)` on a Union{T,Nothing} field, after
# optimize=true folds the whole mutable-struct allocation chain away, reduces
# to a select whose condition is a ConstantExpr:
#
#   %spec.select = select i1 icmp eq (ptr @TypeA, ptr @TypeB), i8 -1, i8 %rhs
#
# ir_extract's `_operand` currently fails on the ConstantExpr with
#   "Unknown operand ref for: i1 icmp eq (...)".
#
# The two operands are distinct named globals (GlobalAlias / GlobalVariable
# of runtime type descriptors). At link time they have distinct addresses,
# so `icmp eq` is statically `false`, `icmp ne` is statically `true`.
# Bennett-cc0.4 teaches `_operand` to fold this constant to an i1 literal.

mutable struct CC04Node{T}
    val::T
    next::Union{CC04Node{T},Nothing}
end

@testset "Bennett-cc0.4 constant-pointer icmp eq" begin
    # Minimal reproduction: a three-node linked list walked via isnothing
    # checks. After optimize=true, the struct-allocation / field-load chain
    # folds to a select on a constant-ptr ConstantExpr icmp eq.
    function f_cc04(x::Int8)::Int8
        n3 = CC04Node{Int8}(x + Int8(2), nothing)
        n2 = CC04Node{Int8}(x + Int8(1), n3)
        n1 = CC04Node{Int8}(x, n2)
        if !isnothing(n1.next) && !isnothing(n1.next.next)
            n1.next.next.val
        else
            Int8(-1)
        end
    end

    # GREEN (post-cc0.4):
    c = reversible_compile(f_cc04, Int8)
    # The constant-ptr comparison resolves false (TJ3Node ≠ Nothing at link
    # time), so the whole function reduces to x + 2 for every input.
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == (x + Int8(2)) % Int8
    end
    @test verify_reversibility(c; n_tests=3)
end
