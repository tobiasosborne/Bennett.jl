; Bennett-ixiz fixture (T3) — alloca-i64 memcpy with N=16 bytes
; (= 2 elements at 8 bytes per element).
;
; Pre-ixiz, this rejected at predicate 8 in _handle_memcpy_arm
; (`dst_ew != 8 || src_ew != 8`). Post-ixiz, predicate 8 was lifted to
; reject only non-integer alloca element types; equal-width alloca
; element widths (here both 64) are accepted and the memcpy expands to
; ceil(N/ew_bytes) = 2 IRLoad(width=64) + 2 IRStore(width=64) chunks.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_alloca_i64_n16(i64 %x) {
entry:
  %src = alloca i64, i32 2, align 8
  %dst = alloca i64, i32 2, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 16, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
