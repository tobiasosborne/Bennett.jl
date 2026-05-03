; Bennett-9nwt reject — volatile memset. Reversibility cannot honor
; volatile semantics; reject deferred to Bennett-8bys.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i8 @memset_volatile(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 -1, i64 8, i1 true)
  %y = load i8, ptr %dst
  ret i8 %y
}
