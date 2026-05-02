; Bennett-emv fixture — direct llvm.powi.f64.i32 dispatch.
; Function: powi_f64(i64 x_bits, i32 n) -> i64 result_bits

declare double @llvm.powi.f64.i32(double, i32)

define i64 @powi_f64(i64 %x, i32 %n) {
entry:
  %xd = bitcast i64 %x to double
  %r  = call double @llvm.powi.f64.i32(double %xd, i32 %n)
  %rb = bitcast double %r to i64
  ret i64 %rb
}
