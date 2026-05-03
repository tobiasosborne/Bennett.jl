; Bennett-munq reject — nested ArrayType (e.g. `[N x [M x i8]]`) is out
; of scope. Defer to a future ArrayType-extraction follow-up.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @arr_nested(i8 %x) {
entry:
  %src = alloca [2 x [4 x i8]], align 8
  %dst = alloca [2 x [4 x i8]], align 8
  store i8 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
