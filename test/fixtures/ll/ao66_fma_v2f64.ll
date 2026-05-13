; Bennett-ao66 fixture - vector llvm.fma.v2f64 scalarisation.
; Arguments and returns are f64 bit patterns.

declare <2 x double> @llvm.fma.v2f64(<2 x double>, <2 x double>, <2 x double>)

define i64 @ao66_fma_v2f64_lane0(i64 %a0, i64 %b0, i64 %c0,
                                 i64 %a1, i64 %b1, i64 %c1) {
entry:
  %av0 = insertelement <2 x i64> poison, i64 %a0, i32 0
  %av1 = insertelement <2 x i64> %av0, i64 %a1, i32 1
  %bv0 = insertelement <2 x i64> poison, i64 %b0, i32 0
  %bv1 = insertelement <2 x i64> %bv0, i64 %b1, i32 1
  %cv0 = insertelement <2 x i64> poison, i64 %c0, i32 0
  %cv1 = insertelement <2 x i64> %cv0, i64 %c1, i32 1
  %ad = bitcast <2 x i64> %av1 to <2 x double>
  %bd = bitcast <2 x i64> %bv1 to <2 x double>
  %cd = bitcast <2 x i64> %cv1 to <2 x double>
  %r = call <2 x double> @llvm.fma.v2f64(<2 x double> %ad, <2 x double> %bd, <2 x double> %cd)
  %e0d = extractelement <2 x double> %r, i32 0
  %e0 = bitcast double %e0d to i64
  ret i64 %e0
}

define i64 @ao66_fma_v2f64_lane1(i64 %a0, i64 %b0, i64 %c0,
                                 i64 %a1, i64 %b1, i64 %c1) {
entry:
  %av0 = insertelement <2 x i64> poison, i64 %a0, i32 0
  %av1 = insertelement <2 x i64> %av0, i64 %a1, i32 1
  %bv0 = insertelement <2 x i64> poison, i64 %b0, i32 0
  %bv1 = insertelement <2 x i64> %bv0, i64 %b1, i32 1
  %cv0 = insertelement <2 x i64> poison, i64 %c0, i32 0
  %cv1 = insertelement <2 x i64> %cv0, i64 %c1, i32 1
  %ad = bitcast <2 x i64> %av1 to <2 x double>
  %bd = bitcast <2 x i64> %bv1 to <2 x double>
  %cd = bitcast <2 x i64> %cv1 to <2 x double>
  %r = call <2 x double> @llvm.fma.v2f64(<2 x double> %ad, <2 x double> %bd, <2 x double> %cd)
  %e1d = extractelement <2 x double> %r, i32 1
  %e1 = bitcast double %e1d to i64
  ret i64 %e1
}
