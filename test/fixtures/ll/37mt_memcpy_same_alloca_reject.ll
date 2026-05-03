; Bennett-37mt reject — src and dst share the same alloca root
; (semantically a memmove / self-copy). Reversibility forbids
; destructive in-place overwrite; reject deferred to Bennett-8bys.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_self(i8 %x) {
entry:
  %p = alloca i8, i32 8
  store i8 %x, ptr %p
  call void @llvm.memcpy.p0.p0.i64(ptr %p, ptr %p, i64 8, i1 false)
  %y = load i8, ptr %p
  ret i8 %y
}
