; Bennett-lqif fixture — llvm.memmove fails loud at IR walking.

declare void @llvm.memmove.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memmove_user(i64 %x) {
entry:
  %src = alloca i64, align 8
  %dst = alloca i64, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memmove.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
