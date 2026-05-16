; Bennett-land reject — load i64 from synth-ptr alloca then use as data.
; Memcpy a struct-with-ptr-field global into an alloca, then load the
; first 8 bytes as i64, then RETURN the loaded value. The return is a
; non-memcpy use → escape guard `Bennett-land-ptrload` fires.
;
; This is the load-bearing safety net per CLAUDE.md §1 — without it,
; the loaded value would be the synthetic 0x1000_0000_0000_0000 not the
; real allocator address of @target, silently miscompiling any code
; that compared, dereferenced, or hashed the loaded ptr.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@target = private unnamed_addr constant [4 x i8] c"\01\02\03\04", align 1
@gptrescape = private unnamed_addr constant <{ ptr, [8 x i8] }> <{ ptr @target, [8 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i64 @land_ptrload_escape(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gptrescape, i64 16, i1 false)
  ; Load 8 bytes back from the alloca — these are the synth-address bytes.
  ; Using them as an i64 return value triggers the escape guard.
  %y = load i64, ptr %dst, align 8
  ret i64 %y
}
