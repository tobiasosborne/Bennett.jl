; Bennett-eq9p fixture — llvm.acosh.f32 rejection per CLAUDE.md §13.

declare float @llvm.acosh.f32(float)

define i32 @acosh_f32(i32 %x) {
entry:
  %fx = bitcast i32 %x to float
  %r  = call float @llvm.acosh.f32(float %fx)
  %z  = bitcast float %r to i32
  ret i32 %z
}
