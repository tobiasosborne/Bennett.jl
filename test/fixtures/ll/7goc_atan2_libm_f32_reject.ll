; Bennett-7goc fixture — libm @atan2f rejection per CLAUDE.md §13.

declare float @atan2f(float, float)

define i32 @atan2f_libm(i32 %y, i32 %x) {
entry:
  %fy = bitcast i32 %y to float
  %fx = bitcast i32 %x to float
  %r = call float @atan2f(float %fy, float %fx)
  %z = bitcast float %r to i32
  ret i32 %z
}
