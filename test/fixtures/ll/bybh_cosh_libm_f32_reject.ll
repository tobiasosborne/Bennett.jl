; Bennett-bybh fixture — libm @coshf rejection per CLAUDE.md §13.

declare float @coshf(float)

define i32 @coshf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @coshf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
