using Test
using Bennett: extract_parsed_ir_from_ll

# Bennett-l9cl / U09 — `convert(Int, ::LLVM.ConstantInt)` silently truncates
# to the low 64 bits for i128 (and wider) operands. Catalogue repro:
#   `i128 1 << 127` -> stored as 0 in IROperand.value.
# A later-but-unreachable silent zero would flip-flop gate counts in a
# way impossible to debug. Per CLAUDE.md §1 (fail-loud), extractor must
# crash immediately with a clear message when the width exceeds 64.

const I128_IR = """
define i128 @julia_use_i128(i128 %x) {
top:
  %y = add i128 %x, 170141183460469231731687303715884105727
  ret i128 %y
}
"""

@testset "Bennett-l9cl i128 ConstantInt fail-loud" begin

    mktempdir() do dir
        path = joinpath(dir, "i128.ll")
        write(path, I128_IR)

        # Pre-fix: extract_parsed_ir_from_ll silently returned an IRBinOp
        # whose rhs IROperand had `value = 0x7FFF_FFFF_FFFF_FFFF` (low 64 bits)
        # instead of a giant i128. Post-fix: error loudly naming the width.
        try
            extract_parsed_ir_from_ll(path; entry_function="julia_use_i128")
            @test false  # should not reach here
        catch e
            msg = sprint(showerror, e)
            # Must name both the bit-width and enough context to diagnose.
            @test occursin("128", msg) || occursin("wider than 64", msg) ||
                  occursin("width", msg)
        end
    end
end
