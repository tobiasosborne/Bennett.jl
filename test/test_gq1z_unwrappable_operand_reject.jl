using Test
using Bennett
using Bennett: _parsed_ir_from_ir_string

# Bennett-gq1z (review 3 finding T1): `src/extract/module_walk.jl`'s cc0.3
# benign-error catch SKIPPED any instruction whose operand LLVM.jl cannot wrap
# ("Unknown value kind" — `blockaddress`, GlobalAlias, ...) unless a
# non-`jl_global` alias was involved (Bennett-n4di). A live
# `store ptr blockaddress(...)` was erased: the function then loaded the
# earlier 0 and the circuit returned 1 where the IR returns 0, with
# `verify_reversibility` true.
#
# Post-fix: an instruction with an unwrappable operand is skipped ONLY when
# every unwrappable operand is a Julia `jl_global#N.jit` runtime alias AND the
# instruction is a pure value (load / cast / GEP / ...): its result is then
# either unused or an undefined SSA name that lowering rejects. Everything
# else — any other operand kind, or a store / call / terminator through a
# jl_global alias — raises `_ir_error` naming Bennett-gq1z and the operand
# kind. The Bennett-4eu `indirectbr` diagnostic is kept by an explicit
# up-front terminator scan, not by dropping the `select` that feeds it.

function _gq1z_err(ir)
    try
        _parsed_ir_from_ir_string(ir)
    catch e
        return sprint(showerror, e)
    end
    return nothing
end

# Review 3 T1 witness, verbatim. The stored block address is non-null, so the
# IR returns 0; the pre-fix circuit returned 1.
const _GQ1Z_WITNESS = """
target datalayout = "e-p:64:64"
target triple = "x86_64-unknown-linux-gnu"
define i8 @julia_witness(i8 %x) {
entry:
  %a = alloca i64, align 8
  store i64 0, ptr %a, align 8
  store ptr blockaddress(@julia_witness, %done), ptr %a, align 8
  br label %done
done:
  %v = load i64, ptr %a, align 8
  %z = icmp eq i64 %v, 0
  %r = zext i1 %z to i8
  ret i8 %r
}
"""

const _GQ1Z_LOUD = [
    ("T1 witness: store of a blockaddress", "LLVMBlockAddressValueKind",
     _GQ1Z_WITNESS),
    # Pre-fix this intrinsic call was dropped silently (the memset arm wraps
    # its destination operand and hit "Unknown value kind").
    ("call taking a blockaddress argument", "LLVMBlockAddressValueKind", """
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
define i8 @julia_w(i8 %x) {
entry:
  call void @llvm.memset.p0.i64(ptr blockaddress(@julia_w, %done), i8 1, i64 8, i1 false)
  br label %done
done:
  ret i8 %x
}
"""),
    ("dead select over blockaddresses (no indirectbr)", "LLVMBlockAddressValueKind", """
define i8 @julia_w(i8 %x) {
entry:
  %t = select i1 true, ptr blockaddress(@julia_w, %done), ptr null
  br label %done
done:
  ret i8 %x
}
"""),
    ("store of a jl_global#N.jit alias pointer (side effect)", "jl_global#5.jit", """
@"jl_global#5" = global i8 0
@"jl_global#5.jit" = alias i8, ptr @"jl_global#5"
define i8 @julia_w(i8 %x) {
entry:
  ; Bennett-1zow: an `i64` slot (modelled), not `alloca ptr` — gate-off a ptr
  ; slot is an unmodelled alloca refused AT the alloca, before this store.
  %s = alloca i64, align 8
  store ptr @"jl_global#5.jit", ptr %s, align 8
  ret i8 %x
}
"""),
    ("store through a jl_global#N.jit alias (side effect)", "jl_global#5.jit", """
@"jl_global#5" = global i8 0
@"jl_global#5.jit" = alias i8, ptr @"jl_global#5"
define i8 @julia_w(i8 %x) {
entry:
  store i8 %x, ptr @"jl_global#5.jit", align 1
  ret i8 %x
}
"""),
]

# Already loud before gq1z by OTHER arms (never reached the skip); pinned so
# they stay loud: an unregistered callee (Bennett-5oyt / U15) and a ptrtoint
# ConstantExpr operand (cc0.4/cc0.6).
const _GQ1Z_ALREADY_LOUD = [
    ("unregistered call taking a blockaddress argument", """
declare void @sink(ptr)
define i8 @julia_w(i8 %x) {
entry:
  call void @sink(ptr blockaddress(@julia_w, %done))
  br label %done
done:
  ret i8 %x
}
"""),
    ("blockaddress inside a ConstantExpr store value", """
define i8 @julia_w(i8 %x) {
entry:
  %a = alloca i64, align 8
  store i64 ptrtoint (ptr blockaddress(@julia_w, %done) to i64), ptr %a, align 8
  br label %done
done:
  %v = load i64, ptr %a, align 8
  %r = trunc i64 %v to i8
  ret i8 %r
}
"""),
]

@testset "Bennett-gq1z: unwrappable operands are rejected, never skipped" begin
    for (label, ir) in _GQ1Z_ALREADY_LOUD
        @testset "$label" begin
            @test_throws ErrorException _parsed_ir_from_ir_string(ir)
            @test occursin("ir_extract.jl:", something(_gq1z_err(ir), ""))
        end
    end

    for (label, frag, ir) in _GQ1Z_LOUD
        @testset "$label" begin
            @test_throws ErrorException _parsed_ir_from_ir_string(ir)
            msg = something(_gq1z_err(ir), "")
            @test occursin("Bennett-gq1z", msg)
            @test occursin(frag, msg)
            @test occursin("ir_extract.jl:", msg)   # names function / block / inst
        end
    end

    # The Bennett-4eu hard stop keeps its precise message (fixture unchanged),
    # and wins even when a blockaddress is used BEFORE the indirectbr block.
    @testset "indirectbr still reports Bennett-4eu" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "4eu_indirectbr_reject.ll")
        msg = try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="julia_f_1")
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("indirectbr", msg)
        @test occursin("Bennett-4eu", msg)
        @test !occursin("Bennett-gq1z", msg)

        ir = """
define i8 @julia_w(i8 %x) {
entry:
  %a = alloca ptr, align 8
  store ptr blockaddress(@julia_w, %B), ptr %a, align 8
  br label %go
go:
  %t = load ptr, ptr %a, align 8
  indirectbr ptr %t, [label %B]
B:
  ret i8 %x
}
"""
        msg2 = something(_gq1z_err(ir), "")
        @test occursin("Bennett-4eu", msg2)
        @test !occursin("Bennett-gq1z", msg2)
    end

    # The certified skip is unchanged: a pure (load) use of a jl_global#N.jit
    # runtime alias whose result is dead is dropped, and the function compiles.
    @testset "jl_global#N.jit pure dead load still skipped" begin
        ir = """
@"jl_global#5" = global i8 0
@"jl_global#5.jit" = alias i8, ptr @"jl_global#5"
define i8 @julia_w(i8 %x) {
entry:
  %v = load i8, ptr @"jl_global#5.jit"
  %r = add i8 %x, 3
  ret i8 %r
}
"""
        pir = _parsed_ir_from_ir_string(ir)
        insts = pir.blocks[1].instructions
        @test length(insts) == 1 && insts[1] isa Bennett.IRBinOp
        c = reversible_compile(pir)
        @test verify_reversibility(c)
        bad = [x for x in typemin(Int8):typemax(Int8)
               if simulate(c, x) != x + Int8(3)]
        @test isempty(bad)
    end

    # Plain Julia is unaffected: end-to-end, exhaustive Int8.
    @testset "plain Julia end-to-end" begin
        f(x::Int8) = x * Int8(3) + Int8(1)
        c = reversible_compile(f, Int8)
        @test verify_reversibility(c)
        bad = [x for x in typemin(Int8):typemax(Int8) if simulate(c, x) != f(x)]
        @test isempty(bad)
    end
end
