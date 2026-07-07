# Bennett-yd4f / U80 / CW-D (ADR 0017): under the closed-world `ptr_cells` gate
# ONLY, an INTEGER-typed `LLVM.UndefValue` in PHI-INCOMING position lowers to
# `iconst(0)` (a `ConstOperand(0)`) instead of the Bennett-bjdg / U80 fail-loud.
#
# Soundness (established by prior IR analysis — see the bead): an integer
# `undef` in phi-incoming position is LLVM's compiler-proven don't-care on a
# dynamically-dead edge (LangRef: undef as a phi operand). BennettVM resolves
# phis by the TAKEN predecessor edge (BennettVM/src/ir/ingest_phi.jl:84), so a
# `0` placeholder on a dead incoming is never materialised at runtime. This
# unblocks recursive-callee extraction of `Base.rehash!` for the fdict Dict
# round-trip: `rehash!(::Dict{Int8,Int8},::Int64)` at `optimize=false` has
# EXACTLY 5 undef operands, all `i64`, all phi-incoming, all dynamically dead.
#
# Position-DEPENDENCE is load-bearing (the fix is gated at the phi site, NOT in
# `_operand`):
#   * INTEGER undef in phi-incoming under ptr_cells   → iconst(0)   (GATE 1)
#   * INTEGER undef anywhere else (e.g. `ret i64 undef`) → FAIL LOUD (GATE 2)
#   * POISON in phi-incoming (distinct LLVM.jl type, NOT a subtype of
#     UndefValue) → FAIL LOUD                                        (GATE 3)
#   * NON-INTEGER (ptr) undef in phi-incoming → FAIL LOUD            (GATE 4)
#   * ptr_cells=false (circuit/:heap) → byte-identical FAIL LOUD (all gates)
#
# GATE 5 pins the real-target WALL-ADVANCE for `Base.rehash!`: after the fix the
# undef phi wall is CLEARED and extraction advances to the NEXT wall (see the
# per-mode disjunction). Registry snapshot/restore (Rule 7 — no _known_callees
# leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRPhi, ConstOperand, SSAOperand

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each isolates
# a single phi / undef so the fixture's first wall IS the arm under test.
# ---------------------------------------------------------------------------

# INTEGER undef in phi-incoming — the real rehash! shape (Julia's O0 dead-arm
# placeholder). The `[ 7, %top ]` literal proves a `0` on the `%loop` edge is
# undef-DERIVED, not coincidental. Extraction succeeds under ptr_cells=true.
const UNDEF_PHI = """
define i64 @undef_phi(i64 %n) {
top:
  br label %loop
loop:
  %i = phi i64 [ 7, %top ], [ undef, %loop ]
  %c = icmp slt i64 %i, %n
  br i1 %c, label %loop, label %done
done:
  ret i64 %i
}
"""

# INTEGER undef in RETURN (non-phi) position — must STAY fail-loud under BOTH
# gates (the fix is phi-position-gated; every other operand position keeps
# `_operand`'s U80 undef fail-loud).
const UNDEF_RET = """
define i64 @undef_ret() {
top:
  ret i64 undef
}
"""

# POISON in phi-incoming — PoisonValue is a DISTINCT LLVM.jl type (sibling of
# UndefValue, not a subtype), so it is NOT caught by the undef gate and stays
# fail-loud under BOTH gates.
const POISON_PHI = """
define i64 @poison_phi(i64 %n) {
top:
  br label %loop
loop:
  %i = phi i64 [ 7, %top ], [ poison, %loop ]
  %c = icmp slt i64 %i, %n
  br i1 %c, label %loop, label %done
done:
  ret i64 %i
}
"""

# NON-INTEGER (ptr) undef in phi-incoming — the undef gate is guarded by
# `value_type isa IntegerType`, so a ptr undef falls through to `_operand` and
# stays fail-loud under BOTH gates. `%q` is a dead ptr phi (function returns
# i64, so the ptr-RETURN wall never pre-empts the phi undef wall).
const UNDEF_PTR_PHI = """
define i64 @undef_ptr_phi(ptr %p, i1 %c) {
top:
  br label %loop
loop:
  %q = phi ptr [ %p, %top ], [ undef, %loop ]
  br i1 %c, label %loop, label %done
done:
  ret i64 0
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _extract_ll(name, ir, entry; cells)
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

# Collect all instructions across blocks, INCLUDING terminators.
function _all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# The operand of `phi`'s incoming edge from block `blk`, or `nothing`.
function _incoming_from(phi::IRPhi, blk::Symbol)
    for (op, from) in phi.incoming
        from === blk && return op
    end
    return nothing
end

# Is `msg` the Bennett-bjdg / U80 UndefValue fail-loud wall?
_is_undef_wall(msg) =
    occursin("UndefValue operand", msg) &&
    occursin("Bennett-bjdg / U80", msg)

@testset "Bennett-yd4f integer undef phi-incoming → zero cell under ptr_cells" begin

    # =======================================================================
    # GATE 1 — ptr_cells=true: INTEGER undef in phi-incoming → ConstOperand(0).
    # Positive node-shape assertions (Rule 4: no-throw is not a pass). The
    # `%top` incoming keeps its literal 7; the `%loop` incoming is the undef →
    # zero cell (proving the 0 is undef-derived, not coincidental).
    # =======================================================================
    @testset "GATE 1 — undef phi-incoming lowers to ConstOperand(0)" begin
        (st, pir) = _extract_ll("undef_phi", UNDEF_PHI, "undef_phi"; cells=true)
        @test st === :ok
        if st === :ok
            phis = filter(x -> x isa IRPhi, _all_insts(pir))
            @test length(phis) == 1
            phi = phis[1]
            @test phi.width == 64                 # i64 phi

            top_op = _incoming_from(phi, :top)
            @test top_op isa ConstOperand
            @test top_op.value == 7               # literal 7 — NOT undef-derived

            loop_op = _incoming_from(phi, :loop)
            @test loop_op isa ConstOperand
            @test loop_op.value == 0              # undef → zero cell
        end
    end

    # =======================================================================
    # GATE 2 — INTEGER undef in NON-phi (return) position STILL fails loud
    # under BOTH gates. The fix is phi-position-gated; `_operand`'s undef
    # fail-loud is untouched.
    # =======================================================================
    @testset "GATE 2 — non-phi integer undef stays fail-loud (both gates)" begin
        for cells in (true, false)
            (st, msg) = _extract_ll("undef_ret_$(cells)", UNDEF_RET, "undef_ret"; cells=cells)
            @test st === :err
            if st === :err
                @test occursin("UndefValue operand", msg)
                @test occursin("Bennett-bjdg / U80", msg)
            end
        end
    end

    # =======================================================================
    # GATE 3 — POISON in phi-incoming STILL fails loud under BOTH gates.
    # PoisonValue is a DISTINCT type (not caught by the UndefValue gate).
    # =======================================================================
    @testset "GATE 3 — poison phi-incoming stays fail-loud (both gates)" begin
        for cells in (true, false)
            (st, msg) = _extract_ll("poison_phi_$(cells)", POISON_PHI, "poison_phi"; cells=cells)
            @test st === :err
            if st === :err
                @test occursin("PoisonValue operand", msg)
            end
        end
    end

    # =======================================================================
    # GATE 4 — NON-INTEGER (ptr) undef in phi-incoming STILL fails loud under
    # BOTH gates. The undef gate requires `value_type isa IntegerType`; a ptr
    # undef falls through to `_operand`'s undef wall.
    # =======================================================================
    @testset "GATE 4 — non-integer (ptr) undef phi-incoming stays fail-loud (both gates)" begin
        for cells in (true, false)
            (st, msg) = _extract_ll("undef_ptr_phi_$(cells)", UNDEF_PTR_PHI, "undef_ptr_phi"; cells=cells)
            @test st === :err
            if st === :err
                @test occursin("undef", lowercase(msg))
            end
        end
    end

    # =======================================================================
    # GATE 5 — real-target WALL-ADVANCE for `Base.rehash!`. Pre-fix the root
    # walls at the `phi i64 [ undef, ... ]` UndefValue / U80 wall (5 dead-edge
    # undef incomings). Post-fix that wall is CLEARED and extraction advances
    # to the NEXT wall. Assert NEGATIVELY (no longer the UndefValue wall) + an
    # inclusive per-mode disjunction of plausible CW-D successors (Rule 5 —
    # order-tolerant per the beaw/u2kk lesson). Registry snapshot/restore
    # (Rule 7 — no _known_callees leak).
    #
    # OBSERVED walls (re-probed 2026-07-07 post-Bennett-lbot, this machine):
    #   * BOTH check-bounds modes : `rehash!` walls at the VARIABLE-SIZE
    #                              `llvm.memset.p0.i64` zeroing `h::Dict.slots2`
    #                              (non-constant byte count — Bennett-8bys /
    #                              Bennett-9nwt; the message names both `memset`
    #                              and `variable-size memcpy`). Bennett-lbot FUSED
    #                              the `llvm.smul.with.overflow.i64` GenericMemory
    #                              size-check that used to gate this body, so
    #                              rehash! now extracts PAST it to this memset wall.
    #   Earlier (pre-lbot) walls retained as future-robust disjuncts: default
    #   `j_AssertionError [1 x ptr]` unsupported RETURN TYPE (`assertionerror` /
    #   `arraytype`), suite-mode `ptrtoint %memory_data` (`ptrtoint` / `iwo9`).
    # =======================================================================
    @testset "GATE 5 — rehash! advances past the undef-phi U80 wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Dict{Int8,Int8},Int64}

            # --- ptr_cells=true: the undef-phi wall must be GONE. Either it
            #     extracts, or it advances to a DIFFERENT (later) wall.
            on_msg = try
                extract_parsed_ir(Base.rehash!, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # LOAD-BEARING NEGATIVE: the undef wall is cleared.
                @test !occursin("UndefValue operand", on_msg)
                # POSITIVE inclusive disjunction covering BOTH modes.
                lc = lowercase(on_msg)
                @test occursin("unsupported return type", lc) ||
                      occursin("assertionerror", lc)          ||
                      occursin("arraytype", lc)               ||
                      occursin("ptrtoint", lc)                ||
                      occursin("iwo9", lc)                    ||
                      occursin("type-tag", lc)                ||
                      occursin("memset", lc)                  ||  # Bennett-lbot: rehash! frontier
                      occursin("memcpy", lc)                  ||  #   advanced to the variable-size
                      occursin("8bys", lc)                    ||  #   memset (Bennett-8bys / 9nwt)
                      occursin("9nwt", lc)                    ||
                      occursin("gc_alloc_obj", lc)            ||
                      occursin("no registered callee", lc)    ||
                      occursin("closed-world", lc)
            end

            # --- ptr_cells=false: byte-identity — the gate is OFF, so extraction
            #     must STILL fail (no silent undef→0 modeling on the circuit
            #     path). OBSERVED wall (both modes): the ptr-RETURN / ptr-width
            #     wall (`unsupported LLVM type for width query: PointerType`),
            #     which pre-empts the undef phi under cells=false. Assert it
            #     still errors + is a pointer wall (defensively inclusive of the
            #     undef wall).
            off_msg = try
                extract_parsed_ir(Base.rehash!, at; optimize=false, ptr_cells=false)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test off_msg !== nothing               # gate OFF — no silent success
            if off_msg !== nothing
                @test occursin("PointerType", off_msg)          ||
                      occursin("pointer", lowercase(off_msg))   ||
                      occursin("UndefValue operand", off_msg)
            end
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
