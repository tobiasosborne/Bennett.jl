; Bennett-582 fixture — llvm.log.f32 must be rejected (CLAUDE.md §13,
; Bennett-3rph: f32 native transcendentals not bit-exact).

declare float @llvm.log.f32(float)

define i32 @log_f32(i32 %x) {
entry:
  %f = bitcast i32 %x to float
  %r = call float @llvm.log.f32(float %f)
  %y = bitcast float %r to i32
  ret i32 %y
}
