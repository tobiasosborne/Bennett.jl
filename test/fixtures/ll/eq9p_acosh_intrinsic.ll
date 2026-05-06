; Bennett-eq9p fixture — direct llvm.acosh.f64 dispatch.

declare double @llvm.acosh.f64(double)

define i64 @acosh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.acosh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
