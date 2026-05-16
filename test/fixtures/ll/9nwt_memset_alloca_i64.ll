; Bennett-9nwt + Bennett-ixiz fixture — alloca-i64 memset with
; c=0xAB N=16 bytes (= 2 elements at 8 bytes per element).
;
; Pre-ixiz, predicate 12 in `_handle_memset_arm` rejected because
; `dst_ew=64 != 8`. Post-ixiz, predicate 12 was lifted to accept any
; integer dst_ew, and the byte fill c=0xAB is broadcast across each
; element width via `_broadcast_byte_to_width` →
; 0xABABABABABABABAB for ew=64.
;
; LLVM encodes `i8 -85` and `i8 0xab` identically (two's-complement
; UInt8 0xab = signed Int8 -85).
;
; Lowering: 2 IRPtrOffset + 2 IRStore(width=64, val=0xABABABABABABABAB).

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i64 @memset_alloca_i64(i64 %x) {
entry:
  %dst = alloca i64, i32 2, align 8
  call void @llvm.memset.p0.i64(ptr align 8 %dst, i8 -85, i64 16, i1 false)
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
