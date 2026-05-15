; Bennett-pg5 reject fixture - llvm.vector.reduce.fadd.v4f64.
; Float-lane reductions are out of scope for pg5; should fail loud with a
; pointer at the future-work bead Bennett-lx5h.

declare double @llvm.vector.reduce.fadd.v4f64(double, <4 x double>)

define double @pg5_reduce_fadd_v4f64(double %a, double %b, double %c, double %d) {
entry:
  %v0 = insertelement <4 x double> poison, double %a, i32 0
  %v1 = insertelement <4 x double> %v0,    double %b, i32 1
  %v2 = insertelement <4 x double> %v1,    double %c, i32 2
  %v3 = insertelement <4 x double> %v2,    double %d, i32 3
  %r  = call double @llvm.vector.reduce.fadd.v4f64(double 0.0, <4 x double> %v3)
  ret double %r
}
