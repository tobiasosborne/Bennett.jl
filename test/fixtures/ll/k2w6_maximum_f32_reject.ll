; Bennett-k2w6 — llvm.maximum.f32 rejection per CLAUDE.md §13.

declare float @llvm.maximum.f32(float, float)

define i32 @k2w6_maximum_f32(i32 %a, i32 %b) {
entry:
  %fa = bitcast i32 %a to float
  %fb = bitcast i32 %b to float
  %r  = call float @llvm.maximum.f32(float %fa, float %fb)
  %z  = bitcast float %r to i32
  ret i32 %z
}
