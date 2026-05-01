; Bennett-h6f fixture — direct llvm.fmuladd.f64 dispatch.
; Function: fmuladd_f64(i64 a, i64 b, i64 c) -> i64
;
; Per LangRef, llvm.fmuladd may be split into fmul+fadd by the lowerer if
; doing so is cheaper. Bennett.jl chooses to route both fma and fmuladd to
; soft_fma (single-rounding, IEEE 754 binary64 FMA) — the bit-exact answer
; in both cases, at the cost of fmuladd being slower than the fmul+fadd
; split would be. CLAUDE.md §1 (fail loud) and §13 (bit-exact f64) both
; argue for the single-rounding route.

declare double @llvm.fmuladd.f64(double, double, double)

define i64 @fmuladd_f64(i64 %a, i64 %b, i64 %c) {
entry:
  %da = bitcast i64 %a to double
  %db = bitcast i64 %b to double
  %dc = bitcast i64 %c to double
  %r  = call double @llvm.fmuladd.f64(double %da, double %db, double %dc)
  %y  = bitcast double %r to i64
  ret i64 %y
}
