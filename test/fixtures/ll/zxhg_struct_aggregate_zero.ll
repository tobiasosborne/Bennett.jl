; Bennett-zxhg positive — ConstantAggregateZero arm.
; `<{ [4 x i8], [4 x i8] }> zeroinitializer`. All 8 bytes zero. Load
; offset 5 → 0.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gzero = private unnamed_addr constant <{ [4 x i8], [4 x i8] }> zeroinitializer, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_aggregate_zero(i8 %x) {
entry:
  %dst = alloca [8 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gzero, i64 8, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 5
  %y = load i8, ptr %p
  ret i8 %y
}
