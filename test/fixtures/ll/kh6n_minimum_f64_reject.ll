; Bennett-kh6n fixture — scalar llvm.minimum.f64 must be rejected:
; the current handler emits IRICmp(:slt) on the f64 bit pattern, which
; mishandles +0.0/-0.0 (treated as unequal) and NaN (signed-int compare
; treats NaN bit patterns as positive infinity-or-larger). Mirrors the
; vector rejection in src/extract/vectors.jl. A native soft_fmin/fmax
; primitive is the correct fix; until then, fail loud.

declare double @llvm.minimum.f64(double, double)

define i64 @kh6n_minimum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.minimum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
