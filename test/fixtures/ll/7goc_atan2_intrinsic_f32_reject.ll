; Bennett-7goc fixture — llvm.atan2.f32 rejection per CLAUDE.md §13.

declare float @llvm.atan2.f32(float, float)

define i32 @atan2_f32(i32 %y, i32 %x) {
entry:
  %fy = bitcast i32 %y to float
  %fx = bitcast i32 %x to float
  %r = call float @llvm.atan2.f32(float %fy, float %fx)
  %z = bitcast float %r to i32
  ret i32 %z
}
