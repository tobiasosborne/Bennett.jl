; Bennett-9nwt fixture — case C: memset(c=0x55, N=4) on fresh alloca-i8.
; Mixed-bit pattern (0b01010101) exercises resolve!(::ConstOperand, 8)
; NOT-gate placement at positions 1,3,5,7. Oracle: load dst[2] returns 0x55.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_c55_n4(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memset.p0.i64(ptr %dst, i8 85, i64 4, i1 false)
  %dst2 = getelementptr i8, ptr %dst, i32 2
  %y = load i8, ptr %dst2
  ret i8 %y
}
