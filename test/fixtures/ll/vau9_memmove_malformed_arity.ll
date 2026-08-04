; Bennett-vau9 — MALFORMED-IR guard fixture (predicate 2 of the memmove arm).
;
; `llvm.memmove` is declared here with THREE parameters (no `i1 immarg
; isvolatile`), so the call site has 3 args + callee = 4 operands. LLVM's .ll
; parser accepts this (the intrinsic-signature verifier does not run on the
; extraction path — verified empirically 2026-08-04), so without the explicit
; `n_ops >= 5` guard the arm would index `ops[4]` out of bounds instead of
; failing loud with a legible message (CLAUDE.md Rule 1).
;
; Kept in its OWN file: a module cannot declare `@llvm.memmove.p0.p0.i64` at
; two different arities, so this cannot live in `vau9_memmove_var_n.ll`.

declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64)

define void @memmove_arity3(ptr %d, ptr %s, i64 %n) {
entry:
  call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 %n)
  ret void
}
