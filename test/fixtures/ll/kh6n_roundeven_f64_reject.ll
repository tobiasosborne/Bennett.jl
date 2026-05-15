; Bennett-kh6n fixture — llvm.roundeven.f64 (banker's rounding /
; round-half-to-even, IEEE 754 roundToIntegralTiesToEven) must NOT be
; silently swallowed by the llvm.round prefix arm. The current callee
; registry only has soft_round (round-half-AWAY-from-zero), so silent
; dispatch produces the wrong answer at .5 / 1.5 / 2.5 / ...

declare double @llvm.roundeven.f64(double)

define i64 @kh6n_roundeven_f64(i64 %a) {
entry:
  %fa = bitcast i64 %a to double
  %r  = call double @llvm.roundeven.f64(double %fa)
  %z  = bitcast double %r to i64
  ret i64 %z
}
