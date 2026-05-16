; Bennett-doih reject — DST as global (predicate 5a). Hard-rejected;
; mutating read-only constant data has no reversible semantics.

@gdst = private unnamed_addr constant [4 x i8] c"\00\00\00\00", align 1
@gsrc = private unnamed_addr constant [4 x i8] c"\11\22\33\44", align 1

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i8 @doih_global_dst(i8 %x) {
entry:
  call void @llvm.memcpy.p0.p0.i64(ptr @gdst, ptr @gsrc, i64 4, i1 false)
  ret i8 %x
}
