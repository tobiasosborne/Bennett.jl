; Bennett-p19b — llvm.minimumnum.f32 rejection per CLAUDE.md §13
; (no native f32 arithmetic primitives; f32 paths are not bit-exact).

declare float @llvm.minimumnum.f32(float, float)

define i32 @p19b_minimumnum_f32(i32 %a, i32 %b) {
entry:
  %fa = bitcast i32 %a to float
  %fb = bitcast i32 %b to float
  %r  = call float @llvm.minimumnum.f32(float %fa, float %fb)
  %z  = bitcast float %r to i32
  ret i32 %z
}
