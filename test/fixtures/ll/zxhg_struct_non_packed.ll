; Bennett-zxhg positive — non-packed `{ i8, i32 }` (8 bytes with 3 bytes
; of ABI padding between i8 and i32). Verifies `LLVM.offsetof` path
; correctly accounts for padding.
;
; Field layout: i8 at offset 0; 3 bytes padding (zero) at 1-3; i32 at
; offset 4. With i32 = 256 = 0x00000100 little-endian = [0x00, 0x01,
; 0x00, 0x00]. Load offset 5 should yield 0x01.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@gnp = private unnamed_addr constant { i8, i32 } { i8 99, i32 256 }, align 4

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_non_packed(i8 %x) {
entry:
  %dst = alloca [8 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gnp, i64 8, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 5
  %y = load i8, ptr %p
  ret i8 %y
}
