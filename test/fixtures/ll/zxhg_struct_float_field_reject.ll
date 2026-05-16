; Bennett-zxhg reject — `<{ i8, float }>`. FloatType field has no
; integer materialization in zxhg's MVP — hard-rejects.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gfloat = private unnamed_addr constant <{ i8, float }> <{ i8 1, float 0x4009000000000000 }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_float(i8 %x) {
entry:
  %dst = alloca [5 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gfloat, i64 5, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 0
  %y = load i8, ptr %p
  ret i8 %y
}
