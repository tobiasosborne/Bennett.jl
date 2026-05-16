; Bennett-land reject — undef ptr field.
; `<{ ptr undef, [8 x i8] }>`. `_ptr_identity` returns nothing for
; undef (unresolvable canonical identity); Bennett-land hard-rejects.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gundef = private unnamed_addr constant <{ ptr, [8 x i8] }> <{ ptr undef, [8 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_undef_ptr(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gundef, i64 16, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 7
  %y = load i8, ptr %p
  ret i8 %y
}
