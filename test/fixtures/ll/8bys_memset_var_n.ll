; Bennett-8bys / CW-D fixture — VARIABLE-size memset routed (under ptr_cells)
; to IRCall(:memset,[dst,byte,nbytes]) → BVM's reversible IntrinsicMemset.
;
; The byte count %n is a runtime SSA value (not a ConstantInt), so the const-N
; case-C unroll cannot fire. Under ptr_cells=true this routes to a bare
; IRCall(dest, :memset, [dst_cell, byte, nbytes], [64,8,64], 64). Under
; ptr_cells=false the predicate-5 "non-constant byte count" reject still fires
; byte-identically (the circuit / :heap models get no IntrinsicMemset).
;
; The fill byte is passed RAW via _operand(c_v) — NO mask, NO broadcast (BVM's
; IntrinsicMemset.forward does its own cell-broadcast). _const_int_as_int
; SIGN-EXTENDS the i8:  i8 0 -> 0,  i8 1 -> 1,  i8 -1 (== 0xFF) -> -1.
; A byte of 1 is the unambiguous raw-not-broadcast probe: raw = 1, whereas a
; 64-bit broadcast of 0x01 would be 0x0101010101010101 = 72340172838076673.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

; c = 0 (the real rehash! slots-zeroing shape: fresh Dict.slots Memory).
define void @memset_var_n(ptr %p, i64 %n) {
entry:
  call void @llvm.memset.p0.i64(ptr %p, i8 0, i64 %n, i1 false)
  ret void
}

; c = 1 — unambiguous raw-not-broadcast probe (raw 1 != broadcast 0x0101...).
define void @memset_var_n_c1(ptr %p, i64 %n) {
entry:
  call void @llvm.memset.p0.i64(ptr %p, i8 1, i64 %n, i1 false)
  ret void
}

; c = 0xFF (== i8 -1) — sign-extends to -1 (raw). Kept as the named "255" case
; from the spec; note 0xFF is degenerate (broadcast of 0xFF is also -1).
define void @memset_var_n_cff(ptr %p, i64 %n) {
entry:
  call void @llvm.memset.p0.i64(ptr %p, i8 -1, i64 %n, i1 false)
  ret void
}

; VOLATILE variable-N memset — must STILL fail loud under ptr_cells (Rule 1).
define void @memset_var_n_volatile(ptr %p, i64 %n) {
entry:
  call void @llvm.memset.p0.i64(ptr %p, i8 0, i64 %n, i1 true)
  ret void
}
