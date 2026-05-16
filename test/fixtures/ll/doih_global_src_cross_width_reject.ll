; Bennett-doih reject — cross-width: src is [N x i8] (ew=8), dst is
; alloca i64 (ew=64). G6 same-width predicate rejects with a
; Bennett-doih-wide breadcrumb.

@gcw = private unnamed_addr constant [8 x i8] c"\11\22\33\44\55\66\77\88", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @doih_cross_width(i64 %x) {
entry:
  %dst = alloca i64, i32 1, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr @gcw, i64 8, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
