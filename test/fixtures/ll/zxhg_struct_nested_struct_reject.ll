; Bennett-zxhg reject — nested struct with a ptr in the inner struct.
; `<{ <{ i8, ptr }>, i8 }>`. Verifies recursive rejection propagates.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@target2 = private unnamed_addr constant [2 x i8] c"\05\06", align 1
@gnest = private unnamed_addr constant <{ <{ i8, ptr }>, i8 }> <{ <{ i8, ptr }> <{ i8 7, ptr @target2 }>, i8 9 }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_nested(i8 %x) {
entry:
  %dst = alloca [10 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gnest, i64 10, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 0
  %y = load i8, ptr %p
  ret i8 %y
}
