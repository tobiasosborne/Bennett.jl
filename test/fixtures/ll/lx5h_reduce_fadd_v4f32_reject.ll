; Bennett-lx5h reject fixture: f32 vector reductions are out of scope per
; CLAUDE.md §13 (Float32 native arithmetic is not bit-exact via the
; fpext→f64-op→fptrunc routing per Bennett-3rph). Should fail loud with
; an explicit f64-only message.

declare float @llvm.vector.reduce.fadd.v4f32(float, <4 x float>)

define float @lx5h_reduce_fadd_v4f32(float %s, float %a, float %b, float %c, float %d) {
entry:
  %v0 = insertelement <4 x float> poison, float %a, i32 0
  %v1 = insertelement <4 x float> %v0,    float %b, i32 1
  %v2 = insertelement <4 x float> %v1,    float %c, i32 2
  %v3 = insertelement <4 x float> %v2,    float %d, i32 3
  %r  = call float @llvm.vector.reduce.fadd.v4f32(float %s, <4 x float> %v3)
  ret float %r
}
