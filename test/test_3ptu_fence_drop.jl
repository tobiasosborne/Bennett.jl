# Bennett-3ptu — CW-D2 lever: DROP LLVM `fence` under the closed-world
# `ptr_cells=true` VM gate; keep it FAIL-LOUD on the circuit path
# (`ptr_cells=false`).
#
# A `fence` is a pure memory-ordering barrier with NO data effect. In the
# single-threaded, deterministic, history-reversible BennettVM cell model it is a
# genuine no-op (no state change, trivially reversible). Every Julia callee in
# the fdict closed-world path emits 2 such fences (GC safepoint / write-barrier
# fences), so dropping them unblocks setindex!/rehash!/ht_keyindex2_shorthash!
# extraction.
#
# This mirrors two already-landed CW-D2 levers: gc_preserve token drop
# (Bennett-zf5v) and VM-gated atomic relaxation (Bennett-ares). Like those, the
# drop is ptr_cells-gated and exact-opcode-scoped — the gate defaults false so
# the circuit path is byte-identical (the existing "unsupported LLVM opcode"
# fail-loud still fires for `fence`).
#
# Gate map:
#   (a) ptr_cells=true:  the `fence` is DROPPED — extraction SUCCEEDS, the fence
#       leaves NO instruction in the lowered stream, and the surrounding integer
#       op survives (positive node shape — Rule 4, not just no-throw).
#   (b) ptr_cells=false: the SAME fixture still walls at the unsupported-opcode
#       fail-loud (byte-identity — the drop lives behind the gate).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, ParsedIR

# A MINIMAL fixture that isolates `fence`: a trivial integer op (`add`) plus a
# `fence` plus an integer return. NO ptrtoint / insertvalue / sret — those are
# their own separate opcode walls (separate beads) and would mask this drop
# proof. `fence syncscope("singlethread") seq_cst` is exactly the GC-safepoint
# barrier shape Julia emits; the plain `fence seq_cst` variant is covered too.
const FENCE_SINGLETHREAD = """
define i64 @fence_st(i64 %x) {
top:
  %y = add i64 %x, 1
  fence syncscope("singlethread") seq_cst
  ret i64 %y
}
"""

const FENCE_PLAIN = """
define i64 @fence_plain(i64 %x) {
top:
  %y = add i64 %x, 1
  fence seq_cst
  ret i64 %y
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _extract_ll_3ptu(name, ir, entry; cells)
    mktempdir() do dir
        path = joinpath(dir, "$(name).ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=cells)
            return (:ok, pir)
        catch e
            e isa InterruptException && rethrow()
            return (:err, sprint(showerror, e))
        end
    end
end

# Collect all instructions across blocks.
_all_insts_3ptu(pir) = [ins for b in pir.blocks for ins in b.instructions]

@testset "Bennett-3ptu fence drop under ptr_cells" begin

    # =======================================================================
    # GATE (a) — cells=true: the fence is DROPPED; the add survives.
    # Positive node-shape assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — fence dropped under ptr_cells, add survives (singlethread)" begin
        (st, pir) = _extract_ll_3ptu("fence_st", FENCE_SINGLETHREAD, "fence_st"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_3ptu(pir)
            # The fence produced NO IR instruction (dropped → return nothing):
            # there is no IRFence type in the IR hierarchy, so the witness is
            # that the surrounding `add` is the ONLY arithmetic op and the
            # instruction stream is exactly {binop} (the ret is carried on the
            # block, not as a body instruction).
            binops = filter(x -> x isa Bennett.IRBinOp, insts)
            @test length(binops) == 1            # the `add i64 %x, 1` survived
            @test binops[1].op === :add
            # No stray instruction beyond the single add was emitted for the
            # fence (it vanished entirely).
            @test length(insts) == 1
        end
    end

    @testset "GATE (a') — plain fence dropped under ptr_cells, add survives" begin
        (st, pir) = _extract_ll_3ptu("fence_plain", FENCE_PLAIN, "fence_plain"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_3ptu(pir)
            binops = filter(x -> x isa Bennett.IRBinOp, insts)
            @test length(binops) == 1
            @test binops[1].op === :add
            @test length(insts) == 1
        end
    end

    # =======================================================================
    # GATE (b) — cells=false: SAME fixture still walls (byte-identity). The
    # drop lives behind the ptr_cells gate; on the circuit path a `fence`
    # reaches the existing "unsupported LLVM opcode" fail-loud (Rule 1: the
    # circuit path does NOT silently drop the fence).
    # =======================================================================
    @testset "GATE (b) — cells=false still walls (byte-identity, no drop)" begin
        (st, msg) = _extract_ll_3ptu("fence_st_off", FENCE_SINGLETHREAD, "fence_st"; cells=false)
        @test st === :err
        if st === :err
            @test occursin("unsupported LLVM opcode", msg)
            @test occursin("fence", msg)
        end
    end

end
