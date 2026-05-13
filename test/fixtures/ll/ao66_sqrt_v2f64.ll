; Bennett-ao66 fixture - vector llvm.sqrt.v2f64 scalarisation.
; Arguments and returns are f64 bit patterns.

declare <2 x double> @llvm.sqrt.v2f64(<2 x double>)

define i64 @ao66_sqrt_v2f64_lane0(i64 %a, i64 %b) {
entry:
  %vi0 = insertelement <2 x i64> poison, i64 %a, i32 0
  %vi1 = insertelement <2 x i64> %vi0, i64 %b, i32 1
  %vd = bitcast <2 x i64> %vi1 to <2 x double>
  %r = call <2 x double> @llvm.sqrt.v2f64(<2 x double> %vd)
  %e0d = extractelement <2 x double> %r, i32 0
  %e0 = bitcast double %e0d to i64
  ret i64 %e0
}

define i64 @ao66_sqrt_v2f64_lane1(i64 %a, i64 %b) {
entry:
  %vi0 = insertelement <2 x i64> poison, i64 %a, i32 0
  %vi1 = insertelement <2 x i64> %vi0, i64 %b, i32 1
  %vd = bitcast <2 x i64> %vi1 to <2 x double>
  %r = call <2 x double> @llvm.sqrt.v2f64(<2 x double> %vd)
  %e1d = extractelement <2 x double> %r, i32 1
  %e1 = bitcast double %e1d to i64
  ret i64 %e1
}
