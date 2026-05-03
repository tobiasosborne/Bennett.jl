; Bennett-37mt reject — variable byte count (the 3rd argument is an
; SSA value, not a ConstantInt). Variable-size memcpy needs runtime
; loop unrolling deferred to Bennett-8bys.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_var_n(i8 %x, i64 %n) {
entry:
  %src = alloca i8, i32 8
  %dst = alloca i8, i32 8
  store i8 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 %n, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
