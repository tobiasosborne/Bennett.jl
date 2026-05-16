; Bennett-doih reject — src is an external global declaration (no
; initializer). _extract_const_globals doesn't include it (it requires
; `LLVM.isconstant(g)` and an extractable initializer), so G5 reports
; "not extractable" with a Bennett-doih-external breadcrumb.

@gext = external constant [4 x i8]

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_ext_src(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gext, i64 4, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
