; Pre-zxhg this was a doih REJECT fixture (filename had `_reject`
; suffix). Post-Bennett-zxhg, `_extract_const_globals` accepts
; pure-integer ConstantStruct initializers like this `<{ i8, [3 x i8] }>`,
; flattening them to a byte stream (elem_width=8). The doih G5 path
; thus succeeds and the memcpy lowers to 4 IRPtrOffset+IRStore(iconst,
; 8) pairs. dst[0] = 1, dst[1] = 2, dst[2] = 3, dst[3] = 4.
;
; The fail-loud branch (still hit by t5_tr2_hashmap.ll:153) is the
; ConstantStruct WITH a non-integer field — covered by
; `Bennett-zxhg-ptrfield` fixtures.

@gstruct = private unnamed_addr constant <{ i8, [3 x i8] }> <{ i8 1, [3 x i8] c"\02\03\04" }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_struct_src(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gstruct, i64 4, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
