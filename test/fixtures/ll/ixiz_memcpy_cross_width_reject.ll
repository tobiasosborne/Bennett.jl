; Bennett-ixiz fixture (T8) — cross-width memcpy reject.
;
; dst is alloca i64 (ew=64), src is alloca i8 (ew=8). Post-ixiz the
; per-element-width predicate was lifted to accept arbitrary integer
; ew, but a NEW predicate 8b was added: `dst_ew == src_ew` is now
; required. Cross-width memcpy requires implicit pack/unpack lowering
; (out-of-scope; tracked under Bennett-8bys).

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_cross_width(i64 %x) {
entry:
  %src = alloca i8, i32 8, align 1
  %dst = alloca i64, i32 1, align 8
  store i64 %x, ptr %dst, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 1 %src, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
