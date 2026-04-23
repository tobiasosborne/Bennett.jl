using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-qal5 / U16 — multi-index `getelementptr` and GEPs with neither
# a named-SSA base nor a GlobalVariable base were silently dropped at
# `src/ir_extract.jl:1706`. The GEP's dest SSA was left undefined; any
# load or pointer use that referenced it crashed far from the root cause.
# Minimum-viable fix per catalogue: `_ir_error` naming the GEP shape.
# Full type-walking byte-offset accumulation is future work.

# Multi-index GEP into an array — 3 operands (base + 2 indices).
const MULTI_IDX_IR = """
@tbl = private constant [4 x i32] [i32 1, i32 2, i32 3, i32 4]
define i32 @julia_multi_gep(i32 %i) {
top:
  %q = getelementptr [4 x i32], ptr @tbl, i32 0, i32 %i
  %v = load i32, ptr %q
  ret i32 %v
}
"""

@testset "Bennett-qal5 multi-index GEP fail-loud" begin
    mktempdir() do dir
        path = joinpath(dir, "gep.ll")
        write(path, MULTI_IDX_IR)
        try
            extract_parsed_ir_from_ll(path; entry_function="julia_multi_gep")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            @test occursin("getelementptr", lowercase(msg))
            # Either cites multi-index / unknown base / structural reason.
            @test occursin("multi", lowercase(msg)) ||
                  occursin("U16", msg) ||
                  occursin("unknown", lowercase(msg))
        end
    end
end
