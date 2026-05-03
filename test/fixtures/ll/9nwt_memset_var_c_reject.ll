; Bennett-9nwt reject — variable fill byte (c is an SSA value).
; Const-operand fast path can't express a runtime byte; deferred to
; Bennett-8bys-uncompute (variable-data lowering).

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_var_c(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 %x, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
