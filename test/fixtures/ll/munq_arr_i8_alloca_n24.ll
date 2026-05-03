; Bennett-munq fixture — `[24 x i8]` ArrayType alloca + memcpy.
; Mirrors t5_tr2_hashmap.ll line 283 shape (24-byte memcpy between two
; alloca [24 x i8]).

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @arr_i8_n24(i8 %x) {
entry:
  %src = alloca [24 x i8], align 8
  %dst = alloca [24 x i8], align 8
  %src17 = getelementptr i8, ptr %src, i32 17
  %dst17 = getelementptr i8, ptr %dst, i32 17
  store i8 %x, ptr %src17
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 24, i1 false)
  %y = load i8, ptr %dst17
  ret i8 %y
}
