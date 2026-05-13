; Bennett-ao66 fixture - known vector intrinsic with no Bennett scalar handler.

declare <4 x i64> @llvm.expect.v4i64(<4 x i64>, <4 x i64>)

define i64 @ao66_expect_v4i64(i64 %a) {
entry:
  %v0 = insertelement <4 x i64> poison, i64 %a, i32 0
  %v1 = insertelement <4 x i64> %v0, i64 1, i32 1
  %v2 = insertelement <4 x i64> %v1, i64 2, i32 2
  %v3 = insertelement <4 x i64> %v2, i64 3, i32 3
  %e0 = insertelement <4 x i64> poison, i64 0, i32 0
  %e1 = insertelement <4 x i64> %e0, i64 1, i32 1
  %e2 = insertelement <4 x i64> %e1, i64 2, i32 2
  %e3 = insertelement <4 x i64> %e2, i64 3, i32 3
  %r = call <4 x i64> @llvm.expect.v4i64(<4 x i64> %v3, <4 x i64> %e3)
  %y = extractelement <4 x i64> %r, i32 0
  ret i64 %y
}
