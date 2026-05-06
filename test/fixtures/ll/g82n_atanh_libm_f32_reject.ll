; Bennett-g82n fixture — libm @atanhf rejection per CLAUDE.md §13.

declare float @atanhf(float)

define i32 @atanhf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @atanhf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
