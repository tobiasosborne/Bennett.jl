# Bennett-k3ej / BVM ADR 0020 (CW-C2 chunk A) — two decisions, one file.
#
# This is the Bennett.jl-side implementation of the BennettVM closed-world
# C-track front-end contract (BennettVM.jl docs/adr/0020-c-track-frontend-contract.md):
#
#   D1. `IRCall.callee` widens from `Function` to `Union{Function,Symbol}`.
#       A `.ll`-sourced callee carries only a NAME (there is no Julia
#       `Function` object to bind); BVM already consumes callees by name
#       (`nameof` → `_HEAP_DISPATCH` / guard-5 function table). We keep the
#       single `IRCall` type (no `IRCallByName` fork — Law 2) and add a
#       Symbol-callee constructor overload that mirrors the Function one. The
#       Function path is byte-identical; the diagnostic sites resolve the
#       callee name via `_callee_name` so a Symbol callee names itself.
#
#   D2. A C `ptr` parameter WITHOUT a `dereferenceable(N)` attribute (the C
#       heap-pointer case) becomes an opaque Int64 cell-address argument
#       (width 64). Gated to `deref == 0` so the Julia NTuple-by-ref / sret
#       model (`deref > 0`) is untouched. Two robustness pieces enable this:
#       (i) `_get_deref_bytes`'s text fallback now locates the actual
#       `define`/`declare` line instead of blindly reading `string(func)`
#       line 1 — clang prefixes each function with a `; Function Attrs:`
#       COMMENT line, which previously triggered the "malformed define"
#       AssertionError on every C function (the ptr-parameter wall); and
#       (ii) the module walk maps a deref-absent ptr param to a 64-bit arg
#       instead of silently skipping it.
#
# The extraction assertions below verify the FRONTIER ADVANCES exactly as ADR
# 0020 predicts: `ht_get`'s wall moves from the deref AssertionError to the
# `store ptr` wall (chunk B); `ht_free`/`ht_new` are blocked UPSTREAM of the
# param loop (at return-type width — void / pointer return, chunk C / chunk B),
# so D2 correctly does not reach them. The fixture is read-only reference
# (BennettVM.jl); the inline `.ll` strings exercise D2 in isolation.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, soft_fadd

# Read-only BennettVM fixture (never written; probed for the frontier).
const _K3EJ_HT_LL =
    "/home/tobias/Projects/BennettVM.jl/test/reference/c/hashtable.O0.ll"

# A minimal C-style `.ll`: a `ptr` parameter with NO dereferenceable attribute,
# plus an integer param, plus a clang-style `; Function Attrs:` comment line so
# we exercise the actual-define-line fallback. Body is a trivial integer return
# that does NOT touch the pointer, so extraction must succeed end-to-end with
# the pointer modelled as a 64-bit cell-address arg.
const _K3EJ_C_PTR_LL = """
; Function Attrs: noinline nounwind optnone
define i64 @c_ptr_passthru(ptr noundef %p, i64 noundef %k) #0 {
entry:
  %r = add i64 %k, 1
  ret i64 %r
}
"""

@testset "Bennett-k3ej IRCall Symbol callee + C ptr-param (BVM ADR 0020 D1+D2)" begin

    # ---- D1: IRCall.callee :: Union{Function,Symbol} ----
    @testset "D1 — Symbol-callee construction + validation" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)

        # Symbol callee constructs and is stored verbatim.
        call = Bennett.IRCall(:r, :free, [a], [64], 64)
        @test call isa Bennett.IRCall
        @test call.callee === :free
        @test call.callee isa Symbol

        # Same validations as the Function path: arity, ret_width, arg_widths.
        @test_throws "length(args)"   Bennett.IRCall(:r, :memcpy, [a], [64, 64], 64)
        @test_throws "ret_width=0"    Bennett.IRCall(:r, :memcpy, [a, b], [64, 64], 0)
        @test_throws "arg_widths[1]=0" Bennett.IRCall(:r, :memcpy, [a, b], [0, 64], 64)

        # The Symbol name appears in diagnostics (callee self-names).
        @test_throws "callee=memcpy" Bennett.IRCall(:r, :memcpy, [a], [64, 64], 64)
    end

    @testset "D1 — Function-callee path unchanged (byte-identical behaviour)" begin
        a = Bennett.ssa(:a); b = Bennett.ssa(:b)
        # Mirror of test_k7al_ir_constructor_asserts.jl's IRCall block — these
        # must behave identically post-widening.
        @test Bennett.IRCall(:r, soft_fadd, [a, b], [64, 64], 64) isa Bennett.IRCall
        c = Bennett.IRCall(:r, soft_fadd, [a, b], [64, 64], 64)
        @test c.callee === soft_fadd
        @test c.callee isa Function
        @test_throws "length(args)"    Bennett.IRCall(:r, soft_fadd, [a], [64, 64], 64)
        @test_throws "ret_width=0"     Bennett.IRCall(:r, soft_fadd, [a, b], [64, 64], 0)
        @test_throws "arg_widths[1]=0" Bennett.IRCall(:r, soft_fadd, [a, b], [0, 64], 64)
        # Function callee still names itself via nameof.
        @test_throws "callee=soft_fadd" Bennett.IRCall(:r, soft_fadd, [a], [64, 64], 64)
    end

    @testset "D1 — _callee_name dispatch" begin
        @test Bennett._callee_name(:free) === :free
        @test Bennett._callee_name(soft_fadd) === nameof(soft_fadd)
    end

    # ---- D2: C ptr parameter → opaque Int64 cell-address arg ----
    @testset "D2 — deref-absent ptr param becomes 64-bit cell-address arg" begin
        mktempdir() do dir
            path = joinpath(dir, "c_ptr_passthru.ll")
            write(path, _K3EJ_C_PTR_LL)
            pir = extract_parsed_ir_from_ll(path; entry_function="c_ptr_passthru")
            widths = Dict{Symbol,Int}(name => w for (name, w) in pir.args)
            # The ptr param is an opaque 64-bit cell address ...
            @test widths[:p] == 64
            # ... and the integer param is unchanged.
            @test widths[:k] == 64
            # Both params are present (the ptr is NOT silently skipped anymore).
            @test length(pir.args) == 2
        end
    end

    # ---- D2: the BennettVM C fixture frontier advances as ADR 0020 predicts ----
    # These run only if the read-only reference fixture is present.
    if isfile(_K3EJ_HT_LL)
        @testset "D2 — ht_get frontier advances PAST the deref wall" begin
            # Pre-D2: AssertionError from `_get_deref_bytes` (malformed define).
            # Post-D2: the ptr params (`%t`, `%found`) become 64-bit cell args;
            # the NEXT wall is the `store ptr` of the pointer into its alloca
            # slot (ADR 0020 D3 / chunk B). Assert the error CHANGED and is the
            # store-ptr wall, NOT the deref AssertionError.
            err = try
                extract_parsed_ir_from_ll(_K3EJ_HT_LL; entry_function="ht_get")
                nothing
            catch e
                e
            end
            @test err !== nothing                       # still fails (chunk B/C remain)
            @test !(err isa AssertionError)             # NOT the deref AssertionError
            msg = sprint(showerror, err)
            @test occursin("store", msg)                # the store-ptr wall
            @test occursin("non-integer type", msg)     # store of pointer type
            @test !occursin("_get_deref_bytes", msg)    # param wall is cleared
        end

        @testset "D2 — ht_free / ht_new blocked UPSTREAM of the param loop" begin
            # ht_free returns `void`; ht_new returns `ptr`. Both die at the
            # RETURN-TYPE width query (module_walk return-width block), which is
            # upstream of the parameter loop — so D2 correctly does NOT reach
            # their ptr params. These walls are ADR 0020 chunk B (pointer
            # return = 64-bit cell) / chunk C (void return = no dest). Documented
            # here so the next chunk knows the real frontier (NOT the deref wall).
            free_msg = try
                extract_parsed_ir_from_ll(_K3EJ_HT_LL; entry_function="ht_free")
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("VoidType", free_msg)        # void-return wall (chunk C)
            @test !occursin("_get_deref_bytes", free_msg)

            new_msg = try
                extract_parsed_ir_from_ll(_K3EJ_HT_LL; entry_function="ht_new")
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("unsupported LLVM type", new_msg)  # ptr-return wall (chunk B)
            @test occursin("PointerType", new_msg)
            @test !occursin("_get_deref_bytes", new_msg)
        end
    end
end
