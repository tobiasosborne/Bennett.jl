; Bennett-0ulc fixture — libm @log1p.

declare double @log1p(double)

define i64 @log1p_libm(i64 %x) {
entry:
  %dx = bitcast i64 %x to double
  %r  = call double @log1p(double %dx)
  %z  = bitcast double %r to i64
  ret i64 %z
}
