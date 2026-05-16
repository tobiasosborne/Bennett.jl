; Bennett-doih fixture — const-GEP src memcpy: copy 4 bytes from
; @gtab+4 (i.e. bytes 4..7) into a fresh alloca.
; Oracle: dst[1] = gtab[5] = 0x66.

@gtab_gep = private unnamed_addr constant [8 x i8] c"\11\22\33\44\55\66\77\88", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_const_gep(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr getelementptr (i8, ptr @gtab_gep, i32 4), i64 4, i1 false)
  %dst1 = getelementptr i8, ptr %dst, i32 1
  %y = load i8, ptr %dst1
  ret i8 %y
}
