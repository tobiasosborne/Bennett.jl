; Bennett-bybh fixture — direct llvm.cosh.f64 dispatch (LLVM 18+).
; Function: cosh_intr(i64 xbits) -> i64 bits

declare double @llvm.cosh.f64(double)

define i64 @cosh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.cosh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
