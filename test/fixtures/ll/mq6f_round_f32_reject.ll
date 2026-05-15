; Bennett-mq6f — llvm.round.f32 rejection per CLAUDE.md §13.

declare float @llvm.round.f32(float)

define i32 @mq6f_round_f32(i32 %a) {
entry:
  %fa = bitcast i32 %a to float
  %r  = call float @llvm.round.f32(float %fa)
  %z  = bitcast float %r to i32
  ret i32 %z
}
