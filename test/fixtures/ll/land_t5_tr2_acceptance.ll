; Bennett-land T5 acceptance — exact mirror of build/t5_tr2_hashmap.ll:153.
; `<{ ptr, [24 x i8] }>` with non-null ptr + 24 zero bytes (32 total).
; Body is carry-through only — same pattern HashMap::new uses
; (memcpy chain into sret without intermediate load).

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

@alloc_d0776666182ad032bd1011cf266e2f3a = private unnamed_addr constant [16 x i8] c"\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF\FF", align 16
@anon.7665023084100688a96add9323205da2.0 = private unnamed_addr constant <{ ptr, [24 x i8] }> <{ ptr @alloc_d0776666182ad032bd1011cf266e2f3a, [24 x i8] zeroinitializer }>, align 8

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @land_t5_tr2_acceptance(i8 %x) {
start:
  %_3 = alloca [32 x i8], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %_3, ptr align 8 @anon.7665023084100688a96add9323205da2.0, i64 32, i1 false)
  ret i8 %x
}
