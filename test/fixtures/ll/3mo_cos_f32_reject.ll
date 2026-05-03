; Bennett-3mo fixture — llvm.cos.f32 rejection per CLAUDE.md §13.

declare float @llvm.cos.f32(float)

define i32 @cos_f32(i32 %x) {
entry:
  %d = bitcast i32 %x to float
  %r = call float @llvm.cos.f32(float %d)
  %y = bitcast float %r to i32
  ret i32 %y
}
