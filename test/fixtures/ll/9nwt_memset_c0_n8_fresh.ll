; Bennett-9nwt fixture — case A: memset(c=0, N=8) on fresh alloca-i8.
; Lowers to IRInst[] (no-op). Oracle: load dst[0] returns 0 since the
; alloca is zero-initialised and the memset is a no-op.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_c0_n8(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
