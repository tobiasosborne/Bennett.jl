; Bennett-bybh fixture — libm-style external @cosh dispatch.

declare double @cosh(double)

define i64 @cosh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @cosh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
