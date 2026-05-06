; Bennett-m2bv fixture — libm-style external @tanh dispatch.
; What clang/rustc emit when the math intrinsic is disabled or LLVM <18.
; Function: tanh_libm(i64 xbits) -> i64 bits

declare double @tanh(double)

define i64 @tanh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @tanh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
