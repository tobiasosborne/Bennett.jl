; Bennett-37mt reject — llvm.memmove ALWAYS fails loud. Memmove
; permits overlapping ranges; Bennett has no static alias analysis
; to prove non-overlap, and reversibility cannot honor in-place
; overwrite anyway. Deferred to Bennett-8bys.

declare void @llvm.memmove.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memmove_user(i8 %x) {
entry:
  %src = alloca i8, i32 8
  %dst = alloca i8, i32 8
  store i8 %x, ptr %src
  call void @llvm.memmove.p0.p0.i64(ptr %dst, ptr %src, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
