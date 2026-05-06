; Bennett-0ulc fixture — libm @log1pf rejection per CLAUDE.md §13.

declare float @log1pf(float)

define i32 @log1pf_libm(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @log1pf(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
