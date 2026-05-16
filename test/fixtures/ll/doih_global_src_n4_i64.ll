; Bennett-doih fixture — wider-element global-src memcpy: [4 x i64]
; constant copied into alloca i64, x4. Exercises the G6 same-width path
; with ew=64 and verifies ixiz integration (post-ixiz the non-global
; path accepts arbitrary equal widths; doih inherits the same invariant).
;
; Oracle: returns gtab_i64[1] = 0x1122334455667788.

@gtab_i64 = private unnamed_addr constant [4 x i64] [
  i64 1, i64 1234605616436508552, i64 -1, i64 9223372036854775807
], align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @doih_n4_i64(i64 %x) {
entry:
  %dst = alloca i64, i32 4, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 @gtab_i64, i64 32, i1 false)
  %dst1 = getelementptr i64, ptr %dst, i32 1
  %y = load i64, ptr %dst1, align 8
  ret i64 %y
}
