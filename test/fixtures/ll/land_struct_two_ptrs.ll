; Bennett-land positive — two distinct ptrs in same struct.
; `<{ ptr @a, ptr @b }>`. Counter assigns @a → addr 0x1000_..._0000
; (byte 7 = 0x10), @b → addr 0x1000_..._0001 (byte 8 = 0x01,
; byte 15 = 0x10). Body is carry-through only.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@a = private unnamed_addr constant [2 x i8] c"\01\02", align 1
@b = private unnamed_addr constant [2 x i8] c"\03\04", align 1
@gtwo = private unnamed_addr constant <{ ptr, ptr }> <{ ptr @a, ptr @b }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_two_ptrs(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gtwo, i64 16, i1 false)
  ret i8 %x
}
