; Bennett-land reject — non-zero pointer addrspace with non-null pointee.
; `<{ ptr addrspace(1) @target, [8 x i8] c"\01..." }>`. Bennett's
; wire model is single-address-space; non-zero addrspace ptr fields
; reject in `_flatten_struct_to_bytes` before the identity check.
; Tracked in Bennett-land-addrspace follow-up. Use non-null pointee
; and non-zero tail bytes so the global doesn't collapse to a
; ConstantAggregateZero (which would skip the ConstantStruct arm
; entirely).

target datalayout = "e-m:e-p1:64:64-i64:64-f80:128-n8:16:32:64-S128"

@target_as1 = private unnamed_addr addrspace(1) constant [4 x i8] c"\AA\BB\CC\DD", align 1
@gaddrspace = private unnamed_addr constant <{ ptr addrspace(1), [8 x i8] }> <{ ptr addrspace(1) @target_as1, [8 x i8] c"\11\22\33\44\55\66\77\88" }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_struct_addrspace(i8 %x) {
entry:
  %dst = alloca [16 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gaddrspace, i64 16, i1 false)
  ret i8 %x
}
