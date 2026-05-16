; Bennett-ixiz fixture (T4) — alloca-i64 memset c=0 N=16.
;
; Pre-ixiz: case A short-circuited at c==0 regardless of dst alloca
; width (predicate 8 in _handle_memset_arm). So this fixture would
; already silently emit no stores and the load would return 0.
;
; Post-ixiz: c==0 still short-circuits (pre-9nwt benign-tolerance
; preserved), so the behaviour is unchanged. We include this fixture
; for symmetry with T5 and to document the case-A fast path.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i64 @memset_alloca_i64_c0_n16(i64 %x) {
entry:
  %dst = alloca i64, i32 2, align 8
  call void @llvm.memset.p0.i64(ptr align 8 %dst, i8 0, i64 16, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
