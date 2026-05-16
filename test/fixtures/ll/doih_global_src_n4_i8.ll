; Bennett-doih fixture — minimal global-src memcpy: [4 x i8] constant
; copied into a fresh alloca, return byte index 2.
;
; Oracle: ignores %x (input); returns 0x33 = 51 as i8 (signed).
; The %x is required because reversible_compile expects at least one
; input wire; the function pipes it through but never reads it.

@gtab = private unnamed_addr constant [4 x i8] c"\11\22\33\44", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_n4_i8(i8 %x) {
entry:
  %dst = alloca i8, i32 4
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gtab, i64 4, i1 false)
  %dst2 = getelementptr i8, ptr %dst, i32 2
  %y = load i8, ptr %dst2
  ret i8 %y
}
