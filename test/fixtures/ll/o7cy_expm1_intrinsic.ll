; Bennett-o7cy fixture — direct llvm.expm1.f64 dispatch.

declare double @llvm.expm1.f64(double)

define i64 @expm1_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.expm1.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
