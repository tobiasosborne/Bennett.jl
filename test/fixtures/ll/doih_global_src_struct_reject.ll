; Bennett-doih reject — src is a ConstantStruct global, not a
; ConstantDataArray. _extract_const_globals silently skips it
; (module_walk.jl filters at `init isa LLVM.ConstantDataArray`),
; so G5 in _handle_memcpy_global_src reports "not extractable" with
; a precise Bennett-doih-struct breadcrumb.
;
; This mirrors the t5_tr2_hashmap.ll:153 shape (packed struct of
; {ptr, [24 x i8]}).

@gstruct = private unnamed_addr constant <{ i8, [3 x i8] }> <{ i8 1, [3 x i8] c"\02\03\04" }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_struct_src(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gstruct, i64 4, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
