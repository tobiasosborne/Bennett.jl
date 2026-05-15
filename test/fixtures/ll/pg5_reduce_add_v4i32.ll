; Bennett-pg5 fixture - llvm.vector.reduce.add.v4i32: signed/unsigned-agnostic sum.

declare i32 @llvm.vector.reduce.add.v4i32(<4 x i32>)

define i32 @pg5_reduce_add_v4i32(i32 %a, i32 %b, i32 %c, i32 %d) {
entry:
  %v0 = insertelement <4 x i32> poison, i32 %a, i32 0
  %v1 = insertelement <4 x i32> %v0,    i32 %b, i32 1
  %v2 = insertelement <4 x i32> %v1,    i32 %c, i32 2
  %v3 = insertelement <4 x i32> %v2,    i32 %d, i32 3
  %r  = call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %v3)
  ret i32 %r
}
