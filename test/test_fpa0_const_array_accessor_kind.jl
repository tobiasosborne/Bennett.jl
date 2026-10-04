# Bennett-fpa0 — constant-global extraction must never call a raw LLVM C-API
# accessor on a value kind it does not support.
#
# Pre-fix, `_flatten_struct_to_bytes` (src/extract/module_walk.jl) admitted a
# struct field that is a plain `ConstantArray` into the same branch as a dense
# `ConstantDataArray` and called `LLVMGetElementAsConstant` on it — an accessor
# valid ONLY for `ConstantDataSequential`. LLVM then read garbage and the whole
# Julia process died with SIGSEGV (exit 139), even when the entry function never
# touched the global (every constant global is scanned). LLVM canonicalises an
# all-`ConstantInt` integer array to `ConstantDataArray`, so a `ConstantArray`
# field of integers always carries an `undef` / `poison` / constant-expression
# element — had the accessor not crashed, the fallback would have zero-filled it.
#
# Invariant: an integer array is read element-wise only through the accessor
# its kind supports (`LLVMGetElementAsConstant` on ConstantDataArray, operands
# on ConstantArray); every element must be a plain ConstantInt, otherwise the
# WHOLE global is left out of `parsed.globals` (never zero-filled). An unread
# such global therefore costs nothing; a READ of it fails loud at the memcpy
# G5 gate ("not extractable as a constant integer byte stream").
#
# Before the fix the crashing cases below killed the test process. After the
# fix nothing segfaults, so in-process `@test_throws` / value checks are fine:
# a regression shows up as a test failure (or, at worst, a dead process that
# the runner reports as such).

using Test, Bennett

const _FPA0_DL = "target datalayout = \"e-m:e-i64:64-f80:128-n8:16:32:64-S128\"\n" *
    "declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)\n" *
    "@h = constant i8 5\n"

_fpa0_unread(gdecl) = _FPA0_DL * gdecl * "\n" * """
define i8 @julia_f(i8 %x) {
entry:
  ret i8 %x
}
"""

# memcpy the whole global into a byte alloca and load byte (x & (nbytes-1)).
_fpa0_read(gdecl, nbytes) = _FPA0_DL * gdecl * "\n" * """
define i8 @julia_f(i8 %x) {
entry:
  %dst = alloca [$nbytes x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @g, i64 $nbytes, i1 false)
  %i = and i8 %x, $(nbytes - 1)
  %iz = zext i8 %i to i64
  %p = getelementptr inbounds i8, ptr %dst, i64 %iz
  %y = load i8, ptr %p
  ret i8 %y
}
"""

_le(v::Integer, nb) = UInt8[(UInt64(v) >> (8k)) & 0xff for k in 0:nb-1]

# (name, array type, array literal, total bytes of the bare array,
#  expected little-endian bytes or :refuse)
const _FPA0_ARRAYS = [
    ("cda_i8",   "[2 x i8]",  "[i8 1, i8 2]", 2, UInt8[1, 2]),
    ("cda_i32",  "[2 x i32]", "[i32 258, i32 -1]", 8,
        vcat(_le(258, 4), _le(typemax(UInt32), 4))),
    ("cda_i64",  "[2 x i64]", "[i64 72623859790382856, i64 5]", 16,
        vcat(_le(72623859790382856, 8), _le(5, 8))),
    ("zeroinit", "[2 x i8]",  "zeroinitializer", 2, UInt8[0, 0]),
    ("nested",   "[2 x [2 x i8]]",
        "[[2 x i8] [i8 1, i8 2], [2 x i8] [i8 3, i8 4]]", 4, :refuse),
    ("undef",    "[2 x i8]",  "[i8 1, i8 undef]", 2, :refuse),
    ("poison",   "[2 x i8]",  "[i8 1, i8 poison]", 2, :refuse),
    ("ptrtoint", "[2 x i64]", "[i64 ptrtoint (ptr @h to i64), i64 0]", 16, :refuse),
    ("ptr_elem", "[2 x ptr]", "[ptr @h, ptr null]", 16, :refuse),
    ("arr_of_struct", "[2 x { i8, i8 }]",
        "[{ i8, i8 } { i8 1, i8 2 }, { i8, i8 } { i8 3, i8 4 }]", 4, :refuse),
]

# Wrappers: the array as a struct field (the crashing `_flatten_struct_to_bytes`
# path) and as the bare global initializer (`_extract_const_globals`).
_fpa0_struct(ty, lit) = "@g = constant { $ty } { $ty $lit }"
_fpa0_bare(ty, lit)   = "@g = constant $ty $lit"

const _FPA0_G5 = "not extractable as a constant integer byte stream"

@testset "Bennett-fpa0: const-array element accessor matches value kind" begin
    for (wname, wrap) in (("struct-field", _fpa0_struct), ("bare", _fpa0_bare))
        for (name, ty, lit, nbytes, want) in _FPA0_ARRAYS
            # A bare non-i8 array is memcpy'd into an i8 dst — that is the
            # (unrelated) G6 cross-width reject, so only the i8-shaped bare
            # arrays get a read leg; the unread leg runs for every case.
            bare_cross_width = wname == "bare" && want !== :refuse &&
                               !(ty in ("[2 x i8]",))
            gdecl = wrap(ty, lit)
            @testset "$wname / $name / unread" begin
                p = Bennett._parsed_ir_from_ir_string(_fpa0_unread(gdecl))
                if want === :refuse
                    @test !haskey(p.globals, :g)
                else
                    @test haskey(p.globals, :g)
                end
                c = reversible_compile(p)
                @test verify_reversibility(c)
                @test all(simulate(c, x) == x for x in typemin(Int8):typemax(Int8))
            end
            bare_cross_width && continue
            @testset "$wname / $name / read" begin
                ir = _fpa0_read(gdecl, nbytes)
                if want === :refuse
                    err = try
                        Bennett._parsed_ir_from_ir_string(ir); nothing
                    catch e
                        e
                    end
                    @test err isa ErrorException
                    @test err !== nothing && occursin(_FPA0_G5, sprint(showerror, err))
                    @test err !== nothing && occursin("@g", sprint(showerror, err))
                else
                    p = Bennett._parsed_ir_from_ir_string(ir)
                    gdata, _ = p.globals[:g]
                    c = reversible_compile(p)
                    @test verify_reversibility(c)
                    for x in 0:255
                        @test simulate(c, Int8(x - 128)) ==
                              reinterpret(Int8, want[((x - 128) & (nbytes - 1)) + 1])
                    end
                end
            end
        end
    end

    @testset "dense data arrays are decoded element-exact (no zero fallback)" begin
        p = Bennett._parsed_ir_from_ir_string(_fpa0_unread(
            "@g = constant [3 x i16] [i16 1, i16 -2, i16 300]"))
        @test p.globals[:g] == (UInt64[1, 0xfffe, 300], 16)
        p = Bennett._parsed_ir_from_ir_string(_fpa0_unread(
            "@g = constant { i8, [2 x i16] } { i8 7, [2 x i16] [i16 -1, i16 2] }"))
        @test p.globals[:g][1] == UInt64[7, 0, 0xff, 0xff, 2, 0]
    end
end
