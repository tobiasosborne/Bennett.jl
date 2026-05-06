; Bennett-m2bv fixture — libm @tanhf rejection per CLAUDE.md §13.

declare float @tanhf(float)

define i32 @tanhf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @tanhf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
