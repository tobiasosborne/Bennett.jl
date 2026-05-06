; Bennett-ky5n fixture — libm-style external @sinh dispatch.
; What clang/rustc emit when the math intrinsic is disabled or LLVM <18.
; Function: sinh_libm(i64 xbits) -> i64 bits

declare double @sinh(double)

define i64 @sinh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @sinh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
