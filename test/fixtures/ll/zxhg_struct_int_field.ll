; Bennett-zxhg positive — pure-integer ConstantStruct
; `<{ i8, [3 x i8] }>` with bytes [0x10, 0x11, 0x12, 0x13]. memcpy 4
; bytes to alloca [4 x i8], load dst[2] should be 0x12.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gstruct = private unnamed_addr constant <{ i8, [3 x i8] }> <{ i8 16, [3 x i8] c"\11\12\13" }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_int_field(i8 %x) {
entry:
  %dst = alloca [4 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gstruct, i64 4, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 2
  %y = load i8, ptr %p
  ret i8 %y
}
