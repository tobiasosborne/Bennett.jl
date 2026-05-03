; Bennett-9nwt reject — c≠0 on non-fresh alloca (a prior IRStore wrote
; to dst within the same block). Reversible model can't destructively
; overwrite; deferred to Bennett-8bys-uncompute.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_non_fresh(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  store i8 %x, ptr %dst
  call void @llvm.memset.p0.i64(ptr %dst, i8 -1, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
