; Bennett-37mt fixture — N=4 byte memcpy through alloca-i8 buffers.
;
; Phase 1 deviates from the bead's "N is a multiple of 8 bytes" wording:
; with byte-granular chunks the constraint is moot; any positive N works.
; This fixture demonstrates N=4 (smaller than 8) compiles end-to-end.
;
; Test contract: store %x into src[3] (last byte), memcpy 4 bytes src→dst,
; load dst[3] — output must equal input.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_n4_i8(i8 %x) {
entry:
  %src = alloca i8, i32 4
  %dst = alloca i8, i32 4
  %src3 = getelementptr i8, ptr %src, i32 3
  %dst3 = getelementptr i8, ptr %dst, i32 3
  store i8 %x, ptr %src3
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 4, i1 false)
  %y = load i8, ptr %dst3
  ret i8 %y
}
