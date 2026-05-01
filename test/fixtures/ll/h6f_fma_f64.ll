; Bennett-h6f fixture — direct llvm.fma.f64 dispatch.
; Function: fma_f64(i64 a, i64 b, i64 c) -> i64    where each is f64-bit-pattern

declare double @llvm.fma.f64(double, double, double)

define i64 @fma_f64(i64 %a, i64 %b, i64 %c) {
entry:
  %da = bitcast i64 %a to double
  %db = bitcast i64 %b to double
  %dc = bitcast i64 %c to double
  %r  = call double @llvm.fma.f64(double %da, double %db, double %dc)
  %y  = bitcast double %r to i64
  ret i64 %y
}
