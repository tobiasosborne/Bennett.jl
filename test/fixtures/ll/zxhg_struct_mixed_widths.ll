; Bennett-zxhg positive — `<{ i64, i32, [4 x i8] }>` (16 bytes, packed).
; Validates LSB-first byte packing for both i64 (8 bytes) and i32
; (4 bytes), plus the trailing array. Load byte at offset 0 = 0x88 (LSB
; of i64 0x1122334455667788).

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gmix = private unnamed_addr constant <{ i64, i32, [4 x i8] }> <{ i64 1234605616436508552, i32 -16777216, [4 x i8] c"\AA\BB\CC\DD" }>, align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_mixed_widths(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gmix, i64 16, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 0
  %y = load i8, ptr %p
  ret i8 %y
}
