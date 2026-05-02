; Bennett-582 fixture — direct llvm.log.f64 dispatch.
; Function: log_f64(i64 bits) -> i64 bits   (round-trip via double)

declare double @llvm.log.f64(double)

define i64 @log_f64(i64 %x) {
entry:
  %d = bitcast i64 %x to double
  %r = call double @llvm.log.f64(double %d)
  %y = bitcast double %r to i64
  ret i64 %y
}
