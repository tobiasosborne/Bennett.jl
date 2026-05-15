; Bennett-lx5h: llvm.vector.reduce.fmul.v4f64.
; LLVM langref: returns `start * vec[0] * vec[1] * vec[2] * vec[3]` (strict
; left-to-right when no `reassoc` flag is set). First arg = scalar start.

declare double @llvm.vector.reduce.fmul.v4f64(double, <4 x double>)

define i64 @lx5h_reduce_fmul_v4f64(i64 %s, i64 %a, i64 %b, i64 %c, i64 %d) {
entry:
  %fs = bitcast i64 %s to double
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %fc = bitcast i64 %c to double
  %fd = bitcast i64 %d to double
  %v0 = insertelement <4 x double> poison, double %fa, i32 0
  %v1 = insertelement <4 x double> %v0,    double %fb, i32 1
  %v2 = insertelement <4 x double> %v1,    double %fc, i32 2
  %v3 = insertelement <4 x double> %v2,    double %fd, i32 3
  %r  = call double @llvm.vector.reduce.fmul.v4f64(double %fs, <4 x double> %v3)
  %z  = bitcast double %r to i64
  ret i64 %z
}
