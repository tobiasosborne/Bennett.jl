# Bennett-8su4 — volatile c=0 memset must NOT be rejected.
#
# Julia's heap-allocating frontend emits a GC-frame zero-init at function
# entry: `llvm.memset.p0.i64(ptr %gcframe, i8 0, i64 N, i1 true)` —
# volatile=true, c=0. Pre-8su4, `_handle_memset_arm` rejected it: the
# volatile-VALUE predicate fired BEFORE the c==0 silent-drop predicate, so
# the benign GC-frame memset was killed before the drop could catch it.
#
# Fix (Bennett-8su4): relocate the volatile-value check to AFTER the
# c==0/N==0 drop. A c==0 memset emits zero IRInsts regardless of
# volatility, so volatility is moot for it. Volatile c!=0 still rejects
# (predicate 8 doesn't fire for c!=0, so control reaches the relocated
# check).
#
# The malformed-IR guard (predicate 3 — isvolatile is a ConstantInt) is
# unchanged by Bennett-8su4. Research outcome (CLAUDE.md §9): a
# non-constant isvolatile arg IS constructible — if the `declare` omits
# the `immarg` attribute on the 4th parameter, LLVM's text parser accepts
# a module that passes an SSA value there. Predicate 3 catches it and
# fails loud. The "malformed isvolatile" sub-test below exercises that
# path and confirms it still rejects (it never reaches the relocated
# volatile-value check, since predicate 3 dominates).

using Test
using Bennett

@testset "Bennett-8su4: volatile c=0 memset accepted; volatile c!=0 rejected" begin

    @testset "volatile c=0 N=8: silent drop (case A), not rejected" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "8su4_memset_volatile_c0_n8.ll")
        parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_volatile_c0")
        # Pin: no IRStore was added by the memset (case A is empty no-op),
        # i.e. the volatile c=0 memset passed through the drop, not a reject.
        all_insts = vcat([blk.instructions for blk in parsed.blocks]...)
        memset_stores = filter(s -> s isa Bennett.IRStore && s.width == 8, all_insts)
        @test length(memset_stores) == 0
        c = reversible_compile(parsed)
        @test verify_reversibility(c)
        # Oracle: load dst[0] returns 0 since the alloca is zero-initialised
        # and the memset is a no-op.
        for x in Int8(-8):Int8(8)
            @test simulate(c, x) == 0
        end
    end

    @testset "volatile c!=0 still fails loud → 8bys" begin
        # Reuse the 9nwt volatile-reject fixture: i8 -1 (nonzero c),
        # volatile=true. c!=0 → predicate 8 doesn't fire → control reaches
        # the relocated volatile-value check, which rejects.
        path = joinpath(@__DIR__, "fixtures", "ll", "9nwt_memset_volatile_reject.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_volatile")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_volatile")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("volatile", msg)
            @test occursin("Bennett-8bys", msg)
        end
    end

    @testset "malformed isvolatile (non-constant SSA) fails loud (predicate 3)" begin
        # Research step (CLAUDE.md §9): the 4th memset operand is a
        # non-constant SSA value. Predicate 3 — the malformed-IR guard,
        # unchanged by Bennett-8su4 — rejects it before any value check.
        path = joinpath(@__DIR__, "fixtures", "ll", "8su4_memset_dynamic_volatile.ll")
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            path; entry_function="memset_dynvol")
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="memset_dynvol")
            @test false
        catch e
            msg = sprint(showerror, e)
            @test occursin("isvolatile arg is not", msg)
        end
    end

end
