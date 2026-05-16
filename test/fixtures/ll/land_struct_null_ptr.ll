; Bennett-land positive — null-ptr field.
; `<{ ptr null, [8 x i8] c"ABCDEFGH" }>`. ConstantPointerNull
; materialises as 8 zero bytes (no counter bump). Body is carry-through
; only so the escape guard doesn't fire on extraction.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gnullptr = private unnamed_addr constant <{ ptr, [8 x i8] }> <{ ptr null, [8 x i8] c"ABCDEFGH" }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_null_ptr(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gnullptr, i64 16, i1 false)
  ret i8 %x
}
