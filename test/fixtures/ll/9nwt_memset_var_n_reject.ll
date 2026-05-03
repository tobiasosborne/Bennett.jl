; Bennett-9nwt reject — variable byte count (N is an SSA value).
; Variable-size memset needs runtime loop unrolling deferred to Bennett-8bys.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_var_n(i8 %x, i64 %n) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 -1, i64 %n, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
