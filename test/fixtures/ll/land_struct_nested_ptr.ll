; Bennett-land positive — nested struct with inner ptr.
; `<{ <{ ptr @x, [4 x i8] }>, [8 x i8] }>`. Inner ptr's prov entry
; lifts to outer offset 0. Body is carry-through only.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@x = private unnamed_addr constant [2 x i8] c"\AA\BB", align 1
@gnested = private unnamed_addr constant <{ <{ ptr, [4 x i8] }>, [8 x i8] }> <{ <{ ptr, [4 x i8] }> <{ ptr @x, [4 x i8] c"\11\22\33\44" }>, [8 x i8] c"\55\66\77\88\99\AA\BB\CC" }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_nested_ptr(i8 %x) {
entry:
  %dst = alloca [20 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gnested, i64 20, i1 false)
  ret i8 %x
}
