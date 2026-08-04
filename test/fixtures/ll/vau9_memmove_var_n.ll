; Bennett-vau9 / CW-D (ADR 0017 CW-D workstream) — memmove routing fixtures.
;
; Under the closed-world `ptr_cells` gate an `llvm.memmove.p0.p0.i64(dst, src,
; nbytes, i1 false)` routes to
;   IRCall(dest, :memmove, [dst_cell, src_cell, nbytes], [64,64,64], 64)
; → BennettVM's overlap-safe `IntrinsicMemmove` (`:memmove` ∈ `_HEAP_DISPATCH`;
; its `forward` snapshots the src range BEFORE writing dest, and its L2
; dest-range delta reverses it). This is the memmove sibling of the ratified
; Bennett-8bys variable-size-memset D5b void-call routing.
;
; Unlike memset there is NO legacy const-N unroll to preserve: memmove has
; ALWAYS failed loud, so the WHOLE arm is gated on ptr_cells and const-N routes
; through the same IRCall. Under `ptr_cells=false` the legacy reject stands
; byte-identically (the circuit / :heap models have no IntrinsicMemmove).

declare void @llvm.memmove.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)
declare void @llvm.memmove.p1.p0.i64(ptr addrspace(1) nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

; ---------------------------------------------------------------------------
; (a) VARIABLE-size, non-volatile — the `_growend!` grow-copy shape: both
;     pointers are runtime SSA cells, the count is a runtime SSA value.
; ---------------------------------------------------------------------------
define void @memmove_var_n(ptr %d, ptr %s, i64 %n) {
entry:
  call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 false)
  ret void
}

; ---------------------------------------------------------------------------
; (b) CONST-size — routes through the SAME IRCall (no unroll; there is no
;     legacy const-N memmove behaviour to preserve).
; ---------------------------------------------------------------------------
define void @memmove_const_n(ptr %d, ptr %s) {
entry:
  call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 16, i1 false)
  ret void
}

; ---------------------------------------------------------------------------
; (d) VOLATILE — must STILL fail loud under ptr_cells (Rule 1: no observable
;     side-effect ordering in the reversible model).
; ---------------------------------------------------------------------------
define void @memmove_var_n_volatile(ptr %d, ptr %s, i64 %n) {
entry:
  call void @llvm.memmove.p0.p0.i64(ptr %d, ptr %s, i64 %n, i1 true)
  ret void
}

; ---------------------------------------------------------------------------
; (e) NON-p0 address space on the dst pointer — predicate 1 reject (mirrors
;     the memcpy `llvm.memcpy.p0.p0.` prefix check). Bennett's wire/cell model
;     is single-address-space.
; ---------------------------------------------------------------------------
define void @memmove_p1_dst(ptr addrspace(1) %d, ptr %s, i64 %n) {
entry:
  call void @llvm.memmove.p1.p0.i64(ptr addrspace(1) %d, ptr %s, i64 %n, i1 false)
  ret void
}
