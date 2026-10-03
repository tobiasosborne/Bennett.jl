# Bennett-pdwn — type-tag interning must not collide with null (or any other
# VM pointer namespace), and must be consistent across separately extracted
# functions of a closed-world set.
#
# Pre-fix (Astra B-extract-core F19): `tag_ids` minted dense first-seen ids
# starting at 0, so the FIRST type tag a function loaded was the integer 0 —
# the null-pointer cell encoding (Bennett-beaw / 8g7m lower `ptr null` to
# `ConstOperand(0)`). `icmp eq ptr %tag, null` therefore returned 1 for a
# non-null type pointer, with `verify_reversibility` passing. The small ids
# 1, 2, … also coincide with BennettVM stack addresses `[1, 2^40)`, and the
# per-function dict gave the same type different ids in different functions
# (and different types the same id).
#
# Post-fix: a type tag's id is a pure function of its canonical type path,
# placed in a reserved, never-allocated band of the read-only globals tier
# (`[GLOBAL_BASE + 2^46, GLOBAL_BASE + 2^47)`, below the empty-Memory data
# sentinel), and a process-wide registry fails loud if two distinct types
# ever map to the same id.

using Test
using Bennett
using Bennett: ParsedIR, IRBinOp, ConstOperand

_pdwn_extract(ir) = Bennett._parsed_ir_from_ir_string(ir; ptr_cells=true)

# The minted id carried by the tag-load `dest`: IRBinOp(dest, :or, iconst(id), iconst(0), 64).
function _pdwn_tag_id(pir::ParsedIR, dest::Symbol)
    for b in pir.blocks, ins in b.instructions
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or &&
           ins.op1 isa ConstOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins.op1.value
        end
    end
    return nothing
end

# Compile the i8 -> i1 fixture and check the result for all 256 inputs.
function _pdwn_check_const_i1(pir::ParsedIR, want::Bool)
    c = reversible_compile(pir)
    @test verify_reversibility(c)
    bad = Tuple{Int,Any}[]
    for x in typemin(Int8):typemax(Int8)
        r = simulate(c, x)
        (r != 0) == want || push!(bad, (Int(x), r))
    end
    isempty(bad) || @info "Bennett-pdwn mismatches (first 5)" bad[1:min(5, end)]
    @test isempty(bad)
end

# The Astra F19 witness: a non-null type pointer compared to null. Julia emits
# the type-tag global in exactly this `constant ptr inttoptr (i64 K to ptr)` form.
const PDWN_NULL_EQ = """
@"+Main.Core.Int8#1" = constant ptr inttoptr (i64 1234 to ptr)

define i1 @julia_tag(i8 %x) {
entry:
  %tag = load ptr, ptr @"+Main.Core.Int8#1"
  %r = icmp eq ptr %tag, null
  ret i1 %r
}
"""
const PDWN_NULL_NE = replace(PDWN_NULL_EQ, "icmp eq" => "icmp ne")

# Two loads of one type (different `#N`) and one load of another, compared.
const PDWN_SAME_TYPE = """
@"+Main.Base.Dict#148" = external global ptr
@"+Main.Base.Dict#999" = external global ptr

define i1 @julia_same(i8 %x) {
entry:
  %a = load ptr, ptr @"+Main.Base.Dict#148"
  %b = load ptr, ptr @"+Main.Base.Dict#999"
  %r = icmp eq ptr %a, %b
  ret i1 %r
}
"""
const PDWN_DIFF_TYPE = """
@"+Main.Base.Dict#148" = external global ptr
@"+Core.AssertionError#153" = external global ptr

define i1 @julia_diff(i8 %x) {
entry:
  %a = load ptr, ptr @"+Main.Base.Dict#148"
  %b = load ptr, ptr @"+Core.AssertionError#153"
  %r = icmp eq ptr %a, %b
  ret i1 %r
}
"""

# The same two types loaded in OPPOSITE orders by two separately extracted
# functions (the closed-world set extracts each function on its own).
const PDWN_ORDER_AB = """
@"+Main.Base.Dict#148" = external global ptr
@"+Core.AssertionError#153" = external global ptr

define i64 @julia_ab() {
top:
  %ta = load ptr, ptr @"+Main.Base.Dict#148"
  %da = ptrtoint ptr %ta to i64
  %tb = load ptr, ptr @"+Core.AssertionError#153"
  %db = ptrtoint ptr %tb to i64
  %s = xor i64 %da, %db
  ret i64 %s
}
"""
const PDWN_ORDER_BA = """
@"+Main.Base.Dict#7" = external global ptr
@"+Core.AssertionError#8" = external global ptr

define i64 @julia_ba() {
top:
  %tb = load ptr, ptr @"+Core.AssertionError#8"
  %db = ptrtoint ptr %tb to i64
  %ta = load ptr, ptr @"+Main.Base.Dict#7"
  %da = ptrtoint ptr %ta to i64
  %s = xor i64 %da, %db
  ret i64 %s
}
"""

const PDWN_GLOBAL_BASE = Int64(1) << 48

@testset "Bennett-pdwn: type-tag ids never collide with null / pointer namespaces" begin

    @testset "non-null type tag compared to null (Astra F19 witness)" begin
        pir = _pdwn_extract(PDWN_NULL_EQ)
        id = _pdwn_tag_id(pir, :tag)
        @test id !== nothing && id != 0
        _pdwn_check_const_i1(pir, false)               # tag == null  → false
        _pdwn_check_const_i1(_pdwn_extract(PDWN_NULL_NE), true)   # tag != null → true
    end

    @testset "ids lie in the reserved type-tag band of the globals tier" begin
        pir = _pdwn_extract(PDWN_ORDER_AB)
        for d in (:ta, :tb)
            id = _pdwn_tag_id(pir, d)
            @test id !== nothing
            # Above the stack [1, 2^40) and the malloc arena [2^40, 2^48).
            @test id >= PDWN_GLOBAL_BASE + (Int64(1) << 46)
            # Below (and distinct from) the empty-Memory data sentinel.
            @test id < Int64(Bennett._EMPTY_MEMORY_DATA_SENTINEL)
            @test id % 8 == 0
        end
    end

    @testset "same type (different #N) equal, different types unequal — circuit" begin
        _pdwn_check_const_i1(_pdwn_extract(PDWN_SAME_TYPE), true)
        _pdwn_check_const_i1(_pdwn_extract(PDWN_DIFF_TYPE), false)
    end

    @testset "ids are consistent across separately extracted functions" begin
        p_ab = _pdwn_extract(PDWN_ORDER_AB)
        p_ba = _pdwn_extract(PDWN_ORDER_BA)
        dict_ab, aerr_ab = _pdwn_tag_id(p_ab, :ta), _pdwn_tag_id(p_ab, :tb)
        dict_ba, aerr_ba = _pdwn_tag_id(p_ba, :ta), _pdwn_tag_id(p_ba, :tb)
        @test dict_ab == dict_ba           # same type, opposite first-seen order
        @test aerr_ab == aerr_ba
        @test dict_ab != aerr_ab           # distinct types stay distinct
        # Re-extraction is deterministic.
        @test _pdwn_tag_id(_pdwn_extract(PDWN_ORDER_AB), :ta) == dict_ab
    end

    @testset "two distinct types mapping to one id fails loud" begin
        id = Bennett._type_tag_id("Main.Base.Dict")
        @test id == _pdwn_tag_id(_pdwn_extract(PDWN_ORDER_AB), :ta)
        # Simulate a hash collision: claim Dict's id for a different type.
        reg = Bennett._TYPE_TAG_REGISTRY
        saved = lock(Bennett._TYPE_TAG_REGISTRY_LOCK) do
            old = reg[id]
            reg[id] = "Main.Pdwn.Impostor"
            old
        end
        try
            err = try
                _pdwn_extract(PDWN_ORDER_AB); nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test err !== nothing
            err === nothing || @test occursin("Bennett-pdwn", err)
        finally
            lock(Bennett._TYPE_TAG_REGISTRY_LOCK) do
                reg[id] = saved
            end
        end
    end
end
