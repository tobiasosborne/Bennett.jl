; Bennett-kuza / M2 fixture — cond_pair under `--check-bounds=yes`.
;
; Source:  cp(x::Int8) = [x, -x][1 + Int(x < Int8(0))]
; Dumped:  julia --check-bounds=yes --project -e 'using InteractiveUtils;
;            cp(x::Int8)=[x,-x][1+Int(x<Int8(0))];
;            code_llvm(stdout,cp,Tuple{Int8};debuginfo=:none,optimize=true,
;                      dump_module=true)'  (Julia 1.12.5)
;
; ONE @ijl_gc_small_alloc (N=2 Memory, no Array wrapper); straight-line —
; the index `lshr %x,7` is provably 0/1 so there is no bounds-check diamond.
; The `<tag>` i64 constants are dead GC machinery — any valid i64 works.
;
; M2 partitions SKEL: the gcframe/TLS/alloc/tag/length/self-data-store are
; GC machinery (dropped); the element stores at GEP(Memory,16) / GEP(Memory,17)
; and the runtime load off %memory_data are element traffic (re-rooted onto a
; synthetic IRAlloca [2 x i8]).

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i8 @julia_cp_129(i8 signext %"x::Int8") #0 {
L42:
  %gcframe1 = alloca [3 x ptr], align 16
  call void @llvm.memset.p0.i64(ptr align 16 %gcframe1, i8 0, i64 24, i1 true)
  %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"() #1
  %tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 -8
  %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
  store i64 4, ptr %gcframe1, align 8
  %frame.prev = getelementptr inbounds ptr, ptr %gcframe1, i64 1
  %task.gcstack = load ptr, ptr %tls_pgcstack, align 8
  store ptr %task.gcstack, ptr %frame.prev, align 8
  store ptr %gcframe1, ptr %tls_pgcstack, align 8
  %0 = sub i8 0, %"x::Int8"
  %ptls_field = getelementptr inbounds i8, ptr %tls_pgcstack, i64 16
  %ptls_load = load ptr, ptr %ptls_field, align 8
  %"Memory{Int8}[]" = call noalias nonnull align 8 dereferenceable(32) ptr @ijl_gc_small_alloc(ptr %ptls_load, i32 408, i32 32, i64 136510482798720) #2
  %"Memory{Int8}[].tag_addr" = getelementptr inbounds i64, ptr %"Memory{Int8}[]", i64 -1
  store atomic i64 136510482798720, ptr %"Memory{Int8}[].tag_addr" unordered, align 8
  %memory_ptr = getelementptr inbounds { i64, ptr }, ptr %"Memory{Int8}[]", i64 0, i32 1
  %memory_data = getelementptr inbounds i8, ptr %"Memory{Int8}[]", i64 16
  store ptr %memory_data, ptr %memory_ptr, align 8
  store i64 2, ptr %"Memory{Int8}[]", align 8
  store i8 %"x::Int8", ptr %memory_data, align 1
  %memoryref_data11.1 = getelementptr inbounds i8, ptr %"Memory{Int8}[]", i64 17
  store i8 %0, ptr %memoryref_data11.1, align 1
  %"x::Int8.lobit" = lshr i8 %"x::Int8", 7
  %1 = zext nneg i8 %"x::Int8.lobit" to i64
  %2 = getelementptr i8, ptr %memory_data, i64 %1
  %3 = load i8, ptr %2, align 1
  %frame.prev63 = load ptr, ptr %frame.prev, align 8
  store ptr %frame.prev63, ptr %tls_pgcstack, align 8
  ret i8 %3
}

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg) #3
declare noalias nonnull ptr @ijl_gc_small_alloc(ptr, i32, i32, i64) #4

attributes #0 = { "frame-pointer"="all" "julia.fsig"="cp(Int8)" "probe-stack"="inline-asm" }
attributes #1 = { nounwind }
attributes #2 = { nounwind willreturn allockind("alloc") allocsize(2) memory(argmem: read, inaccessiblemem: readwrite) }
attributes #3 = { nocallback nofree nounwind willreturn memory(argmem: write) }
attributes #4 = { nounwind willreturn allockind("alloc") allocsize(2) memory(argmem: read, inaccessiblemem: readwrite) }
