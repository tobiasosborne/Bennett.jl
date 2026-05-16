; Bennett-doih reject — dst alloca has a prior store before the memcpy
; (non-fresh dst). G9 reuses _alloca_is_fresh from Bennett-9nwt and
; reports the non-fresh hazard with a Bennett-8bys-uncompute breadcrumb.

@gnf = private unnamed_addr constant [4 x i8] c"\11\22\33\44", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_non_fresh(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  store i8 %x, ptr %dst
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gnf, i64 4, i1 false)
  %dst1 = getelementptr i8, ptr %dst, i32 1
  %y = load i8, ptr %dst1
  ret i8 %y
}
