; Bennett-kh6n fixture — llvm.maximumnum.f64 (LLVM 19+, IEEE 754-2019
; maximumNumber) must NOT be silently swallowed by the llvm.maximum
; prefix arm.

declare double @llvm.maximumnum.f64(double, double)

define i64 @kh6n_maximumnum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.maximumnum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
