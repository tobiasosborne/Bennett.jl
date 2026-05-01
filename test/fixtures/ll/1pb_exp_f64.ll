; Bennett-1pb fixture — direct llvm.exp.f64 dispatch.
; Function: exp_f64(i64 bits) -> i64 bits   (round-trip via double)

declare double @llvm.exp.f64(double)

define i64 @exp_f64(i64 %x) {
entry:
  %d = bitcast i64 %x to double
  %r = call double @llvm.exp.f64(double %d)
  %y = bitcast double %r to i64
  ret i64 %y
}
