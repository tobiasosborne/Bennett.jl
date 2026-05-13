; Bennett-ao66 fixture - vector f32 sqrt must still fail loud.

declare <2 x float> @llvm.sqrt.v2f32(<2 x float>)

define i32 @ao66_sqrt_v2f32_lane0(i32 %a, i32 %b) {
entry:
  %vi0 = insertelement <2 x i32> poison, i32 %a, i32 0
  %vi1 = insertelement <2 x i32> %vi0, i32 %b, i32 1
  %vf = bitcast <2 x i32> %vi1 to <2 x float>
  %r = call <2 x float> @llvm.sqrt.v2f32(<2 x float> %vf)
  %ri = bitcast <2 x float> %r to <2 x i32>
  %e0 = extractelement <2 x i32> %ri, i32 0
  ret i32 %e0
}
