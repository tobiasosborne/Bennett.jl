; Bennett-3mo fixture — direct llvm.cos.f64 dispatch.
; Function: cos_f64(i64 bits) -> i64 bits

declare double @llvm.cos.f64(double)

define i64 @cos_f64(i64 %x) {
entry:
  %d = bitcast i64 %x to double
  %r = call double @llvm.cos.f64(double %d)
  %y = bitcast double %r to i64
  ret i64 %y
}
