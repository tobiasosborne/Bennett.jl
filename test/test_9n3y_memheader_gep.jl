# test/test_9n3y_memheader_gep.jl — bead bennettvm-9n3y (CW-D4): the Julia
# GenericMemory HEADER struct GEP (`getelementptr { i64, ptr }, ptr %m, i32 0,
# i32 K`) is stamped BYTE-granular (`elem_width = 8`) under ptr_cells, so the
# cell-addressed BennettVM lands the data-ptr field on byte-cell +8.
#
# # Why (the dual-shape ground truth — verified, callee_rehash!.ll:755-769 in
# # BennettVM.jl/scratchpad)
#
# Julia reads the SAME data-ptr field through TWO GEP shapes:
#
#   * element path (setindex!/getindex):
#       `getelementptr { i64, ptr }, ptr %m, i32 0, i32 1`  (word-shaped)
#   * fill!/memset path (rehash!, RUNTIME length — live and load-bearing):
#       `getelementptr i8, ptr %m, i32 8`                    (byte-shaped)
#
# BVM's per-GEP division rule (`cell = offset_bytes ÷ (elem_width÷8)`) maps the
# byte shape to cell +8 but the old word stamp (elem_width=64) to cell +1 — TWO
# different cells for ONE field. The already-shipped `jl_global#NNN` singleton
# headers (Bennett-416r.13) fixed byte granularity (length@byte-cell 0,
# data-ptr@byte-cell 8), so the header GEP must unify on BYTE: elem_width = 8.
#
# # Scope guard (the C-tier byte-identity constraint)
#
# The byte stamp fires ONLY for the LITERAL (unnamed) 2-element `{ i64, ptr }`
# struct — Julia's GenericMemory header shape. clang emits NAMED `%struct.T`
# types for ordinary C struct FIELD ACCESSES, so those keep the word-granular
# elem_width=64 stamp (the ptr_cells C tier is byte-identical; see
# test_haiy_ptr_cells_store_load_gep.jl's `%struct.ht` pins). CAVEAT
# (bennettvm-jb6w): clang's SysV register-coercion spill of a by-value
# `{long; void*}` struct CAN emit a literal `{i64,ptr}` GEP — a real,
# currently-untriggered mis-stamp mechanism tracked in that bead; the
# named-struct control below pins only the ordinary-field-access case.
#
# No literal `#NNN` names or LLVM formatting pinned (Rule 5): the fdict check
# is programmatic over extracted IRPtrOffset nodes.

using Test
import Bennett
using Bennett: extract_parsed_ir_from_ll

_9n3y_insts(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                          init = Bennett.IRInst[])

function _9n3y_extract_ll(ir::AbstractString, fn::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function = fn,
                                         ptr_cells = true)
    end
end

# LITERAL `{ i64, ptr }` — the Julia GenericMemory header shape (field-0 length
# GEP + field-1 data-ptr GEP + a load through the data pointer).
const _9N3Y_LITERAL_LL = """
define i64 @cwd4_memheader(ptr noundef %m) {
entry:
  %len_ptr = getelementptr inbounds { i64, ptr }, ptr %m, i32 0, i32 0
  %len = load i64, ptr %len_ptr, align 8
  %data_ptr = getelementptr inbounds { i64, ptr }, ptr %m, i32 0, i32 1
  %data = load ptr, ptr %data_ptr, align 8
  %e0 = load i64, ptr %data, align 8
  %r = add i64 %len, %e0
  ret i64 %r
}
"""

# NAMED `%struct.fake = type { i64, ptr }` — the same member shape but a C-tier
# named struct: MUST keep the word-granular 64-bit stamp.
const _9N3Y_NAMED_LL = """
%struct.fake = type { i64, ptr }
define i64 @cwd4_named(ptr noundef %m) {
entry:
  %len_ptr = getelementptr inbounds %struct.fake, ptr %m, i32 0, i32 0
  %len = load i64, ptr %len_ptr, align 8
  %data_ptr = getelementptr inbounds %struct.fake, ptr %m, i32 0, i32 1
  %data = load ptr, ptr %data_ptr, align 8
  %e0 = load i64, ptr %data, align 8
  %r = add i64 %len, %e0
  ret i64 %r
}
"""

@testset "Bennett 9n3y — {i64,ptr} GenericMemory header GEP byte stamp (CW-D4)" begin

    @testset "literal { i64, ptr } GEP → IRPtrOffset elem_width 8 (byte cells)" begin
        pir = _9n3y_extract_ll(_9N3Y_LITERAL_LL, "cwd4_memheader")
        ptroffs = [i for i in _9n3y_insts(pir) if i isa Bennett.IRPtrOffset]
        offs = sort(unique([p.offset_bytes for p in ptroffs]))
        @test offs == [0, 8]                       # length @ 0, data-ptr @ 8
        # THE stamp: byte-granular ⇒ BVM cell = 8 ÷ (8÷8) = 8 (matches the
        # i8 fill!/memset shape AND the 416r.13 singleton header layout).
        @test all(p -> p.elem_width == 8, ptroffs)
    end

    @testset "named %struct.fake {i64,ptr} keeps elem_width 64 (C tier untouched)" begin
        pir = _9n3y_extract_ll(_9N3Y_NAMED_LL, "cwd4_named")
        ptroffs = [i for i in _9n3y_insts(pir) if i isa Bennett.IRPtrOffset]
        @test !isempty(ptroffs)
        @test all(p -> p.elem_width == 64, ptroffs)
    end

    @testset "extracted fdict set: every memory_data_ptr IRPtrOffset is byte-stamped" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = Bennett.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                       ptr_cells = true)
        # The data-ptr field GEPs Julia codegen names `memory_data_ptr*`
        # (programmatic sweep across ALL functions in the closed set; count
        # not pinned — codegen may fold/duplicate sites).
        dps = [i for (_k, pir) in set for i in _9n3y_insts(pir)
               if i isa Bennett.IRPtrOffset &&
                  occursin("memory_data_ptr", String(i.dest))]
        @test !isempty(dps)
        @test all(p -> p.offset_bytes == 8, dps)
        @test all(p -> p.elem_width == 8, dps)
        # And NO word-stamped {i64,ptr} field-1 GEP survives anywhere in the
        # set: an offset-8 IRPtrOffset with elem_width 64 would be the old
        # cell+1 mis-address (the two-cells-for-one-field defect).
        stale = [i for (_k, pir) in set for i in _9n3y_insts(pir)
                 if i isa Bennett.IRPtrOffset && i.offset_bytes == 8 &&
                    i.elem_width == 64]
        @test isempty(stale)
    end
end
