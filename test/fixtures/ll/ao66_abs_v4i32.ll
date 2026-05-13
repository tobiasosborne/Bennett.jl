; Bennett-ao66 fixture - vector llvm.abs.v4i32 scalarisation with scalar immarg.

declare <4 x i32> @llvm.abs.v4i32(<4 x i32>, i1 immarg)

define i32 @ao66_abs_v4i32(i32 %a, i32 %b) {
entry:
  %v0 = insertelement <4 x i32> poison, i32 %a, i32 0
  %v1 = insertelement <4 x i32> %v0, i32 %b, i32 1
  %v2 = insertelement <4 x i32> %v1, i32 -7, i32 2
  %v3 = insertelement <4 x i32> %v2, i32 9, i32 3
  %r = call <4 x i32> @llvm.abs.v4i32(<4 x i32> %v3, i1 false)
  %e0 = extractelement <4 x i32> %r, i32 0
  %e1 = extractelement <4 x i32> %r, i32 1
  %e2 = extractelement <4 x i32> %r, i32 2
  %e3 = extractelement <4 x i32> %r, i32 3
  %m0 = mul i32 %e0, 31
  %a1 = add i32 %m0, %e1
  %m1 = mul i32 %a1, 31
  %a2 = add i32 %m1, %e2
  %m2 = mul i32 %a2, 31
  %a3 = add i32 %m2, %e3
  ret i32 %a3
}
