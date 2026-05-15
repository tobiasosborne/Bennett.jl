; Bennett-pg5 fixture - llvm.vector.reduce.add.v2i64: 2-lane sum (smallest non-trivial width).

declare i64 @llvm.vector.reduce.add.v2i64(<2 x i64>)

define i64 @pg5_reduce_add_v2i64(i64 %a, i64 %b) {
entry:
  %v0 = insertelement <2 x i64> poison, i64 %a, i32 0
  %v1 = insertelement <2 x i64> %v0,    i64 %b, i32 1
  %r  = call i64 @llvm.vector.reduce.add.v2i64(<2 x i64> %v1)
  ret i64 %r
}
