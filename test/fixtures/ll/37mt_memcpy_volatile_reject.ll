; Bennett-37mt reject — volatile memcpy. The 4th immarg is i1 true.
; Reversibility cannot honor volatile semantics; reject deferred to
; Bennett-8bys.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @memcpy_volatile(i8 %x) {
entry:
  %src = alloca i8, i32 8
  %dst = alloca i8, i32 8
  store i8 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 8, i1 true)
  %y = load i8, ptr %dst
  ret i8 %y
}
