; Bennett-mq6f — llvm.round.f64 dispatch fixture (round-half-AWAY-from-zero
; per LLVM langref). Pre-mq6f this fell through the no-op
; floor/ceil/trunc/rint/round arm to the callee registry which had
; banker's `soft_round` registered, silently miscompiling every ±N.5 tie.

declare double @llvm.round.f64(double)

define i64 @mq6f_round_f64(i64 %a) {
entry:
  %fa = bitcast i64 %a to double
  %r  = call double @llvm.round.f64(double %fa)
  %z  = bitcast double %r to i64
  ret i64 %z
}
