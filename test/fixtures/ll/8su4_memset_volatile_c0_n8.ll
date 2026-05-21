; Bennett-8su4 fixture — volatile memset(c=0, N=8) on fresh alloca-i8.
; Mirrors 9nwt_memset_c0_n8_fresh.ll but with isvolatile=true. Julia's
; heap-allocating frontend emits exactly this shape for GC-frame zero-
; init: `llvm.memset.p0.i64(ptr %gcframe, i8 0, i64 N, i1 true)`.
; A c==0 memset emits zero IRInsts regardless of volatility (case A
; silent drop), so this must NOT be rejected. Oracle: load dst[0]
; returns 0 since the alloca is zero-initialised and memset is a no-op.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_volatile_c0(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 8, i1 true)
  %y = load i8, ptr %dst
  ret i8 %y
}
