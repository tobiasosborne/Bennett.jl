; Bennett-37mt fixture — N=24 byte memcpy (matches t5_tr2_hashmap.ll
; line 283 shape). Two `alloca i8, i32 24` buffers; populate src at
; byte 17, memcpy 24 bytes src→dst, load dst[17].
;
; Phase 1 (Bennett-37mt) emits 24 byte-granular IRPtrOffset+IRPtrOffset+
; IRLoad+IRStore quads. Total alloca slots: 24 wires per buffer < 64,
; so the const-idx :shadow strategy applies for every chunk.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_n24_i8(i8 %x) {
entry:
  %src = alloca i8, i32 24
  %dst = alloca i8, i32 24
  %src17 = getelementptr i8, ptr %src, i32 17
  %dst17 = getelementptr i8, ptr %dst, i32 17
  store i8 %x, ptr %src17
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 24, i1 false)
  %y = load i8, ptr %dst17
  ret i8 %y
}
