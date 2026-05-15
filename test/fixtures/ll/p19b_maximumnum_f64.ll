; Bennett-p19b — llvm.maximumnum.f64 native dispatch fixture (LLVM 19+
; IEEE 754-2019 maximumNumber). NaN-absorbing with specified +0.0 > -0.0
; tie-break. Semantically identical to llvm.maxnum.f64 in our impl.

declare double @llvm.maximumnum.f64(double, double)

define i64 @p19b_maximumnum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.maximumnum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
