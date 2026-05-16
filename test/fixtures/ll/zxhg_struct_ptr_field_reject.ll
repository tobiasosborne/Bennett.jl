; Bennett-zxhg reject — MIRRORS t5_tr2_hashmap.ll:153 shape.
; `<{ ptr, [24 x i8] }>` with a non-null ptr field. Hard-rejects at
; `_flatten_struct_to_bytes` (returning nothing) → silently skipped in
; the globals dict → G5 fires with `Bennett-zxhg-ptrfield`.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@target = private unnamed_addr constant [4 x i8] c"\01\02\03\04", align 1
@gptrstruct = private unnamed_addr constant <{ ptr, [24 x i8] }> <{ ptr @target, [24 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @zxhg_struct_ptr_field(i8 %x) {
entry:
  %dst = alloca [32 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gptrstruct, i64 32, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 16
  %y = load i8, ptr %p
  ret i8 %y
}
