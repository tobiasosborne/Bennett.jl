; Bennett-sfx9 fixture — libm @asinhf rejection per CLAUDE.md §13.

declare float @asinhf(float)

define i32 @asinhf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @asinhf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
