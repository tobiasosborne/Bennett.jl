; Bennett-m2bv fixture — direct llvm.tanh.f64 dispatch (LLVM 18+).
; Function: tanh_intr(i64 xbits) -> i64 bits   (round-trip via double)

declare double @llvm.tanh.f64(double)

define i64 @tanh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.tanh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
