; Bennett-k2w6 — llvm.maximum.f64 dispatch fixture (NaN-propagating).

declare double @llvm.maximum.f64(double, double)

define i64 @k2w6_maximum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.maximum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
