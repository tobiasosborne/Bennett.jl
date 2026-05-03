; Bennett-munq reject — `[N x i16]` ArrayType. Wider-element ArrayType
; is out of scope for Phase 3 sub-bead 1 (Bennett-munq); defer to
; Bennett-ixiz (wider-elem alloca support, lifts the ew==8 gate in
; aggregate.jl:227 + memory.jl wider shadow paths).

declare void @llvm.memcpy.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

define i16 @arr_i16(i16 %x) {
entry:
  %src = alloca [4 x i16], align 8
  %dst = alloca [4 x i16], align 8
  store i16 %x, ptr %src
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 8, i1 false)
  %y = load i16, ptr %dst
  ret i16 %y
}
