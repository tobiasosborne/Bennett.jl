using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-tu6i / U10 — `extractvalue`/`insertvalue` on StructType hit
# `LLVM.eltype(struct_type)` in `_convert_instruction`, which raises a
# raw UndefRefError deep in the LLVM.jl bindings. Catalogue: every
# `.with.overflow` intrinsic, `cmpxchg`, or mixed-width tuple return
# trips this silently (stack-trace without Bennett context).
#
# Post-tu6i: `_ir_error` with a clear message naming the site + the StructType
# context.
#
# Bennett-6bu3 UPDATE: StructType insert/extract is now SUPPORTED for
# fixed-width integer ({8,16,32,64}) and (under ptr_cells) pointer fields
# (per-field layout). So a plain `{i64,i64}` / `{i32,i32}` struct now EXTRACTS
# — those were retired as fail-loud witnesses. The still-load-bearing
# fail-loud cases are the ones 6bu3 deliberately keeps rejecting:
#   * an i1 field (`{i64,i1}` — `sadd.with.overflow` / `cmpxchg` results);
#   * a non-integer (float) field.
# This test now pins THOSE rejections (the overflow/float walls), which keep
# the slot model from silently mis-lowering an i1 overflow flag or a float.
# Extracted WITHOUT ptr_cells (the circuit path) — these structs have no
# pointer fields, so the rejection is on width/type, not the ptr_cells gate.

# extractvalue on a {i64, i1} struct (the `*.with.overflow` result shape): the
# i1 field is rejected at the {8,16,32,64} width guard. Built via
# insertvalue-from-zeroinitializer so the i1 width guard (not an unsupported
# intrinsic-call return type) is the wall under test.
const STRUCT_EV_IR = """
define i64 @julia_struct_ev(i64 %x) {
top:
  %s = insertvalue {i64, i1} zeroinitializer, i64 %x, 0
  %sum = extractvalue {i64, i1} %s, 0
  ret i64 %sum
}
"""

# insertvalue into a {i64, double} struct (a float field): rejected as a
# non-integer field.
const STRUCT_IV_IR = """
define i64 @julia_struct_iv(i64 %x) {
top:
  %dead = insertvalue {i64, double} undef, i64 %x, 0
  ret i64 %x
}
"""

@testset "Bennett-tu6i / 6bu3 struct extractvalue/insertvalue fail-loud (i1 / float fields)" begin

    mktempdir() do dir
        # T1 — extractvalue on a {i64, i1} struct (sadd.with.overflow pattern):
        # the i1 field must still be rejected loud (Bennett-6bu3 width guard).
        path_ev = joinpath(dir, "ev.ll")
        write(path_ev, STRUCT_EV_IR)
        try
            extract_parsed_ir_from_ll(path_ev; entry_function="julia_struct_ev")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            # Must be a Bennett-authored error, not a raw UndefRefError from
            # LLVM.eltype. The 6bu3 width guard rejects the i1 field.
            @test !occursin("UndefRefError", msg)
            @test occursin("width 1", lowercase(msg)) ||
                  occursin("{8,16,32,64}", msg)
            @test occursin("6bu3", msg)
        end

        # T2 — insertvalue into a {i64, double} struct (a float field): the
        # non-integer field must still be rejected loud (Bennett-6bu3).
        path_iv = joinpath(dir, "iv.ll")
        write(path_iv, STRUCT_IV_IR)
        try
            extract_parsed_ir_from_ll(path_iv; entry_function="julia_struct_iv")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            @test !occursin("UndefRefError", msg)
            @test occursin("unsupported type", lowercase(msg)) ||
                  occursin("float", lowercase(msg)) ||
                  occursin("double", lowercase(msg))
            @test occursin("6bu3", msg)
        end
    end
end
