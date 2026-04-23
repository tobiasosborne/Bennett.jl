using Test
using Bennett: extract_parsed_ir_from_ll, IRPtrOffset

# Bennett-vz5n / U12 — constant-index GEP extraction stored the raw index
# in `IRPtrOffset.offset_bytes`, but the consumer at `src/lower.jl:1691`
# multiplies the field by 8 to get a bit offset. That only happened to be
# correct when the GEP's source element type was i8 (stride 1 byte).
# For `getelementptr i32, ptr %p, i64 1` the raw index 1 survived as
# `offset_bytes = 1`, lowered as a 1-byte offset instead of the correct
# 4-byte stride. Same for i16 / i64 / double / etc.
#
# Fix: read `LLVMGetGEPSourceElementType`, compute
# `stride_bytes = _type_width(elt_ty) ÷ 8`, store
# `offset_bytes = raw_idx * stride_bytes`.

# Minimal function with constant-index GEPs at various strides. The body
# never actually uses the loaded values; the test inspects the extracted
# IRPtrOffset records directly rather than compiling + simulating.
const STRIDE_IR = """
define i64 @julia_strides(ptr %p8, ptr %p16, ptr %p32, ptr %p64) {
top:
  %q8  = getelementptr i8,  ptr %p8,  i64 3
  %q16 = getelementptr i16, ptr %p16, i64 3
  %q32 = getelementptr i32, ptr %p32, i64 3
  %q64 = getelementptr i64, ptr %p64, i64 3
  ret i64 0
}
"""

@testset "Bennett-vz5n GEP offset_bytes scales with source element type" begin
    mktempdir() do dir
        path = joinpath(dir, "gep.ll")
        write(path, STRIDE_IR)

        pir = extract_parsed_ir_from_ll(path; entry_function="julia_strides")

        offsets = Dict{Symbol,Int}()
        for blk in pir.blocks, inst in blk.instructions
            if inst isa IRPtrOffset
                offsets[inst.dest] = inst.offset_bytes
            end
        end

        # Expected: stride = elt bytes; raw idx = 3.
        @test offsets[:q8]  == 3 * 1
        @test offsets[:q16] == 3 * 2
        @test offsets[:q32] == 3 * 4
        @test offsets[:q64] == 3 * 8
    end
end
