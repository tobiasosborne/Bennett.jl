; Bennett-s1zl fixture — llvm.tan.f32 rejection per CLAUDE.md §13.

declare float @llvm.tan.f32(float)

define i32 @tan_f32(i32 %x) {
entry:
  %d = bitcast i32 %x to float
  %r = call float @llvm.tan.f32(float %d)
  %y = bitcast float %r to i32
  ret i32 %y
}
