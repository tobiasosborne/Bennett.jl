; Bennett-sfx9 fixture — direct llvm.asinh.f64 dispatch (LLVM 18+).
; Function: asinh_intr(i64 xbits) -> i64 bits

declare double @llvm.asinh.f64(double)

define i64 @asinh_intr(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @llvm.asinh.f64(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
