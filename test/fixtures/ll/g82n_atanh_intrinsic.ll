; Bennett-g82n fixture — direct llvm.atanh.f64 dispatch.

declare double @llvm.atanh.f64(double)

define i64 @atanh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.atanh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
