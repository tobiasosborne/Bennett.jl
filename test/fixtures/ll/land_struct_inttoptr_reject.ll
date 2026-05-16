; Bennett-land reject — inttoptr-of-const ptr field.
; `<{ ptr inttoptr (i64 0xDEADBEEF to ptr), [8 x i8] }>`. The
; `(:addr, K)` arm of `_ptr_identity` could be materialised as K, but
; K is allocator-dependent — downstream code that compares against a
; real ptr would silently miscompile. Bennett-land MVP REJECTS this
; case; tracked in Bennett-land-inttoptr follow-up.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@ginttoptr = private unnamed_addr constant <{ ptr, [8 x i8] }> <{ ptr inttoptr (i64 3735928559 to ptr), [8 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_inttoptr(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @ginttoptr, i64 16, i1 false)
  %p = getelementptr inbounds i8, ptr %dst, i64 7
  %y = load i8, ptr %p
  ret i8 %y
}
