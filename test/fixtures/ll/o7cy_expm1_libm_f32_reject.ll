; Bennett-o7cy fixture — libm @expm1f rejection per CLAUDE.md §13.

declare float @expm1f(float)

define i32 @expm1f_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @expm1f(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
