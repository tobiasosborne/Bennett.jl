; Bennett-o7cy fixture — llvm.expm1.f32 rejection per CLAUDE.md §13.

declare float @llvm.expm1.f32(float)

define i32 @expm1_f32(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @llvm.expm1.f32(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
