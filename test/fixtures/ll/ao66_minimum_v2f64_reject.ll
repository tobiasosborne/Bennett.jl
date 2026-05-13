; Bennett-ao66 fixture - vector f64 min/max must not use integer compares.

declare <2 x double> @llvm.minimum.v2f64(<2 x double>, <2 x double>)

define i64 @ao66_minimum_v2f64(i64 %a, i64 %b) {
entry:
  %ai0 = insertelement <2 x i64> poison, i64 %a, i32 0
  %ai1 = insertelement <2 x i64> %ai0, i64 %b, i32 1
  %bi0 = insertelement <2 x i64> poison, i64 %b, i32 0
  %bi1 = insertelement <2 x i64> %bi0, i64 %a, i32 1
  %ad = bitcast <2 x i64> %ai1 to <2 x double>
  %bd = bitcast <2 x i64> %bi1 to <2 x double>
  %r = call <2 x double> @llvm.minimum.v2f64(<2 x double> %ad, <2 x double> %bd)
  %e0d = extractelement <2 x double> %r, i32 0
  %e0 = bitcast double %e0d to i64
  ret i64 %e0
}
