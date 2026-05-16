; Bennett-doih fixture — 8-byte global-src memcpy, returns a chosen byte.
; Oracle: returns gtab[byte_index_via_input_mod_8] via runtime GEP.
; Simpler oracle: just return byte 5 (= 0x66 = 102 signed).

@gtab8 = private unnamed_addr constant [8 x i8] c"\11\22\33\44\55\66\77\88", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_n8_i8(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gtab8, i64 8, i1 false)
  %dst5 = getelementptr i8, ptr %dst, i32 5
  %y = load i8, ptr %dst5
  ret i8 %y
}
