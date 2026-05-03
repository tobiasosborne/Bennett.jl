; Bennett-9nwt reject — alloca elem_w=64 (alloca i64) is not yet
; supported. Phase 2 byte-granular IRStore lowering requires the alloca's
; elem_w to be 8. Wider-element allocas fail loud → Bennett-8bys.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i64 @memset_alloca_i64(i64 %x) {
entry:
  %dst = alloca i64, align 8
  call void @llvm.memset.p0.i64(ptr align 8 %dst, i8 -1, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
