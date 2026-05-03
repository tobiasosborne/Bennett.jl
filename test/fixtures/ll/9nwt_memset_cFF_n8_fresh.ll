; Bennett-9nwt fixture — case C: memset(c=0xFF, N=8) on fresh alloca-i8.
; Emits 8 byte-granular IRPtrOffset+IRStore pairs at width=8 with
; ConstOperand(0xFF). Oracle: load dst[0] returns 0xFF (== Int8(-1)).

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_cFF_n8(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 -1, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
