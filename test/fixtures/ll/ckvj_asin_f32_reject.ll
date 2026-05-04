; Bennett-ckvj fixture — llvm.asin.f32 rejection per CLAUDE.md §13.

declare float @llvm.asin.f32(float)

define i32 @asin_f32(i32 %x) {
entry:
  %d = bitcast i32 %x to float
  %r = call float @llvm.asin.f32(float %d)
  %y = bitcast float %r to i32
  ret i32 %y
}
