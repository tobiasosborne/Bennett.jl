; Bennett-9nwt reject — memset(c≠0) on a function-parameter ptr (not
; alloca-backed). Phase 2 only handles alloca-i8-backed dst. Note: c=0
; on non-alloca dst is intentionally NOT rejected (preserves pre-9nwt
; broad tolerance for Julia frontend); this fixture uses c=0xAA to
; exercise the alloca-rooted predicate.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_param_dst(ptr %p) {
entry:
  call void @llvm.memset.p0.i64(ptr %p, i8 -86, i64 4, i1 false)
  %y = load i8, ptr %p
  ret i8 %y
}
