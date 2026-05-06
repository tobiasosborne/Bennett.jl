; Bennett-o7cy fixture — libm @expm1.

declare double @expm1(double)

define i64 @expm1_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @expm1(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
