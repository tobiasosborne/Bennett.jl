; Bennett-zxhg reject — `<{ i128, i8 }>`. The i128 field exceeds the
; 64-bit-max width policy in `_flatten_struct_to_bytes`.

target datalayout = "e-m:e-i64:64-i128:128-f80:128-n8:16:32:64-S128"

@gwide = private unnamed_addr constant <{ i128, i8 }> <{ i128 1, i8 2 }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_too_wide(i8 %x) {
entry:
  %dst = alloca [17 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gwide, i64 17, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 0
  %y = load i8, ptr %p
  ret i8 %y
}
