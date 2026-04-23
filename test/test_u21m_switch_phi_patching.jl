using Test
using Bennett: extract_parsed_ir_from_ll, reversible_compile, simulate
using Bennett: IRPhi

# Bennett-u21m / U11 — `_expand_switches` had two phi-patching bugs:
#
# (1) Scope: the patching sweep ran inside the per-block loop, so it only
#     saw blocks appended to `result` up to that point. Phi nodes in later
#     successor blocks were never rewritten.
#
# (2) Dedup: `phi_remap::Dict{Symbol,Symbol}` was keyed by target_label, so
#     when multiple switch cases share a target, each case overwrote the
#     previous, and the phi ended up with exactly one (wrong) incoming.
#
# Post-fix: phi patching runs as a final global sweep; a single
# pre-expansion incoming `(val, orig_switch)` expands to one incoming per
# unique synthetic predecessor block of the phi's host block.

# Switch with case 1 and case 3 pointing at the same label `L`. Post-
# expansion, `L` has two predecessors: `top` (from the first cmp) and
# `_sw_top_3` (from the last cmp, which also serves as the default). The
# phi at `L` must cite BOTH predecessors.
const SWITCH_DUP_IR = """
define i8 @julia_switch_shared(i8 %x) {
top:
  switch i8 %x, label %default [
    i8 1, label %L
    i8 2, label %M
    i8 3, label %L
  ]
L:
  %y = phi i8 [ 10, %top ]
  ret i8 %y
M:
  ret i8 20
default:
  ret i8 0
}
"""

@testset "Bennett-u21m switch phi patching" begin

    mktempdir() do dir
        path = joinpath(dir, "sw.ll")
        write(path, SWITCH_DUP_IR)

        pir = extract_parsed_ir_from_ll(path; entry_function="julia_switch_shared")

        # Locate block L and its phi.
        blk_L = only(filter(b -> b.label === :L, pir.blocks))
        phi = only(filter(i -> i isa IRPhi, blk_L.instructions))
        sources = Set(src for (_, src) in phi.incoming)

        # T1 — phi must cite every post-expansion predecessor of L. After
        # expansion, L is reached from `top` (case 1) and `_sw_top_3`
        # (case 3 AND default both emit their "true" branch into L).
        @test :top in sources
        @test :_sw_top_3 in sources

        # T2 — constant value 10 preserved for every incoming.
        for (val, _) in phi.incoming
            @test val.kind == :const && val.value == 10
        end

        # T3 — end-to-end: reversible_compile + simulate agrees with the
        # switch semantics on all 256 Int8 inputs.
        c = reversible_compile(pir)
        for x in 0x00:0xFF
            expected = (x == 1 || x == 3) ? 10 :
                       (x == 2)            ? 20 :
                                             0
            got = simulate(c, x)
            @test got == expected
        end
    end
end
