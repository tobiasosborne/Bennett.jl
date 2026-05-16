; Bennett-doih fixture — 32-byte global-src memcpy (matches t5 byte count).
; Oracle: returns gtab32[17] = 0x12.

@gtab32 = private unnamed_addr constant [32 x i8] c"\00\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F\10\11\12\13\14\15\16\17\18\19\1A\1B\1C\1D\1E\1F", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_n32_i8(i8 %x) {
entry:
  %dst = alloca i8, i32 32
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gtab32, i64 32, i1 false)
  %dst17 = getelementptr i8, ptr %dst, i32 17
  %y = load i8, ptr %dst17
  ret i8 %y
}
