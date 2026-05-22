; ModuleID = 'f_tj1'
source_filename = "f_tj1"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@jl_boxed_int8_cache = external constant [256 x ptr]

@"jl_global#133.jit" = private alias ptr, inttoptr (i64 130857265649872 to ptr)
@"+Core.Array#134.jit" = private alias ptr, inttoptr (i64 130857265839792 to ptr)

; Function Signature: f_tj1(Int8)
define swiftcc i8 @julia_f_tj1_131(ptr nonnull swiftself %pgcstack, i8 signext %"x::Int8") #0 !dbg !4 {
top:
  %gcframe1 = alloca [15 x ptr], align 16
  call void @llvm.memset.p0.i64(ptr align 16 %gcframe1, i8 0, i64 120, i1 true)
  %0 = getelementptr inbounds ptr, ptr %gcframe1, i64 11
  %1 = getelementptr inbounds ptr, ptr %gcframe1, i64 10
  %2 = getelementptr inbounds ptr, ptr %gcframe1, i64 5
  %3 = getelementptr inbounds ptr, ptr %gcframe1, i64 2
  %"new::#_growend!##0#_growend!##1" = alloca [9 x i64], align 8
  %sret_box = alloca [2 x i64], align 8
  %"new::#_growend!##0#_growend!##120" = alloca [9 x i64], align 8
  %sret_box21 = alloca [2 x i64], align 8
  %"new::#_growend!##0#_growend!##144" = alloca [9 x i64], align 8
  %sret_box45 = alloca [2 x i64], align 8
  store i64 52, ptr %gcframe1, align 8, !tbaa !14
  %frame.prev = getelementptr inbounds ptr, ptr %gcframe1, i64 1
  %task.gcstack = load ptr, ptr %pgcstack, align 8
  store ptr %task.gcstack, ptr %frame.prev, align 8, !tbaa !14
  store ptr %gcframe1, ptr %pgcstack, align 8
  call void @llvm.dbg.value(metadata i8 %"x::Int8", metadata !13, metadata !DIExpression()), !dbg !18
  %ptls_field = getelementptr inbounds i8, ptr %pgcstack, i64 16
  %ptls_load = load ptr, ptr %ptls_field, align 8, !tbaa !14
  %4 = getelementptr inbounds i8, ptr %ptls_load, i64 16
  %safepoint = load ptr, ptr %4, align 8, !tbaa !19, !invariant.load !10
  fence syncscope("singlethread") seq_cst
  %5 = load volatile i64, ptr %safepoint, align 8, !dbg !18
  fence syncscope("singlethread") seq_cst
  %memory_data = load ptr, ptr getelementptr inbounds (ptr, ptr @"jl_global#133.jit", i64 1), align 8, !dbg !21, !tbaa !30, !alias.scope !33, !noalias !36, !nonnull !10
  %ptls_load162 = load ptr, ptr %ptls_field, align 8, !dbg !25, !tbaa !14
  %"new::Array" = call noalias nonnull align 8 dereferenceable(32) ptr @ijl_gc_small_alloc(ptr %ptls_load162, i32 408, i32 32, i64 130857265839792) #10, !dbg !25
  %"new::Array.tag_addr" = getelementptr inbounds i64, ptr %"new::Array", i64 -1, !dbg !25
  store atomic i64 130857265839792, ptr %"new::Array.tag_addr" unordered, align 8, !dbg !25, !tbaa !41
  %6 = getelementptr inbounds i8, ptr %"new::Array", i64 8, !dbg !25
  store ptr %memory_data, ptr %"new::Array", align 8, !dbg !25, !tbaa !44, !alias.scope !33, !noalias !36
  store ptr @"jl_global#133.jit", ptr %6, align 8, !dbg !25, !tbaa !44, !alias.scope !33, !noalias !36
  %"new::Array.size_ptr" = getelementptr inbounds i8, ptr %"new::Array", i64 16, !dbg !25
  store i64 0, ptr %"new::Array.size_ptr", align 8, !dbg !25, !tbaa !46, !alias.scope !47, !noalias !48
  %memory_data4 = load ptr, ptr getelementptr inbounds (ptr, ptr @"jl_global#133.jit", i64 1), align 8, !dbg !49, !tbaa !30, !alias.scope !33, !noalias !36, !nonnull !10
  %7 = ptrtoint ptr %memory_data4 to i64, !dbg !49
  %8 = ptrtoint ptr %memory_data to i64, !dbg !49
  %memoryref_offset = sub i64 %8, %7, !dbg !49
  %9 = add i64 %memoryref_offset, 1, !dbg !49
  %.unbox = load i64, ptr @"jl_global#133.jit", align 8, !dbg !56, !tbaa !46, !alias.scope !60, !noalias !61
  %.not = icmp slt i64 %.unbox, %9, !dbg !56
  br i1 %.not, label %L16, label %L18, !dbg !59

L16:                                              ; preds = %top
  %10 = getelementptr inbounds ptr, ptr %gcframe1, i64 6
  %11 = getelementptr inbounds ptr, ptr %gcframe1, i64 9
  %12 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 8, !dbg !62
  store i64 %9, ptr %12, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %13 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 16, !dbg !62
  store i64 %9, ptr %13, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %14 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 24, !dbg !62
  store i64 1, ptr %14, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %15 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 32, !dbg !62
  store i64 0, ptr %15, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %16 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 40, !dbg !62
  store i64 %.unbox, ptr %16, align 8, !dbg !62, !tbaa !46, !alias.scope !60, !noalias !61
  %17 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 56, !dbg !62
  store ptr %memory_data, ptr %17, align 8, !dbg !62
  %18 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##1", i64 64, !dbg !62
  store i64 -1, ptr %18, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  store ptr %"new::Array", ptr %10, align 8, !dbg !62
  %19 = getelementptr inbounds ptr, ptr %gcframe1, i64 7, !dbg !62
  store ptr @"jl_global#133.jit", ptr %19, align 8, !dbg !62
  %20 = getelementptr inbounds ptr, ptr %gcframe1, i64 8, !dbg !62
  store ptr @"jl_global#133.jit", ptr %20, align 8, !dbg !62
  %gc_slot_addr_12 = getelementptr inbounds ptr, ptr %gcframe1, i64 14
  store ptr %"new::Array", ptr %gc_slot_addr_12, align 8
  call swiftcc void @"j_#_growend!##0_135"(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) %sret_box, ptr noalias nocapture noundef nonnull %11, ptr nonnull swiftself %pgcstack, ptr nocapture nonnull readonly %"new::#_growend!##0#_growend!##1", ptr nocapture nonnull readonly %10), !dbg !62
  %memoryref_data.pre = load ptr, ptr %"new::Array", align 8, !dbg !67, !tbaa !44, !alias.scope !33, !noalias !36
  %memoryref_mem.pre = load ptr, ptr %6, align 8, !dbg !67, !tbaa !44, !alias.scope !33, !noalias !36
  %.pre = ptrtoint ptr %memoryref_data.pre to i64, !dbg !49
  br label %L18, !dbg !62

L18:                                              ; preds = %L16, %top
  %.pre-phi = phi i64 [ %.pre, %L16 ], [ %8, %top ], !dbg !49
  %21 = phi ptr [ %memoryref_mem.pre, %L16 ], [ @"jl_global#133.jit", %top ], !dbg !73
  %22 = phi ptr [ %memoryref_data.pre, %L16 ], [ %memory_data, %top ], !dbg !73
  store i64 1, ptr %"new::Array.size_ptr", align 8, !dbg !75, !tbaa !46, !alias.scope !76, !noalias !61
  store i8 %"x::Int8", ptr %22, align 1, !dbg !70, !tbaa !77, !alias.scope !79, !noalias !80
  %23 = add i8 %"x::Int8", 1, !dbg !81
  %memory_data_ptr15 = getelementptr inbounds { i64, ptr }, ptr %21, i64 0, i32 1, !dbg !49
  %memory_data16 = load ptr, ptr %memory_data_ptr15, align 8, !dbg !49, !tbaa !30, !alias.scope !33, !noalias !36, !nonnull !10
  %24 = ptrtoint ptr %memory_data16 to i64, !dbg !49
  %memoryref_offset17 = sub i64 %.pre-phi, %24, !dbg !49
  %25 = add i64 %memoryref_offset17, 2, !dbg !83
  %.unbox19 = load i64, ptr %21, align 8, !dbg !56, !tbaa !46, !alias.scope !60, !noalias !61
  %.not133 = icmp slt i64 %.unbox19, %25, !dbg !56
  br i1 %.not133, label %L42, label %L44, !dbg !59

L42:                                              ; preds = %L18
  %26 = add i64 %memoryref_offset17, 1, !dbg !49
  %27 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 8, !dbg !62
  store i64 %25, ptr %27, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %28 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 16, !dbg !62
  store i64 %26, ptr %28, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %29 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 24, !dbg !62
  store i64 2, ptr %29, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %30 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 32, !dbg !62
  store i64 1, ptr %30, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %31 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 40, !dbg !62
  store i64 %.unbox19, ptr %31, align 8, !dbg !62, !tbaa !46, !alias.scope !60, !noalias !61
  %32 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 56, !dbg !62
  store ptr %22, ptr %32, align 8, !dbg !62
  %33 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##120", i64 64, !dbg !62
  store i64 -1, ptr %33, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  store ptr %"new::Array", ptr %0, align 8, !dbg !62
  %34 = getelementptr inbounds ptr, ptr %gcframe1, i64 12, !dbg !62
  store ptr %21, ptr %34, align 8, !dbg !62
  %35 = getelementptr inbounds ptr, ptr %gcframe1, i64 13, !dbg !62
  store ptr %21, ptr %35, align 8, !dbg !62
  %gc_slot_addr_12157 = getelementptr inbounds ptr, ptr %gcframe1, i64 14
  store ptr %"new::Array", ptr %gc_slot_addr_12157, align 8
  call swiftcc void @"j_#_growend!##0_135"(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) %sret_box21, ptr noalias nocapture noundef nonnull %1, ptr nonnull swiftself %pgcstack, ptr nocapture nonnull readonly %"new::#_growend!##0#_growend!##120", ptr nocapture nonnull readonly %0), !dbg !62
  %memoryref_data27.pre = load ptr, ptr %"new::Array", align 8, !dbg !67, !tbaa !44, !alias.scope !33, !noalias !36
  %memoryref_mem33.pre = load ptr, ptr %6, align 8, !dbg !67, !tbaa !44, !alias.scope !33, !noalias !36
  %.pre151 = ptrtoint ptr %memoryref_data27.pre to i64, !dbg !49
  br label %L44, !dbg !62

L44:                                              ; preds = %L42, %L18
  %.pre-phi152 = phi i64 [ %.pre151, %L42 ], [ %.pre-phi, %L18 ], !dbg !49
  %.pre-phi150 = phi ptr [ %memoryref_mem33.pre, %L42 ], [ %21, %L18 ], !dbg !86
  %36 = phi ptr [ %memoryref_data27.pre, %L42 ], [ %22, %L18 ], !dbg !73
  store i64 2, ptr %"new::Array.size_ptr", align 8, !dbg !75, !tbaa !46, !alias.scope !76, !noalias !61
  %memoryref_data35 = getelementptr i8, ptr %36, i64 1, !dbg !70
  store i8 %23, ptr %memoryref_data35, align 1, !dbg !70, !tbaa !77, !alias.scope !79, !noalias !80
  %memory_data_ptr39 = getelementptr inbounds { i64, ptr }, ptr %.pre-phi150, i64 0, i32 1, !dbg !49
  %memory_data40 = load ptr, ptr %memory_data_ptr39, align 8, !dbg !49, !tbaa !30, !alias.scope !33, !noalias !36, !nonnull !10
  %37 = ptrtoint ptr %memory_data40 to i64, !dbg !49
  %memoryref_offset41 = sub i64 %.pre-phi152, %37, !dbg !49
  %38 = add i64 %memoryref_offset41, 3, !dbg !83
  %.unbox43 = load i64, ptr %.pre-phi150, align 8, !dbg !56, !tbaa !46, !alias.scope !60, !noalias !61
  %.not134 = icmp slt i64 %.unbox43, %38, !dbg !56
  br i1 %.not134, label %L68, label %L181, !dbg !59

L68:                                              ; preds = %L44
  %39 = add i64 %memoryref_offset41, 1, !dbg !49
  %40 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 8, !dbg !62
  store i64 %38, ptr %40, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %41 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 16, !dbg !62
  store i64 %39, ptr %41, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %42 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 24, !dbg !62
  store i64 3, ptr %42, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %43 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 32, !dbg !62
  store i64 2, ptr %43, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  %44 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 40, !dbg !62
  store i64 %.unbox43, ptr %44, align 8, !dbg !62, !tbaa !46, !alias.scope !60, !noalias !61
  %45 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 56, !dbg !62
  store ptr %36, ptr %45, align 8, !dbg !62
  %46 = getelementptr inbounds i8, ptr %"new::#_growend!##0#_growend!##144", i64 64, !dbg !62
  store i64 -1, ptr %46, align 8, !dbg !62, !tbaa !63, !alias.scope !65, !noalias !66
  store ptr %"new::Array", ptr %3, align 8, !dbg !62
  %47 = getelementptr inbounds ptr, ptr %gcframe1, i64 3, !dbg !62
  store ptr %.pre-phi150, ptr %47, align 8, !dbg !62
  %48 = getelementptr inbounds ptr, ptr %gcframe1, i64 4, !dbg !62
  store ptr %.pre-phi150, ptr %48, align 8, !dbg !62
  %gc_slot_addr_12158 = getelementptr inbounds ptr, ptr %gcframe1, i64 14
  store ptr %"new::Array", ptr %gc_slot_addr_12158, align 8
  call swiftcc void @"j_#_growend!##0_135"(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) %sret_box45, ptr noalias nocapture noundef nonnull %2, ptr nonnull swiftself %pgcstack, ptr nocapture nonnull readonly %"new::#_growend!##0#_growend!##144", ptr nocapture nonnull readonly %3), !dbg !62
  %memoryref_data51.pre = load ptr, ptr %"new::Array", align 8, !dbg !67, !tbaa !44, !alias.scope !33, !noalias !36
  %memoryref_data96.phi.trans.insert = getelementptr inbounds i8, ptr %memoryref_data51.pre, i64 1
  %.pre167 = load i8, ptr %memoryref_data96.phi.trans.insert, align 1, !dbg !90, !tbaa !77, !alias.scope !79, !noalias !80
  br label %L181, !dbg !62

L181:                                             ; preds = %L68, %L44
  %49 = phi i8 [ %.pre167, %L68 ], [ %23, %L44 ], !dbg !90
  %.pre-phi154 = phi ptr [ %memoryref_data51.pre, %L68 ], [ %36, %L44 ], !dbg !70
  %50 = add i8 %"x::Int8", 2, !dbg !81
  store i64 3, ptr %"new::Array.size_ptr", align 8, !dbg !75, !tbaa !46, !alias.scope !76, !noalias !61
  %memoryref_data59 = getelementptr i8, ptr %.pre-phi154, i64 5, !dbg !70
  store i8 %50, ptr %memoryref_data59, align 1, !dbg !70, !tbaa !77, !alias.scope !79, !noalias !80
  %51 = load i8, ptr %.pre-phi154, align 1, !dbg !106, !tbaa !77, !alias.scope !79, !noalias !80
  %52 = add i8 %49, %51, !dbg !108
  %53 = add i8 %50, %52, !dbg !110
  %frame.prev166 = load ptr, ptr %frame.prev, align 8, !tbaa !14
  store ptr %frame.prev166, ptr %pgcstack, align 8, !tbaa !14
  ret i8 %53, !dbg !104
}

; Function Attrs: noinline optnone
define nonnull ptr @jfptr_f_tj1_132(ptr %"function::Core.Function", ptr noalias nocapture noundef readonly %"args::Any[]", i32 %"nargs::UInt32") #1 {
top:
  %thread_ptr = call ptr asm "movq %fs:0, $0", "=r"()
  %tls_ppgcstack = getelementptr inbounds i8, ptr %thread_ptr, i64 -8
  %tls_pgcstack = load ptr, ptr %tls_ppgcstack, align 8
  %0 = getelementptr inbounds i8, ptr %"args::Any[]", i32 0
  %1 = load ptr, ptr %0, align 8, !tbaa !19, !invariant.load !10, !alias.scope !112, !noalias !113, !nonnull !10, !dereferenceable !114, !align !114
  %.unbox = load i8, ptr %1, align 1, !tbaa !115, !alias.scope !79, !noalias !80
  %2 = call swiftcc i8 @julia_f_tj1_131(ptr nonnull swiftself %tls_pgcstack, i8 signext %.unbox)
  %3 = zext i8 %2 to i32
  %4 = getelementptr inbounds [256 x ptr], ptr @jl_boxed_int8_cache, i32 0, i32 %3
  %5 = load ptr, ptr %4, align 8, !tbaa !19, !invariant.load !10, !alias.scope !112, !noalias !113, !nonnull !10, !dereferenceable !114, !align !114
  ret ptr %5
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare void @llvm.dbg.value(metadata, metadata, metadata) #2

; Function Attrs: memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @julia.safepoint(ptr) #3

; Function Attrs: mustprogress nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite)
declare noalias nonnull ptr @julia.gc_alloc_obj(ptr, i64, ptr) #4

; Function Signature: (::Base.var"#_growend!##0#_growend!##1"{Array{Int8, 1}, Int64, Int64, Int64, Int64, Int64, Memory{Int8}, GenericMemoryRef{:not_atomic, Int8, Core.AddrSpace{Core}(0x00)}})()
declare swiftcc void @"j_#_growend!##0_135"(ptr noalias nocapture noundef sret({ ptr, ptr }), ptr noalias nocapture noundef, ptr nonnull swiftself, ptr nocapture readonly, ptr nocapture readonly) #5

; Function Attrs: mustprogress nocallback nofree nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg) #6

; Function Attrs: mustprogress nofree norecurse nosync nounwind speculatable willreturn memory(none)
declare noundef nonnull ptr @julia.gc_loaded(ptr nocapture noundef nonnull readnone, ptr noundef nonnull readnone) #7

; Function Signature: mapreduce_impl(typeof(Base.identity), typeof(Base.:(+)), Array{Int8, 1}, Int64, Int64, Int64)
declare swiftcc i8 @j_mapreduce_impl_137(ptr nonnull swiftself, ptr, i64 signext, i64 signext, i64 signext) #8

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(i64 immarg, ptr nocapture) #9

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(i64 immarg, ptr nocapture) #9

; Function Attrs: nounwind willreturn allockind("alloc") allocsize(2) memory(argmem: read, inaccessiblemem: readwrite)
declare noalias nonnull ptr @ijl_gc_small_alloc(ptr, i32, i32, i64) #10

declare noalias nonnull ptr @julia.new_gc_frame(i32)

declare void @julia.push_gc_frame(ptr, i32)

declare ptr @julia.get_gc_frame_slot(ptr, i32)

declare void @julia.pop_gc_frame(ptr)

; Function Attrs: nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite)
declare noalias nonnull ptr @julia.gc_alloc_bytes(ptr, i64, i64) #11

; Function Attrs: memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @ijl_gc_queue_root(ptr) #3

; Function Attrs: nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite)
declare noalias nonnull ptr @ijl_gc_big_alloc(ptr, i64, i64) #11

; Function Attrs: nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite)
declare noalias nonnull ptr @ijl_gc_alloc_typed(ptr, i64, i64) #11

attributes #0 = { "frame-pointer"="all" "julia.fsig"="f_tj1(Int8)" "probe-stack"="inline-asm" }
attributes #1 = { noinline optnone "frame-pointer"="all" "probe-stack"="inline-asm" }
attributes #2 = { mustprogress nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { mustprogress nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite) }
attributes #5 = { "frame-pointer"="all" "julia.fsig"="(::Base.var\22#_growend!##0#_growend!##1\22{Array{Int8, 1}, Int64, Int64, Int64, Int64, Int64, Memory{Int8}, GenericMemoryRef{:not_atomic, Int8, Core.AddrSpace{Core}(0x00)}})()" "probe-stack"="inline-asm" }
attributes #6 = { mustprogress nocallback nofree nounwind willreturn memory(argmem: write) }
attributes #7 = { mustprogress nofree norecurse nosync nounwind speculatable willreturn memory(none) }
attributes #8 = { "frame-pointer"="all" "julia.fsig"="mapreduce_impl(typeof(Base.identity), typeof(Base.:(+)), Array{Int8, 1}, Int64, Int64, Int64)" "probe-stack"="inline-asm" }
attributes #9 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #10 = { nounwind willreturn allockind("alloc") allocsize(2) memory(argmem: read, inaccessiblemem: readwrite) }
attributes #11 = { nounwind willreturn allockind("alloc") allocsize(1) memory(argmem: read, inaccessiblemem: readwrite) }

!llvm.module.flags = !{!0, !1}
!llvm.dbg.cu = !{!2}

!0 = !{i32 2, !"Dwarf Version", i32 4}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_Julia, file: !3, producer: "julia", isOptimized: true, runtimeVersion: 0, emissionKind: NoDebug, nameTableKind: GNU)
!3 = !DIFile(filename: "julia", directory: ".")
!4 = distinct !DISubprogram(name: "f_tj1", linkageName: "julia_f_tj1_131", scope: null, file: !5, line: 3, type: !6, scopeLine: 3, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2, retainedNodes: !11)
!5 = !DIFile(filename: "none", directory: ".")
!6 = !DISubroutineType(types: !7)
!7 = !{!8, !9, !8}
!8 = !DIBasicType(name: "Int8", size: 8, encoding: DW_ATE_unsigned)
!9 = !DICompositeType(tag: DW_TAG_structure_type, name: "#f_tj1", align: 8, elements: !10, runtimeLang: DW_LANG_Julia, identifier: "130857175302864")
!10 = !{}
!11 = !{!12, !13}
!12 = !DILocalVariable(name: "#self#", arg: 1, scope: !4, file: !5, line: 3, type: !9)
!13 = !DILocalVariable(name: "x", arg: 2, scope: !4, file: !5, line: 3, type: !8)
!14 = !{!15, !15, i64 0}
!15 = !{!"jtbaa_gcframe", !16, i64 0}
!16 = !{!"jtbaa", !17, i64 0}
!17 = !{!"jtbaa"}
!18 = !DILocation(line: 3, scope: !4)
!19 = !{!20, !20, i64 0}
!20 = !{!"jtbaa_const", !16, i64 0}
!21 = !DILocation(line: 593, scope: !22, inlinedAt: !25)
!22 = distinct !DISubprogram(name: "memoryref;", linkageName: "memoryref", scope: !23, file: !23, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!23 = !DIFile(filename: "boot.jl", directory: ".")
!24 = !DISubroutineType(types: !10)
!25 = !DILocation(line: 648, scope: !26, inlinedAt: !27)
!26 = distinct !DISubprogram(name: "Array;", linkageName: "Array", scope: !23, file: !23, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!27 = !DILocation(line: 405, scope: !28, inlinedAt: !18)
!28 = distinct !DISubprogram(name: "getindex;", linkageName: "getindex", scope: !29, file: !29, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!29 = !DIFile(filename: "array.jl", directory: ".")
!30 = !{!31, !31, i64 0}
!31 = !{!"jtbaa_memoryptr", !32, i64 0}
!32 = !{!"jtbaa_array", !16, i64 0}
!33 = !{!34}
!34 = !{!"jnoalias_typemd", !35}
!35 = !{!"jnoalias"}
!36 = !{!37, !38, !39, !40}
!37 = !{!"jnoalias_gcframe", !35}
!38 = !{!"jnoalias_stack", !35}
!39 = !{!"jnoalias_data", !35}
!40 = !{!"jnoalias_const", !35}
!41 = !{!42, !42, i64 0}
!42 = !{!"jtbaa_tag", !43, i64 0}
!43 = !{!"jtbaa_data", !16, i64 0}
!44 = !{!45, !45, i64 0}
!45 = !{!"jtbaa_arrayptr", !32, i64 0}
!46 = !{!16, !16, i64 0}
!47 = !{!39, !34}
!48 = !{!37, !38, !40}
!49 = !DILocation(line: 1128, scope: !50, inlinedAt: !51)
!50 = distinct !DISubprogram(name: "_growend!;", linkageName: "_growend!", scope: !29, file: !29, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!51 = !DILocation(line: 1292, scope: !52, inlinedAt: !53)
!52 = distinct !DISubprogram(name: "_push!;", linkageName: "_push!", scope: !29, file: !29, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!53 = !DILocation(line: 1289, scope: !54, inlinedAt: !55)
!54 = distinct !DISubprogram(name: "push!;", linkageName: "push!", scope: !29, file: !29, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!55 = !DILocation(line: 4, scope: !4)
!56 = !DILocation(line: 83, scope: !57, inlinedAt: !59)
!57 = distinct !DISubprogram(name: "<;", linkageName: "<", scope: !58, file: !58, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!58 = !DIFile(filename: "int.jl", directory: ".")
!59 = !DILocation(line: 1130, scope: !50, inlinedAt: !51)
!60 = !{!34, !38}
!61 = !{!37, !39, !40}
!62 = !DILocation(line: 1131, scope: !50, inlinedAt: !51)
!63 = !{!64, !64, i64 0}
!64 = !{!"jtbaa_stack", !16, i64 0}
!65 = !{!38}
!66 = !{!37, !39, !34, !40}
!67 = !DILocation(line: 54, scope: !68, inlinedAt: !70)
!68 = distinct !DISubprogram(name: "getproperty;", linkageName: "getproperty", scope: !69, file: !69, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!69 = !DIFile(filename: "Base_compiler.jl", directory: ".")
!70 = !DILocation(line: 1010, scope: !71, inlinedAt: !72)
!71 = distinct !DISubprogram(name: "__safe_setindex!;", linkageName: "__safe_setindex!", scope: !29, file: !29, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!72 = !DILocation(line: 1293, scope: !52, inlinedAt: !53)
!73 = !DILocation(line: 54, scope: !68, inlinedAt: !74)
!74 = !DILocation(line: 1123, scope: !50, inlinedAt: !51)
!75 = !DILocation(line: 1159, scope: !50, inlinedAt: !51)
!76 = !{!38, !34}
!77 = !{!78, !78, i64 0}
!78 = !{!"jtbaa_arraybuf", !43, i64 0}
!79 = !{!39}
!80 = !{!37, !38, !34, !40}
!81 = !DILocation(line: 87, scope: !82, inlinedAt: !55)
!82 = distinct !DISubprogram(name: "+;", linkageName: "+", scope: !58, file: !58, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!83 = !DILocation(line: 86, scope: !84, inlinedAt: !85)
!84 = distinct !DISubprogram(name: "-;", linkageName: "-", scope: !58, file: !58, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!85 = !DILocation(line: 1129, scope: !50, inlinedAt: !51)
!86 = !DILocation(line: 14, scope: !87, inlinedAt: !89)
!87 = distinct !DISubprogram(name: "length;", linkageName: "length", scope: !88, file: !88, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!88 = !DIFile(filename: "essentials.jl", directory: ".")
!89 = !DILocation(line: 1125, scope: !50, inlinedAt: !51)
!90 = !DILocation(line: 920, scope: !91, inlinedAt: !92)
!91 = distinct !DISubprogram(name: "getindex;", linkageName: "getindex", scope: !88, file: !88, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!92 = !DILocation(line: 428, scope: !93, inlinedAt: !95)
!93 = distinct !DISubprogram(name: "_mapreduce;", linkageName: "_mapreduce", scope: !94, file: !94, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!94 = !DIFile(filename: "reduce.jl", directory: ".")
!95 = !DILocation(line: 334, scope: !96, inlinedAt: !98)
!96 = distinct !DISubprogram(name: "_mapreduce_dim;", linkageName: "_mapreduce_dim", scope: !97, file: !97, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!97 = !DIFile(filename: "reducedim.jl", directory: ".")
!98 = !DILocation(line: 326, scope: !99, inlinedAt: !100)
!99 = distinct !DISubprogram(name: "#mapreduce#728;", linkageName: "#mapreduce#728", scope: !97, file: !97, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!100 = !DILocation(line: 326, scope: !101, inlinedAt: !102)
!101 = distinct !DISubprogram(name: "mapreduce;", linkageName: "mapreduce", scope: !97, file: !97, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!102 = !DILocation(line: 375, scope: !103, inlinedAt: !104)
!103 = distinct !DISubprogram(name: "#reduce#730;", linkageName: "#reduce#730", scope: !97, file: !97, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!104 = !DILocation(line: 375, scope: !105, inlinedAt: !55)
!105 = distinct !DISubprogram(name: "reduce;", linkageName: "reduce", scope: !97, file: !97, type: !24, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !2)
!106 = !DILocation(line: 920, scope: !91, inlinedAt: !107)
!107 = !DILocation(line: 427, scope: !93, inlinedAt: !95)
!108 = !DILocation(line: 87, scope: !82, inlinedAt: !109)
!109 = !DILocation(line: 429, scope: !93, inlinedAt: !95)
!110 = !DILocation(line: 87, scope: !82, inlinedAt: !111)
!111 = !DILocation(line: 432, scope: !93, inlinedAt: !95)
!112 = !{!40}
!113 = !{!37, !38, !39, !34}
!114 = !{i64 1}
!115 = !{!116, !116, i64 0}
!116 = !{!"jtbaa_immut", !117, i64 0}
!117 = !{!"jtbaa_value", !43, i64 0}
