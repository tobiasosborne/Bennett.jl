; Bennett-land positive — 3-memcpy carry-through, no load-back-as-data.
; This is the HashMap::new pattern (t5_tr2_hashmap.ll:145-161) reduced
; to a minimum: bytes flow @gstruct → %a → %b → sret-style %_0. No
; load reads the synth bytes as data, so the escape guard stays quiet.
;
; Oracle: load byte 7 from a DIFFERENT alloca (one that never received
; the synth bytes) to assert the circuit ran. Here we just bump an i8
; input and return — the synth-byte alloca's contents are dead.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@target = private unnamed_addr constant [4 x i8] c"\01\02\03\04", align 1
@gct = private unnamed_addr constant <{ ptr, [16 x i8] }> <{ ptr @target, [16 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_carry_through(i8 %x) {
entry:
  %a = alloca [24 x i8], align 8
  %b = alloca [24 x i8], align 8
  %c = alloca [24 x i8], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr %a, ptr @gct, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr %b, ptr %a, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr %c, ptr %b, i64 24, i1 false)
  ; %c carries the synth bytes through; the only "real" computation is
  ; the input bump. No load-from-c.
  %y = add i8 %x, 7
  ret i8 %y
}
