# Bennett-zyjn / U94 — `_get_deref_bytes(func, param)` previously
# returned 0 for THREE distinct outcomes:
#   (a) param not in func.parameters     → caller-side bug
#   (b) defline missing `(...)` paren    → LLVM.jl format mismatch
#   (c) param has no `dereferenceable(N)` attribute on its slot
#
# That collapsed two real BUGS into the same silent return value as
# the legitimate "no attr" case (c). The fix `error()`s on (a) and (b)
# with attribution to the bead; only (c) still returns 0.
#
# Tests pin:
#   1. End-to-end compile through the dereferenceable-pointer path
#      still works (a function taking a Tuple-by-reference parameter
#      gets a positive deref byte count and a sane gate count).
#   2. Calling _get_deref_bytes with a parameter from a DIFFERENT
#      function errors with attribution to Bennett-zyjn.
#   3. The legitimate "no deref attr" return-0 path is untouched.

using Test
using Bennett
using LLVM

@testset "Bennett-zyjn / U94 — _get_deref_bytes distinct failures" begin

    @testset "happy path: tuple-input fn compiles end-to-end" begin
        # Tuple{Int8, Int8} input → soft-LLVM passes the tuple by ref
        # via a `dereferenceable(N)` pointer arg. _get_deref_bytes is
        # called from _module_to_parsed_ir_on_func to determine the
        # flat wire width.
        f((a, b)::Tuple{Int8, Int8}) = a + b
        c = reversible_compile(f, Tuple{Tuple{Int8, Int8}})
        @test verify_reversibility(c)
        @test gate_count(c).total > 0
    end

    @testset "caller bug: param from a different function errors" begin
        # Build two LLVM functions, A and B. Pass a parameter from A
        # to _get_deref_bytes(B, ...). The function should error()
        # rather than silently returning 0 (the pre-zyjn behaviour).
        LLVM.Context() do _ctx
            mod = LLVM.Module("test_zyjn")
            i64 = LLVM.Int64Type()
            ptr = LLVM.PointerType()
            ftype = LLVM.FunctionType(i64, [ptr])
            func_a = LLVM.Function(mod, "a", ftype)
            func_b = LLVM.Function(mod, "b", ftype)

            param_a = first(LLVM.parameters(func_a))
            # Param from A passed against func B → caller-side miswiring.
            @test_throws "not in" Bennett._get_deref_bytes(func_b, param_a)
            @test_throws "Bennett-zyjn" Bennett._get_deref_bytes(func_b, param_a)
        end
    end

    @testset "expected: param without deref attr returns 0" begin
        # Build a single function with a pointer param that has NO
        # dereferenceable(N) attribute. _get_deref_bytes must return 0
        # (NOT error) — this is the legitimate "no info" case.
        LLVM.Context() do _ctx
            mod = LLVM.Module("test_zyjn_no_attr")
            i64 = LLVM.Int64Type()
            ptr = LLVM.PointerType()
            ftype = LLVM.FunctionType(i64, [ptr])
            func = LLVM.Function(mod, "f", ftype)
            param = first(LLVM.parameters(func))

            # No deref attribute set on this param.
            @test Bennett._get_deref_bytes(func, param) == 0
        end
    end
end
