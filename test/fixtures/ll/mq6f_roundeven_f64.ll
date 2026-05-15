; Bennett-mq6f — llvm.roundeven.f64 dispatch fixture (banker's rounding /
; round-half-to-EVEN per LLVM langref). Pre-mq6f the kh6n explicit-reject
; arm raised _ir_error here; mq6f replaces that with native dispatch to
; `soft_round` (which is also banker's, so the reject was based on a
; misstatement — see worklog/066 Bennett-mq6f correction).

declare double @llvm.roundeven.f64(double)

define i64 @mq6f_roundeven_f64(i64 %a) {
entry:
  %fa = bitcast i64 %a to double
  %r  = call double @llvm.roundeven.f64(double %fa)
  %z  = bitcast double %r to i64
  ret i64 %z
}
