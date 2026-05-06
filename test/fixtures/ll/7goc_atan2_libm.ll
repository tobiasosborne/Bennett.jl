; Bennett-7goc fixture — libm-style external @atan2 dispatch.
; What clang/rustc emit when the math intrinsic is disabled or LLVM <18.
; Function: atan2_libm(i64 ybits, i64 xbits) -> i64 bits

declare double @atan2(double, double)

define i64 @atan2_libm(i64 %y, i64 %x) {
entry:
  %dy = bitcast i64 %y to double
  %dx = bitcast i64 %x to double
  %r = call double @atan2(double %dy, double %dx)
  %z = bitcast double %r to i64
  ret i64 %z
}
