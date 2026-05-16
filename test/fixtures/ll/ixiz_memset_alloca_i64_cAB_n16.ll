; Bennett-ixiz fixture (T5) — alloca-i64 memset c=0xAB N=16.
;
; Pre-ixiz, predicate 12 in _handle_memset_arm rejected because
; dst_ew != 8. Post-ixiz, the predicate is lifted to accept equal-width
; integer dst, and the byte fill c=0xAB is broadcast across the
; element width: each ew-bit IRStore receives
; c_broadcast = c · (typemax(UInt64) / 0xff) masked to ew bits
; = 0xABABABABABABABAB for ew=64.
;
; Expands to ceil(N/ew_bytes) = 16/8 = 2 IRPtrOffset + IRStore(width=64,
; val=0xABABABABABABABAB) pairs.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i64 @memset_alloca_i64_cAB_n16(i64 %x) {
entry:
  %dst = alloca i64, i32 2, align 8
  call void @llvm.memset.p0.i64(ptr align 8 %dst, i8 -85, i64 16, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
