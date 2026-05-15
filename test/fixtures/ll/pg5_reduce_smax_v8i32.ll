; Bennett-pg5 fixture - llvm.vector.reduce.smax.v8i32: signed max over 8 lanes
; (second-width coverage for the smax arm).

declare i32 @llvm.vector.reduce.smax.v8i32(<8 x i32>)

define i32 @pg5_reduce_smax_v8i32(i32 %a, i32 %b, i32 %c, i32 %d,
                                  i32 %e, i32 %f, i32 %g, i32 %h) {
entry:
  %v0 = insertelement <8 x i32> poison, i32 %a, i32 0
  %v1 = insertelement <8 x i32> %v0,    i32 %b, i32 1
  %v2 = insertelement <8 x i32> %v1,    i32 %c, i32 2
  %v3 = insertelement <8 x i32> %v2,    i32 %d, i32 3
  %v4 = insertelement <8 x i32> %v3,    i32 %e, i32 4
  %v5 = insertelement <8 x i32> %v4,    i32 %f, i32 5
  %v6 = insertelement <8 x i32> %v5,    i32 %g, i32 6
  %v7 = insertelement <8 x i32> %v6,    i32 %h, i32 7
  %r  = call i32 @llvm.vector.reduce.smax.v8i32(<8 x i32> %v7)
  ret i32 %r
}
