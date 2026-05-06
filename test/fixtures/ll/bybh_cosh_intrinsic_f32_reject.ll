; Bennett-bybh fixture — llvm.cosh.f32 rejection per CLAUDE.md §13.

declare float @llvm.cosh.f32(float)

define i32 @cosh_f32(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @llvm.cosh.f32(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
