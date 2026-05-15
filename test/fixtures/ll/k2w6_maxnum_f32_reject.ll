; Bennett-k2w6 — llvm.maxnum.f32 rejection per CLAUDE.md §13.

declare float @llvm.maxnum.f32(float, float)

define i32 @k2w6_maxnum_f32(i32 %a, i32 %b) {
entry:
  %fa = bitcast i32 %a to float
  %fb = bitcast i32 %b to float
  %r  = call float @llvm.maxnum.f32(float %fa, float %fb)
  %z  = bitcast float %r to i32
  ret i32 %z
}
