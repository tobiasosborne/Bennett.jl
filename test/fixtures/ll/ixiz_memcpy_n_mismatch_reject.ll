; Bennett-ixiz fixture (T9) — memcpy N not a multiple of ew_bytes.
;
; alloca i64 (ew=64, ew_bytes=8), memcpy N=5. Post-ixiz, the new
; predicate 8c requires `rem(N*8, dst_ew) == 0` — equivalently, N must
; be a whole multiple of element-size bytes. Byte-granular tail
; copy (loading a partial element) is out-of-scope for ixiz; tracked
; under Bennett-8bys.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_n_mismatch(i64 %x) {
entry:
  %src = alloca i64, i32 2, align 8
  %dst = alloca i64, i32 2, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 5, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
