using Test
using Bennett: extract_parsed_ir_from_ll
import Bennett

# Bennett-qal5 / U16 — multi-index `getelementptr` and GEPs with neither
# a named-SSA base nor a GlobalVariable base were silently dropped at
# `src/ir_extract.jl:1706`. The GEP's dest SSA was left undefined; any
# load or pointer use that referenced it crashed far from the root cause.
# Minimum-viable fix per catalogue: `_ir_error` naming the GEP shape.
# Full type-walking byte-offset accumulation is future work.
#
# UPDATE (bead `bennettvm-416r.4`): the ORIGINAL fixture here —
# `getelementptr [4 x i32], ptr @tbl, i32 0, i32 %i`, a two-index array GEP on
# a CONST GLOBAL integer array read at a RUNTIME index — is now SUPPORTED
# (front-end Case C in `src/extract/instructions.jl`: it lowers to
# `IRVarGEP(:tbl, %i, 32)`, the same node the single-index global GEP arm
# already emits → QROM on the circuit backend / a read-only global segment on
# BennettVM). That IS the 416r.4 goal (a const array read at a runtime index).
# The SAME arm also handles a local alloca-backed stack array (Bennett-dzd).
# This file now pins the shapes that REMAIN unsupported (so the qal5 / U16
# breadcrumb still fires loud on them), plus a POSITIVE check that the
# now-supported const-global-array shape extracts.

# (a) A genuine multi-DIMENSIONAL GEP — 4 operands (base + THREE indices) into a
# nested `[2 x [2 x i32]]`. Case C requires `length(ops) == 3`, so this still
# falls through to the qal5 / U16 wall (full type-walking byte-offset
# accumulation across ≥2 index dimensions is future work).
const MULTIDIM_IR = """
@m = private constant [2 x [2 x i32]] [[2 x i32] [i32 1, i32 2], [2 x i32] [i32 3, i32 4]]
define i32 @julia_multidim_gep(i32 %i, i32 %j) {
top:
  %q = getelementptr [2 x [2 x i32]], ptr @m, i32 0, i32 %i, i32 %j
  %v = load i32, ptr %q
  ret i32 %v
}
"""

# (b) A two-index array GEP whose array element is NON-INTEGER (`[4 x double]`),
# on a local alloca base. Case C fires (ArrayType, local base) but fails loud —
# a float element has no bit-exact `elem_width` for the reversible lowering.
const NONINT_ELEM_IR = """
define double @julia_farr_gep(i32 %i) {
top:
  %a = alloca [4 x double]
  %q = getelementptr [4 x double], ptr %a, i32 0, i32 %i
  %v = load double, ptr %q
  ret double %v
}
"""

# (c) The now-SUPPORTED shape (bead `bennettvm-416r.4`): a two-index array GEP on
# a const global INTEGER array read at a runtime index. Must extract cleanly.
const GLOBAL_ARRAY_IR = """
@tbl = private constant [4 x i32] [i32 1, i32 2, i32 3, i32 4]
define i32 @julia_global_array_gep(i32 %i) {
top:
  %q = getelementptr [4 x i32], ptr @tbl, i32 0, i32 %i
  %v = load i32, ptr %q
  ret i32 %v
}
"""

@testset "Bennett-qal5 multi-index GEP fail-loud" begin
    for (ir, fn) in [(MULTIDIM_IR, "julia_multidim_gep"),
                     (NONINT_ELEM_IR, "julia_farr_gep")]
        mktempdir() do dir
            path = joinpath(dir, "gep.ll")
            write(path, ir)
            try
                extract_parsed_ir_from_ll(path; entry_function=fn)
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
end

@testset "bennettvm-416r.4 two-index const-global-array GEP now supported" begin
    mktempdir() do dir
        path = joinpath(dir, "gep.ll")
        write(path, GLOBAL_ARRAY_IR)
        # ptr_cells=true (the BennettVM C-track mode); also works with the
        # default circuit mode, but the segment is exercised under ptr_cells.
        parsed = extract_parsed_ir_from_ll(path;
                                           entry_function="julia_global_array_gep",
                                           ptr_cells=true)
        @test haskey(parsed.globals, :tbl)
        data, ew = parsed.globals[:tbl]
        @test data == UInt64[1, 2, 3, 4]
        @test ew == 32
        vgeps = Bennett.IRVarGEP[]
        for b in parsed.blocks, inst in b.instructions
            inst isa Bennett.IRVarGEP && push!(vgeps, inst)
        end
        @test length(vgeps) == 1
        @test vgeps[1].base isa Bennett.SSAOperand && vgeps[1].base.name === :tbl
        @test vgeps[1].elem_width == 32
    end
end
