; Bennett-emv fixture — direct llvm.pow.f64 dispatch.
; Function: pow_f64(i64 x_bits, i64 y_bits) -> i64 result_bits

declare double @llvm.pow.f64(double, double)

define i64 @pow_f64(i64 %x, i64 %y) {
entry:
  %xd = bitcast i64 %x to double
  %yd = bitcast i64 %y to double
  %r  = call double @llvm.pow.f64(double %xd, double %yd)
  %rb = bitcast double %r to i64
  ret i64 %rb
}
