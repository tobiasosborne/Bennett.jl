using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-tu6i / U10 — `extractvalue`/`insertvalue` on StructType hit
# `LLVM.eltype(struct_type)` in `_convert_instruction`, which raises a
# raw UndefRefError deep in the LLVM.jl bindings. Catalogue: every
# `.with.overflow` intrinsic, `cmpxchg`, or mixed-width tuple return
# trips this silently (stack-trace without Bennett context).
#
# Post-fix: `_ir_error` with a clear message naming the site + the
# StructType context.

const STRUCT_EV_IR = """
define i64 @julia_struct_ev(i64 %x, i64 %y) {
top:
  %pair = call {i64, i1} @llvm.sadd.with.overflow.i64(i64 %x, i64 %y)
  %sum  = extractvalue {i64, i1} %pair, 0
  ret i64 %sum
}
declare {i64, i1} @llvm.sadd.with.overflow.i64(i64, i64)
"""

const STRUCT_IV_IR = """
define i32 @julia_struct_iv(i32 %x) {
top:
  %dead = insertvalue {i32, i32} undef, i32 %x, 0
  ret i32 %x
}
"""

@testset "Bennett-tu6i struct extractvalue/insertvalue fail-loud" begin

    mktempdir() do dir
        # T1 — extractvalue on a {i64, i1} struct (sadd.with.overflow pattern).
        path_ev = joinpath(dir, "ev.ll")
        write(path_ev, STRUCT_EV_IR)
        try
            extract_parsed_ir_from_ll(path_ev; entry_function="julia_struct_ev")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            # Must be a Bennett-authored error, not a raw UndefRefError from
            # LLVM.eltype. Message must name "extractvalue" and "struct".
            @test !occursin("UndefRefError", msg)
            @test occursin("extractvalue", lowercase(msg))
            @test occursin("struct", lowercase(msg))
        end

        # T2 — insertvalue into a {i64, i32} struct (mixed-width tuple).
        path_iv = joinpath(dir, "iv.ll")
        write(path_iv, STRUCT_IV_IR)
        try
            extract_parsed_ir_from_ll(path_iv; entry_function="julia_struct_iv")
            @test false  # must raise
        catch e
            msg = sprint(showerror, e)
            @test !occursin("UndefRefError", msg)
            @test occursin("insertvalue", lowercase(msg))
            @test occursin("struct", lowercase(msg))
        end
    end
end
