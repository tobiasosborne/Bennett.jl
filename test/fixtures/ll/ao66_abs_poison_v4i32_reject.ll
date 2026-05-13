; Bennett-ao66 fixture - llvm.abs poison-producing form must fail loud.

declare <4 x i32> @llvm.abs.v4i32(<4 x i32>, i1 immarg)

define i32 @ao66_abs_poison_v4i32(i32 %a) {
entry:
  %v0 = insertelement <4 x i32> poison, i32 %a, i32 0
  %v1 = insertelement <4 x i32> %v0, i32 -1, i32 1
  %v2 = insertelement <4 x i32> %v1, i32 -2, i32 2
  %v3 = insertelement <4 x i32> %v2, i32 -3, i32 3
  %r = call <4 x i32> @llvm.abs.v4i32(<4 x i32> %v3, i1 true)
  %y = extractelement <4 x i32> %r, i32 0
  ret i32 %y
}
