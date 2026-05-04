; Bennett-bd7f fixture — llvm.acos.f32 rejection per CLAUDE.md §13.

declare float @llvm.acos.f32(float)

define i32 @acos_f32(i32 %x) {
entry:
  %d = bitcast i32 %x to float
  %r = call float @llvm.acos.f32(float %d)
  %y = bitcast float %r to i32
  ret i32 %y
}
