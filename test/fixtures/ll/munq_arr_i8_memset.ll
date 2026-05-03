; Bennett-munq fixture — `[8 x i8]` ArrayType alloca + memset(c=0xFF).
; Verifies that the ArrayType extraction also unblocks Bennett-9nwt's
; case C lowering on the Rust corpus alloca shape.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @arr_i8_memset(i8 %x) {
entry:
  %dst = alloca [8 x i8], align 8
  call void @llvm.memset.p0.i64(ptr align 8 %dst, i8 -1, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
