; Bennett-munq fixture — `[8 x i8]` ArrayType alloca + memcpy.
;
; This is the canonical Rust frontend shape (matches t5_tr2_hashmap.ll
; line 158 etc.). Pre-Bennett-munq, the alloca was silently dropped by
; `instructions.jl:1501` (`elem_ty isa LLVM.IntegerType || return
; nothing`), making downstream Phase 1 memcpy lowering useless on the
; t5 corpus. Post-munq, `[N x i8]` lands as `IRAlloca(elem_w=8,
; n_elems=N)` and Phase 1's byte-granular memcpy lowering applies.

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @arr_i8_n8(i8 %x) {
entry:
  %src = alloca [8 x i8], align 8
  %dst = alloca [8 x i8], align 8
  store i8 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
