; Bennett-doih reject — N exceeds the global's available bytes.
; @gsmall is [4 x i8] (4 bytes), N=8 reads 4 bytes past end.
; G8 reports out-of-bounds.

@gsmall = private unnamed_addr constant [4 x i8] c"\11\22\33\44", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_oversize(i8 %x) {
entry:
  %dst = alloca i8, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr @gsmall, i64 8, i1 false)
  %y = load i8, ptr %dst
  ret i8 %y
}
