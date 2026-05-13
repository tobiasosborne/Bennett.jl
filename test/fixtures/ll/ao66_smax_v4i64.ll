; Bennett-ao66 fixture - vector llvm.smax.v4i64 scalarisation.

declare <4 x i64> @llvm.smax.v4i64(<4 x i64>, <4 x i64>)

define i64 @ao66_smax_v4i64(i64 %a, i64 %b) {
entry:
  %v0 = insertelement <4 x i64> poison, i64 %a, i32 0
  %v1 = insertelement <4 x i64> %v0, i64 %b, i32 1
  %v2 = insertelement <4 x i64> %v1, i64 -5, i32 2
  %v3 = insertelement <4 x i64> %v2, i64 7, i32 3
  %z0 = insertelement <4 x i64> poison, i64 0, i32 0
  %z1 = insertelement <4 x i64> %z0, i64 0, i32 1
  %z2 = insertelement <4 x i64> %z1, i64 0, i32 2
  %z3 = insertelement <4 x i64> %z2, i64 0, i32 3
  %r = call <4 x i64> @llvm.smax.v4i64(<4 x i64> %v3, <4 x i64> %z3)
  %e0 = extractelement <4 x i64> %r, i32 0
  %e1 = extractelement <4 x i64> %r, i32 1
  %e2 = extractelement <4 x i64> %r, i32 2
  %e3 = extractelement <4 x i64> %r, i32 3
  %m0 = mul i64 %e0, 131
  %a1 = add i64 %m0, %e1
  %m1 = mul i64 %a1, 131
  %a2 = add i64 %m1, %e2
  %m2 = mul i64 %a2, 131
  %a3 = add i64 %m2, %e3
  ret i64 %a3
}
