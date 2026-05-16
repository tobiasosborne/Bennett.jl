; Bennett-37mt + Bennett-ixiz fixture — alloca-i64 memcpy with N=16
; bytes (= 2 elements at 8 bytes per element).
;
; Pre-ixiz, this fixture rejected at predicate 8 in
; `_handle_memcpy_arm` because `dst_ew=64 != 8`. The bead's "Wider-
; element allocas need ... a wider shadow-store path" warning
; pointed at this exact shape.
;
; Post-ixiz, predicate 8 was lifted to accept arbitrary integer
; element widths; this fixture now lowers to 2 IRLoad(width=64) +
; 2 IRStore(width=64) chunks plus 4 IRPtrOffset (src+dst per chunk).

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_alloca_i64(i64 %x) {
entry:
  %src = alloca i64, i32 2, align 8
  %dst = alloca i64, i32 2, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 16, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
