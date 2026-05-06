; Bennett-ky5n fixture — libm @sinhf rejection per CLAUDE.md §13.

declare float @sinhf(float)

define i32 @sinhf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @sinhf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
