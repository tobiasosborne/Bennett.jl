; Bennett-kh6n fixture — scalar llvm.minnum.f64 (IEEE 754 minNum)
; rejection. Same root cause as llvm.minimum.f64: integer compare on
; bit patterns mishandles +0/-0 and NaN propagation.

declare double @llvm.minnum.f64(double, double)

define i64 @kh6n_minnum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.minnum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
