; Bennett-ky5n fixture — llvm.sinh.f32 rejection per CLAUDE.md §13.

declare float @llvm.sinh.f32(float)

define i32 @sinh_f32(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @llvm.sinh.f32(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
