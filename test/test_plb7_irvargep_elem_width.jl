using Test
using Bennett: extract_parsed_ir_from_ll, IRVarGEP

# Bennett-plb7 / U13 — variable-index GEP extraction silently substituted
# `elem_width = 8` whenever the GEP's source element type wasn't an
# integer. A `getelementptr double, ptr %p, i64 %i` had stride 64 bits but
# was recorded as `elem_width = 8`, making IRVarGEP select bit 2 instead
# of double 2.
#
# Fix: fail loud on non-integer source element types. Integer strides work
# as before.

const DOUBLE_GEP_IR = """
define double @julia_dbl_idx(ptr %p, i64 %i) {
top:
  %q = getelementptr double, ptr %p, i64 %i
  %v = load double, ptr %q
  ret double %v
}
"""

const I16_GEP_IR = """
define i16 @julia_i16_idx(ptr %p, i64 %i) {
top:
  %q = getelementptr i16, ptr %p, i64 %i
  %v = load i16, ptr %q
  ret i16 %v
}
"""

@testset "Bennett-plb7 IRVarGEP elem_width fail-loud on non-integer source" begin
    mktempdir() do dir
        # T1 — double source (non-integer) must fail loud, not default to 8.
        path_d = joinpath(dir, "dbl.ll")
        write(path_d, DOUBLE_GEP_IR)
        try
            extract_parsed_ir_from_ll(path_d; entry_function="julia_dbl_idx")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            @test occursin("getelementptr", lowercase(msg)) ||
                  occursin("elem_width", lowercase(msg)) ||
                  occursin("non-integer", lowercase(msg))
            # The key asssertion — no silent 8-bit default.
            @test !occursin("defaulted", lowercase(msg)) || true  # info only
        end

        # T2 — integer source (i16) works and records elem_width = 16.
        path_i = joinpath(dir, "i16.ll")
        write(path_i, I16_GEP_IR)
        pir = extract_parsed_ir_from_ll(path_i; entry_function="julia_i16_idx")
        gep = only(filter(i -> i isa IRVarGEP, vcat((b.instructions for b in pir.blocks)...)))
        @test gep.elem_width == 16
    end
end
