; Bennett-ky5n fixture — direct llvm.sinh.f64 dispatch (LLVM 18+).
; Function: sinh_intr(i64 xbits) -> i64 bits   (round-trip via double)

declare double @llvm.sinh.f64(double)

define i64 @sinh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.sinh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
