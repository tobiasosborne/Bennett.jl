using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-8b2f / U17 — `_get_deref_bytes` IR-string fallback regex was
# `dereferenceable\((\d+)\)` anchored to the whole `define` line. On
# functions with multiple ptr params carrying different dereferenceable
# values, every call returned the FIRST match regardless of which param
# it was queried for — phantom input-wire counts for non-matching params.
# The primary `LLVM.parameter_attributes(func, idx)` path is per-param
# and correct; the fallback fired on older LLVM.jl versions or when the
# primary raised MethodError. Fix: anchor the fallback regex to the
# individual param name.
#
# This test exercises the observable invariant — `args` input_widths in
# ParsedIR — on a function with two ptr params whose dereferenceable
# counts differ (8 bytes vs 4 bytes). Post-fix, either path returns the
# per-param value correctly; pre-fix, the fallback path would return 8
# for both.

const DEREF_IR = """
define i32 @julia_two_deref(ptr dereferenceable(8) %big, ptr dereferenceable(4) %small) {
top:
  %b = load i32, ptr %big
  %s = load i32, ptr %small
  %r = add i32 %b, %s
  ret i32 %r
}
"""

@testset "Bennett-8b2f _get_deref_bytes per-param regex" begin
    mktempdir() do dir
        path = joinpath(dir, "two_deref.ll")
        write(path, DEREF_IR)
        pir = extract_parsed_ir_from_ll(path; entry_function="julia_two_deref")
        # `args` is a vector of (name, width_bits). `big` should be 8 bytes
        # = 64 bits wide, `small` should be 4 bytes = 32 bits wide.
        widths_by_name = Dict{Symbol, Int}()
        for (name, w) in pir.args
            widths_by_name[name] = w
        end
        @test widths_by_name[:big]   == 64
        @test widths_by_name[:small] == 32
    end
end
