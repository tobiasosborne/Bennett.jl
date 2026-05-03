; Bennett-37mt fixture — N=8 byte memcpy through alloca-i8 buffers.
;
; Phase 1 (Bennett-37mt) of the Bennett-hao epic. The smallest in-scope
; shape: two distinct `alloca i8, i32 N`-shaped buffers, constant byte
; count, isvolatile=false, addrspace 0. Lowering emits N triples of
; IRPtrOffset+IRPtrOffset+IRLoad+IRStore at byte granularity.
;
; Test contract: store %x into src[0], memcpy 8 bytes src→dst, load
; dst[0] — output must equal input.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_n8_i8(i8 %x) {
entry:
  %src = alloca i8, i32 8
  %dst = alloca i8, i32 8
  store i8 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
