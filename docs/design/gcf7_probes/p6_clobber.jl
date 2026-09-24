# Escape / clobber / self-store shapes between the writer store and the reload.
import Bennett
const HDR = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"
@"jl_global#93" = private unnamed_addr constant ptr inttoptr (i64 140234000 to ptr)
declare noalias ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @esc(ptr)
"""
fx(name, mid; args="ptr %task, ptr %tag, ptr %pp, ptr %other") = HDR * """
define i64 @$(name)($(args)) {
top:
  %g = load ptr, ptr @"jl_global#93", align 8
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %agg0 = insertvalue { ptr, ptr } zeroinitializer, ptr %box, 0
  %agg = insertvalue { ptr, ptr } %agg0, ptr %g, 1
  store { ptr, ptr } %agg, ptr %box, align 8
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 1
$(mid)
  %ld = load ptr, ptr %f1, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %box, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %ld, 1
  %mem = extractvalue { ptr, ptr } %ref, 1
  %env = alloca [2 x i64], align 8
  %d = getelementptr inbounds i64, ptr %env, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %mem, i64 8, i1 false)
  ret i64 0
}
"""
cases = [
  ("base_noclobber", ""),
  ("esc_call", "  call void @esc(ptr %box)"),
  ("store_via_loaded_ptr", "  %q = load ptr, ptr %pp, align 8\n  store ptr %other, ptr %q, align 8"),
  ("store_via_arg", "  store ptr %other, ptr %pp, align 8"),
  ("self_store", "  store ptr %box, ptr %f1, align 8"),
  ("store_other_same_slot_byte_gep", "  %b8 = getelementptr inbounds i8, ptr %box, i32 8\n  store ptr %other, ptr %b8, align 8"),
  ("memcpy_into_box", "  %b8 = getelementptr inbounds i8, ptr %box, i32 8\n  call void @llvm.memcpy.p0.p0.i64(ptr %b8, ptr %pp, i64 8, i1 false)"),
  ("store_i64_same_slot", "  %b8 = getelementptr inbounds i8, ptr %box, i32 8\n  store i64 5, ptr %b8, align 8"),
  ("store_i32_partial", "  %b12 = getelementptr inbounds i8, ptr %box, i32 12\n  store i32 5, ptr %b12, align 4"),
]
for (nm, mid) in cases
    mktempdir() do dir
        p = joinpath(dir, "$nm.ll"); write(p, fx(nm, mid))
        try
            pir = Bennett.extract_parsed_ir_from_ll(p; entry_function=nm, ptr_cells=true)
            srcs = [i for b in pir.blocks for i in b.instructions
                    if i isa Bennett.IRPtrOffset && i.base isa Bennett.SSAOperand &&
                       i.base.name === Symbol("jl_global#93")]
            println(rpad(nm, 34), " ADMITTED  (global-rooted src offsets: ", length(srcs), ")")
        catch e
            e isa InterruptException && rethrow()
            m = sprint(showerror, e)
            tag = occursin("src operand is not alloca-backed", m) ? "37mt src wall" : first(replace(m, '\n'=>' '), 200)
            println(rpad(nm, 34), " REJECTED: ", tag)
        end
    end
end
