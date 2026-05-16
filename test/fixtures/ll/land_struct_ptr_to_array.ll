; Bennett-land positive — narrowest synthetic-address case.
; `<{ ptr @target, [16 x i8] }>` mirrors the Rust panic-Location ABI
; shape. The function body carries the bytes through memcpy chain only
; (no load of synth bytes) so the escape guard stays quiet.
; The byte-layout oracle is asserted at the EXTRACTION layer
; (inspecting parsed.globals[:gstruct]) not by simulating a load.

target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"

@target = private unnamed_addr constant [4 x i8] c"\01\02\03\04", align 1
@gstruct = private unnamed_addr constant <{ ptr, [16 x i8] }> <{ ptr @target, [16 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_ptr_to_array(i8 %x) {
entry:
  %dst = alloca [24 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gstruct, i64 24, i1 false)
  ret i8 %x
}
