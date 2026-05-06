; Bennett-g82n fixture — libm @atanh.

declare double @atanh(double)

define i64 @atanh_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @atanh(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
