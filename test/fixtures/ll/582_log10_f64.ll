; Bennett-582 fixture — direct llvm.log10.f64 dispatch.
; Function: log10_f64(i64 bits) -> i64 bits   (round-trip via double)

declare double @llvm.log10.f64(double)

define i64 @log10_f64(i64 %x) {
entry:
  %d = bitcast i64 %x to double
  %r = call double @llvm.log10.f64(double %d)
  %y = bitcast double %r to i64
  ret i64 %y
}
