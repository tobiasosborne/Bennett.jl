; Bennett-sfx9 fixture — libm-style external @asinh dispatch.

declare double @asinh(double)

define i64 @asinh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @asinh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
