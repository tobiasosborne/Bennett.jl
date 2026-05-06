; Bennett-eq9p fixture — libm @acoshf rejection per CLAUDE.md §13.

declare float @acoshf(float)

define i32 @acoshf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @acoshf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
