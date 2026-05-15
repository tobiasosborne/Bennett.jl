; Bennett-kh6n fixture — llvm.minimumnum.f64 (LLVM 19+, IEEE 754-2019
; minimumNumber) must NOT be silently swallowed by the llvm.minimum
; prefix arm. Without trailing-`.` discipline the scalar handler in
; src/extract/instructions.jl matches `llvm.minimum` and dispatches to
; an integer-compare-on-float-bits emitter, which gives the wrong
; answer for both regular floats (NaN handling differs from minimum)
; and for the minimumNumber-specific quiet-NaN tie-break.

declare double @llvm.minimumnum.f64(double, double)

define i64 @kh6n_minimumnum_f64(i64 %a, i64 %b) {
entry:
  %fa = bitcast i64 %a to double
  %fb = bitcast i64 %b to double
  %r  = call double @llvm.minimumnum.f64(double %fa, double %fb)
  %z  = bitcast double %r to i64
  ret i64 %z
}
