; Bennett-eq9p fixture — libm @acosh.

declare double @acosh(double)

define i64 @acosh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @acosh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
