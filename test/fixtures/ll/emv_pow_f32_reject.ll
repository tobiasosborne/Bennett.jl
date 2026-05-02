; Bennett-emv fixture — llvm.pow.f32 must be rejected (CLAUDE.md §13).

declare float @llvm.pow.f32(float, float)

define i32 @pow_f32(i32 %x, i32 %y) {
entry:
  %xf = bitcast i32 %x to float
  %yf = bitcast i32 %y to float
  %r  = call float @llvm.pow.f32(float %xf, float %yf)
  %rb = bitcast float %r to i32
  ret i32 %rb
}
