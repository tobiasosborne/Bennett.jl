; Bennett-0ulc fixture — direct llvm.log1p.f64 dispatch.

declare double @llvm.log1p.f64(double)

define i64 @log1p_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.log1p.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
