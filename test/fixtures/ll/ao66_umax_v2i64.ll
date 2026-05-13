; Bennett-ao66 fixture - vector llvm.umax.v2i64 scalarisation.

declare <2 x i64> @llvm.umax.v2i64(<2 x i64>, <2 x i64>)

define i64 @ao66_umax_v2i64(i64 %a, i64 %b) {
entry:
  %v0 = insertelement <2 x i64> poison, i64 %a, i32 0
  %v1 = insertelement <2 x i64> %v0, i64 %b, i32 1
  %w0 = insertelement <2 x i64> poison, i64 3, i32 0
  %w1 = insertelement <2 x i64> %w0, i64 5, i32 1
  %r = call <2 x i64> @llvm.umax.v2i64(<2 x i64> %v1, <2 x i64> %w1)
  %e0 = extractelement <2 x i64> %r, i32 0
  %e1 = extractelement <2 x i64> %r, i32 1
  %s1 = shl i64 %e1, 1
  %y = xor i64 %e0, %s1
  ret i64 %y
}
