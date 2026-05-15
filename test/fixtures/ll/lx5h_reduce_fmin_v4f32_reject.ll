; Bennett-lx5h reject fixture: f32 fmin reduction (out of scope per §13).

declare float @llvm.vector.reduce.fmin.v4f32(<4 x float>)

define float @lx5h_reduce_fmin_v4f32(float %a, float %b, float %c, float %d) {
entry:
  %v0 = insertelement <4 x float> poison, float %a, i32 0
  %v1 = insertelement <4 x float> %v0,    float %b, i32 1
  %v2 = insertelement <4 x float> %v1,    float %c, i32 2
  %v3 = insertelement <4 x float> %v2,    float %d, i32 3
  %r  = call float @llvm.vector.reduce.fmin.v4f32(<4 x float> %v3)
  ret float %r
}
