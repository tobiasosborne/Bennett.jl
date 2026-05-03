; Bennett-lqif fixture — llvm.memcpy fails loud at IR walking.
; Pre-Bennett-lqif this would be silent-dropped via the benign-prefixes
; allowlist; post-Bennett-lqif it errors with a reference to Bennett-37mt
; / 9nwt / 8bys for the proper-lowering tracking beads.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_user(i64 %x) {
entry:
  %src = alloca i64, align 8
  %dst = alloca i64, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
