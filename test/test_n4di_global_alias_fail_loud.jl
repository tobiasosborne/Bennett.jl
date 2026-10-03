using Test
using Bennett
using Bennett: _parsed_ir_from_ir_string

# Bennett-n4di (Astra B-extract-core F17): the cc0.3 benign-error swallow in
# `src/extract/module_walk.jl` dropped ANY instruction whose operand walk hit
# LLVM.jl's "Unknown value kind" on a GlobalAlias — not just Julia's
# `jl_global#N.jit` runtime aliases it was written for. A store or call
# through a user alias (`@a = alias i8, ptr @g`, as from_ll / clang emit) was
# ERASED: no SSA consumer remained to trip a later error, so the side effect
# vanished silently. Plain Julia never emits such aliases, so the witnesses
# are hand-written `.ll` strings through `_parsed_ir_from_ir_string`.
#
# Post-fix: the skip is admitted only when every alias the instruction touches
# is a `jl_global#N.jit` alias; anything else raises `_ir_error` naming the
# alias and its aliasee.

function _n4di_err(ir)
    try
        _parsed_ir_from_ir_string(ir)
    catch e
        return e
    end
    return nothing
end

const _N4DI_CASES = [
    ("store through alias (F17 witness)", "a", "g", """
@g = global i8 0
@a = alias i8, ptr @g
define i8 @julia_alias(i8 %x) {
entry:
  store i8 42, ptr @a
  ret i8 %x
}
"""),
    ("call through function alias", "ah", "h", """
define void @h(i8 %y) {
entry:
  ret void
}
@ah = alias void (i8), ptr @h
define i8 @julia_alias(i8 %x) {
entry:
  call void @ah(i8 %x)
  ret i8 %x
}
"""),
    ("live load through alias", "a", "g", """
@g = global i8 7
@a = alias i8, ptr @g
define i8 @julia_alias(i8 %x) {
entry:
  %v = load i8, ptr @a
  %r = add i8 %v, %x
  ret i8 %r
}
"""),
    ("dead load through alias", "a", "g", """
@g = global i8 7
@a = alias i8, ptr @g
define i8 @julia_alias(i8 %x) {
entry:
  %v = load i8, ptr @a
  ret i8 %x
}
"""),
    ("load through alias of a constant global", "a", "g", """
@g = constant i8 7
@a = alias i8, ptr @g
define i8 @julia_alias(i8 %x) {
entry:
  %v = load i8, ptr @a
  %r = add i8 %v, %x
  ret i8 %r
}
"""),
]

# An alias nested inside a ConstantExpr store target never reached the
# swallow: LLVM.jl wraps the ConstantExpr, and the store arm rejects the
# non-SSA target loudly (Bennett-lgzx / U114). Pinned so it stays loud.
const _N4DI_GEP_IR = """
@g = global [2 x i8] zeroinitializer
@a = alias [2 x i8], ptr @g
define i8 @julia_alias(i8 %x) {
entry:
  store i8 %x, ptr getelementptr (i8, ptr @a, i64 1)
  ret i8 %x
}
"""

@testset "Bennett-n4di: non-jl_global GlobalAlias operands fail loud" begin
    for (label, alias, aliasee, ir) in _N4DI_CASES
        @testset "$label" begin
            @test_throws ErrorException _parsed_ir_from_ir_string(ir)
            e = _n4di_err(ir)
            msg = e === nothing ? "" : sprint(showerror, e)
            @test occursin("Bennett-n4di", msg)
            @test occursin("`@$alias` (aliasee `@$aliasee`)", msg)
        end
    end

    @testset "alias inside a ConstantExpr GEP store target" begin
        @test_throws ErrorException _parsed_ir_from_ir_string(_N4DI_GEP_IR)
        e = _n4di_err(_N4DI_GEP_IR)
        @test e !== nothing && occursin("ir_extract.jl: store", sprint(showerror, e))
    end

    # The tolerated case stays exactly as before: an instruction whose only
    # alias operand is a Julia `jl_global#N.jit` runtime alias is still
    # skipped (dead use → nothing left to consume it).
    @testset "jl_global#N.jit alias skip still admitted" begin
        ir = """
@"jl_global#5" = global i8 0
@"jl_global#5.jit" = alias i8, ptr @"jl_global#5"
define i8 @julia_alias(i8 %x) {
entry:
  %v = load i8, ptr @"jl_global#5.jit"
  %r = add i8 %x, 3
  ret i8 %r
}
"""
        pir = _parsed_ir_from_ir_string(ir)
        @test length(pir.blocks) == 1
        insts = pir.blocks[1].instructions
        @test length(insts) == 1
        @test insts[1] isa Bennett.IRBinOp
        @test insts[1].dest == :r
    end

    # Scope pin: an unwrappable operand that is NOT an alias (blockaddress in
    # a select) is not an n4di error; the indirectbr hard stop (Bennett-4eu)
    # is what rejects the module.
    @testset "blockaddress operand without alias is not an n4di error" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "4eu_indirectbr_reject.ll")
        e = try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="julia_f_1")
            nothing
        catch ex
            ex
        end
        msg = e === nothing ? "" : sprint(showerror, e)
        @test e !== nothing
        @test !occursin("Bennett-n4di", msg)
        @test occursin("indirectbr", msg)
        @test occursin("Bennett-4eu", msg)
    end

    # Plain Julia is unaffected: end-to-end, exhaustive Int8.
    @testset "plain Julia compile unchanged" begin
        f(x::Int8) = x * Int8(3) + Int8(1)
        c = reversible_compile(f, Int8)
        bad = [x for x in typemin(Int8):typemax(Int8) if simulate(c, x) != f(x)]
        isempty(bad) || @info "n4di mismatches" first(bad, 5)
        @test isempty(bad)
        @test verify_reversibility(c)
    end
end
