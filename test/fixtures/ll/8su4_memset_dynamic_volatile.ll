; Bennett-8su4 research fixture — malformed isvolatile arg.
; The 4th memset operand (isvolatile) is a non-constant SSA value (%vol,
; a function parameter). This is malformed IR: LangRef fixes that
; parameter as an `i1 immarg`. The `declare` here deliberately omits the
; `immarg` attribute so LLVM's text parser accepts the module; predicate
; 3 (the malformed-IR guard, unchanged by Bennett-8su4) must reject it.

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1)

define i8 @memset_dynvol(i8 %x, i1 %vol) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 8, i1 %vol)
  %y = load i8, ptr %dst
  ret i8 %y
}
