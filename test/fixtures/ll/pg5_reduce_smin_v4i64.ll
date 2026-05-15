; Bennett-pg5 fixture - llvm.vector.reduce.smin.v4i64: signed min over lanes.

declare i64 @llvm.vector.reduce.smin.v4i64(<4 x i64>)

define i64 @pg5_reduce_smin_v4i64(i64 %a, i64 %b, i64 %c, i64 %d) {
entry:
  %v0 = insertelement <4 x i64> poison, i64 %a, i32 0
  %v1 = insertelement <4 x i64> %v0,    i64 %b, i32 1
  %v2 = insertelement <4 x i64> %v1,    i64 %c, i32 2
  %v3 = insertelement <4 x i64> %v2,    i64 %d, i32 3
  %r  = call i64 @llvm.vector.reduce.smin.v4i64(<4 x i64> %v3)
  ret i64 %r
}
