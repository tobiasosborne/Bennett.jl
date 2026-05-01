; Bennett-1pb fixture — f32 transcendentals must fail loud (CLAUDE.md §13).

declare float @llvm.sqrt.f32(float)

define i32 @sqrt_f32(i32 %x) {
entry:
  %d = bitcast i32 %x to float
  %r = call float @llvm.sqrt.f32(float %d)
  %y = bitcast float %r to i32
  ret i32 %y
}
