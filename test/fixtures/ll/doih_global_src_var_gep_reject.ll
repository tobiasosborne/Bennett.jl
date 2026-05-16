; Bennett-doih reject — src is a runtime-indexed GEP of a global.
; _global_root_and_offset returns nothing for variable GEP indices;
; G5 reports a Bennett-doih-vargep breadcrumb.

@gvg = private unnamed_addr constant [16 x i8] c"\11\22\33\44\55\66\77\88\99\AA\BB\CC\DD\EE\FF\00", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_var_gep(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  %xext = sext i8 %x to i32
  %src = getelementptr i8, ptr @gvg, i32 %xext
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 4, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
