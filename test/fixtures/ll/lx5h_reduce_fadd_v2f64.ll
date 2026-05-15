; Bennett-lx5h: llvm.vector.reduce.fadd.v2f64.
; Smallest non-trivial width corner — covers single fold step + start arg.

declare double @llvm.vector.reduce.fadd.v2f64(double, <2 x double>)

define i64 @lx5h_reduce_fadd_v2f64(i64 %s, i64 %a, i64 %b) {
entry:
  %fs = bitcast i64 %s to double
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %v0 = insertelement <2 x double> poison, double %fa, i32 0
  %v1 = insertelement <2 x double> %v0,    double %fb, i32 1
  %r  = call double @llvm.vector.reduce.fadd.v2f64(double %fs, <2 x double> %v1)
  %z  = bitcast double %r to i64
  ret i64 %z
}
