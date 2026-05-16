; Bennett-zxhg positive — `<{ [8 x i8], [8 x i8] }>` mirrors the t5_tr2
; @anon.7665…1 shape. 16 bytes total. Load offset 9 → 2nd byte of 2nd array.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gtwo = private unnamed_addr constant <{ [8 x i8], [8 x i8] }> <{ [8 x i8] c"\01\02\03\04\05\06\07\08", [8 x i8] c"\11\12\13\14\15\16\17\18" }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_two_i8_arrays(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gtwo, i64 16, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 9
  %y = load i8, ptr %p
  ret i8 %y
}
