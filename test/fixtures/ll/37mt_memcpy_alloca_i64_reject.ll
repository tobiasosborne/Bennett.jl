; Bennett-37mt reject — alloca elem_w=64 (alloca i64) is not yet
; supported. Phase 1 byte-granular chunk lowering requires the
; alloca's elem_w to be 8. Wider-element allocas fail loud with a
; reference to Bennett-8bys.
;
; This fixture replaces the lqif_memcpy_reject.ll shape: that fixture
; ALSO uses `alloca i64`, but pre-37mt the rejection reason was
; "memcpy is not yet lowered" (Phase 0). Post-37mt, memcpy IS lowered
; — just not for elem_w=64 allocas. The rejection routes through the
; predicate-cascade arm of the new handler.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @memcpy_alloca_i64(i64 %x) {
entry:
  %src = alloca i64, align 8
  %dst = alloca i64, align 8
  store i64 %x, ptr %src, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
