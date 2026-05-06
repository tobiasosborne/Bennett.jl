; Bennett-7goc fixture — direct llvm.atan2.f64 dispatch (LLVM 18+).
; Function: atan2_intr(i64 ybits, i64 xbits) -> i64 bits   (round-trip via double)

declare double @llvm.atan2.f64(double, double)

define i64 @atan2_intr(i64 %y, i64 %x) {
entry:
  %dy = bitcast i64 %y to double
  %dx = bitcast i64 %x to double
  %r = call double @llvm.atan2.f64(double %dy, double %dx)
  %z = bitcast double %r to i64
  ret i64 %z
}
