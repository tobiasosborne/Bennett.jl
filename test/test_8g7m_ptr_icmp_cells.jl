# Bennett-8g7m — CW-D: pointer-typed `icmp` under the closed-world `ptr_cells`
# gate.
#
# The wall (post-u2kk): extract_parsed_ir(Base.rehash!, Tuple{Dict{Int8,Int8},
# Int64}; optimize=false, ptr_cells=true) hits `icmp ne ptr %4, null` (a Dict-
# field null check) and fails loud at the Bennett-bjdg / U80 ConstantPointerNull
# wall from `_operand(::LLVM.PointerNull)` (helpers.jl). Two interlocked defects
# in the ICmp arm of `_convert_instruction` (src/extract/instructions.jl):
#   (A) it does NOT thread `ptr_cells` to `_operand`, so a `ptr null` operand
#       hits the U80 fail-loud instead of the beaw `null -> iconst(0)` cell path
#       (the `_operand` helper ALREADY does null->iconst(0) under ptr_cells);
#   (B) `_iwidth(ops[1])` on a PointerType operand hits `_type_width(PointerType)`
#       — the generic "unsupported LLVM type for width query: PointerType" error.
#
# The fix (ICmp arm only): under ptr_cells, if either operand is PointerType, a
# pointer is one Int64 VM cell (ADR 0018 §A, width 64) and a `ptr null` is the
# zero cell. ADMIT ONLY :eq / :ne (deterministic over cell ADDRESSES); the 8
# ordering predicates (ult/ugt/ule/uge/slt/sgt/sle/sge) compare address
# MAGNITUDES, which depend on the BVM allocation layout (UB across allocations in
# C) — FAIL LOUD (Rule 1). The integer path (ptr_cells=false, or non-pointer
# operands) is byte-identical.
#
# Gate map:
#   (A) ptr_cells=true, eq/ne ptr-vs-null: IRICmp(:eq|:ne, ssa, ConstOperand(0),
#       width 64) — the real fdict shape (positive node-shape, Rule 4).
#   (B) ptr_cells=true, eq/ne ptr-vs-ptr: IRICmp(:eq|:ne, ssa, ssa, width 64).
#   (C) ptr_cells=true, ORDERING ptr compare (ult/slt): FAIL LOUD with the
#       address-ordering message (occursin "Bennett-8g7m" and "address").
#   (D) ptr_cells=false byte-identity: eq-null -> U80 ConstantPointerNull wall;
#       eq-ptr -> _type_width PointerType wall (proves the gate is OFF — null is
#       NOT silently 0, ptr width is NOT silently 64 on the circuit path).
#   (E) non-pointer integer icmp unchanged under BOTH gates: `icmp slt i32 %a,
#       %b` -> IRICmp(:slt, ssa, ssa, 32) (the ptr guard must NOT catch integer
#       operands — integer ORDERING is still admitted).
#   (F) rehash! wall-ADVANCE: extract_parsed_ir(Base.rehash!, ...; ptr_cells=
#       true) NEGATIVE (no longer the ConstantPointerNull U80 wall) + inclusive
#       disjunction of plausible CW-D successors. Registry snapshot/restore
#       (Rule 7 — no _known_callees leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRICmp, ConstOperand, SSAOperand

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each isolates
# a single `icmp` so the fixture's first wall IS the icmp arm's behaviour.
# ---------------------------------------------------------------------------

# `icmp eq ptr %p, null` — the real fdict null-check shape. `%p` is a registered
# arg; the second operand is the ConstantPointerNull.
const EQ_NULL = """
define i1 @eq_null(ptr %p) {
top:
  %c = icmp eq ptr %p, null
  ret i1 %c
}
"""

# `icmp ne ptr %p, null` — the exact rehash! Dict-field null check shape.
const NE_NULL = """
define i1 @ne_null(ptr %p) {
top:
  %c = icmp ne ptr %p, null
  ret i1 %c
}
"""

# `icmp eq ptr %p, %q` — pointer-vs-pointer equality (both registered args).
const EQ_PTR = """
define i1 @eq_ptr(ptr %p, ptr %q) {
top:
  %c = icmp eq ptr %p, %q
  ret i1 %c
}
"""

# `icmp ult ptr %p, %q` — ORDERING compare over pointers (UB-flavoured address
# magnitude). Must FAIL LOUD under ptr_cells.
const ULT_PTR = """
define i1 @ult_ptr(ptr %p, ptr %q) {
top:
  %c = icmp ult ptr %p, %q
  ret i1 %c
}
"""

# `icmp slt ptr %p, %q` — signed ORDERING variant. Must FAIL LOUD under ptr_cells.
const SLT_PTR = """
define i1 @slt_ptr(ptr %p, ptr %q) {
top:
  %c = icmp slt ptr %p, %q
  ret i1 %c
}
"""

# `icmp slt i32 %a, %b` — non-pointer integer ORDERING. Must stay UNCHANGED under
# both gates (the ptr guard must not catch integer operands).
const SLT_I32 = """
define i1 @slt_i32(i32 %a, i32 %b) {
top:
  %c = icmp slt i32 %a, %b
  ret i1 %c
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

_only_icmp(pir) = (cs = filter(x -> x isa IRICmp, _all_insts(pir)); cs)

# Is `msg` the Bennett-bjdg / U80 ConstantPointerNull fail-loud wall?
_is_null_wall(msg) =
    occursin("ConstantPointerNull operand", msg) &&
    occursin("Bennett-bjdg / U80", msg)

# Is `msg` the PointerType scalar-width wall (helpers.jl _type_width fallthrough)?
_is_ptr_width_wall(msg) =
    occursin("PointerType", msg) &&
    (occursin("width query", lowercase(msg)) || occursin("_type_width", msg))

@testset "Bennett-8g7m ptr icmp under ptr_cells" begin

    # =======================================================================
    # GATE (A) — ptr_cells=true: eq/ne ptr-vs-null -> IRICmp over a zero cell.
    # =======================================================================
    @testset "GATE (A) — icmp eq ptr %p, null -> :eq over ConstOperand(0) cell" begin
        (st, pir) = _extract_ll("eq_null", EQ_NULL, "eq_null"; cells=true)
        @test st === :ok
        if st === :ok
            cs = _only_icmp(pir)
            @test length(cs) == 1
            c = cs[1]
            @test c.predicate === :eq
            @test c.op1 isa SSAOperand            # %p
            @test c.op2 isa ConstOperand          # null -> zero cell
            @test c.op2.value == 0
            @test c.width == 64                   # one Int64 VM cell
        end
    end

    @testset "GATE (A) — icmp ne ptr %p, null -> :ne over ConstOperand(0) cell" begin
        (st, pir) = _extract_ll("ne_null", NE_NULL, "ne_null"; cells=true)
        @test st === :ok
        if st === :ok
            cs = _only_icmp(pir)
            @test length(cs) == 1
            c = cs[1]
            @test c.predicate === :ne
            @test c.op1 isa SSAOperand
            @test c.op2 isa ConstOperand
            @test c.op2.value == 0
            @test c.width == 64
        end
    end

    # =======================================================================
    # GATE (B) — ptr_cells=true: eq ptr-vs-ptr -> both SSA, width 64.
    # =======================================================================
    @testset "GATE (B) — icmp eq ptr %p, %q -> :eq over two cells (width 64)" begin
        (st, pir) = _extract_ll("eq_ptr", EQ_PTR, "eq_ptr"; cells=true)
        @test st === :ok
        if st === :ok
            cs = _only_icmp(pir)
            @test length(cs) == 1
            c = cs[1]
            @test c.predicate === :eq
            @test c.op1 isa SSAOperand
            @test c.op2 isa SSAOperand
            @test c.width == 64
        end
    end

    # =======================================================================
    # GATE (C) — ptr_cells=true: ORDERING ptr compare FAILS LOUD (Rule 1).
    # Address-magnitude comparison is layout-dependent / UB.
    # =======================================================================
    @testset "GATE (C) — icmp ult ptr fails loud (address-ordering)" begin
        (st, msg) = _extract_ll("ult_ptr", ULT_PTR, "ult_ptr"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-8g7m", msg)
            @test occursin("address", lowercase(msg))
            @test occursin(":ult", msg)
        end
    end

    @testset "GATE (C) — icmp slt ptr fails loud (address-ordering)" begin
        (st, msg) = _extract_ll("slt_ptr", SLT_PTR, "slt_ptr"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-8g7m", msg)
            @test occursin("address", lowercase(msg))
            @test occursin(":slt", msg)
        end
    end

    # =======================================================================
    # GATE (D) — ptr_cells=false byte-identity: the gate is OFF. null is NOT
    # silently 0, ptr width is NOT silently 64.
    # =======================================================================
    @testset "GATE (D) — eq ptr null walls at U80 (gate off)" begin
        (st, msg) = _extract_ll("eq_null_off", EQ_NULL, "eq_null"; cells=false)
        @test st === :err
        if st === :err
            @test _is_null_wall(msg)
        end
    end

    @testset "GATE (D) — eq ptr %p,%q walls at PointerType width (gate off)" begin
        (st, msg) = _extract_ll("eq_ptr_off", EQ_PTR, "eq_ptr"; cells=false)
        @test st === :err
        if st === :err
            @test _is_ptr_width_wall(msg)
        end
    end

    # =======================================================================
    # GATE (E) — non-pointer integer icmp UNCHANGED under BOTH gates. The ptr
    # guard must NOT catch integer operands; integer ORDERING is still admitted.
    # =======================================================================
    @testset "GATE (E) — icmp slt i32 unchanged (both gates)" begin
        for cells in (false, true)
            (st, pir) = _extract_ll("slt_i32_$(cells)", SLT_I32, "slt_i32"; cells=cells)
            @test st === :ok
            if st === :ok
                cs = _only_icmp(pir)
                @test length(cs) == 1
                c = cs[1]
                @test c.predicate === :slt
                @test c.op1 isa SSAOperand
                @test c.op2 isa SSAOperand
                @test c.width == 32               # i32 operands, NOT a 64-bit cell
            end
        end
    end

    # =======================================================================
    # GATE (F) — rehash! wall-ADVANCE under ptr_cells=true. Pre-fix the root
    # walls at the ConstantPointerNull U80 wall (`icmp ne ptr %4, null`); post-
    # fix the eq/ne-over-cell modeling fires and a LATER wall surfaces. Assert
    # NEGATIVELY (no longer the U80 null wall) + an inclusive disjunction of
    # plausible CW-D successors (Rule 5 — order-dependent). Registry snapshot/
    # restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (F) — rehash! advances past the ptr-null icmp U80 wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Dict{Int8,Int8},Int64}
            on_msg = try
                extract_parsed_ir(Base.rehash!, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true   # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the ConstantPointerNull U80 wall.
                @test !_is_null_wall(on_msg)
                # POSITIVE inclusive disjunction of plausible CW-D successors.
                # GENUINE live landing (2026-06-29, registry-clean direct entry):
                # the UndefValue / U80 wall on a `phi i64 [ undef, ... ]` node —
                # `_operand(::UndefValue)` via the PHI arm (helpers.jl). The
                # address-icmp fix advanced rehash! PAST the `icmp ne ptr %4,
                # null` ConstantPointerNull wall to this `i64 undef` phi-incoming.
                # Other disjuncts kept inclusive (Rule 5 — order-dependent).
                @test occursin("undefvalue", lowercase(on_msg))      ||  # GENUINE post-8g7m landing
                      occursin("undef", lowercase(on_msg))           ||  # phi i64 undef incoming
                      occursin("aggregate", lowercase(on_msg))       ||
                      occursin("structtype", lowercase(on_msg))      ||
                      occursin("insertvalue", lowercase(on_msg))     ||
                      occursin("memcpy", lowercase(on_msg))          ||
                      occursin("genericmemory", lowercase(on_msg))   ||
                      occursin("gc_alloc_obj", lowercase(on_msg))    ||
                      occursin("ptrtoint", lowercase(on_msg))        ||
                      occursin("inttoptr", lowercase(on_msg))        ||
                      occursin("type-tag", lowercase(on_msg))        ||
                      occursin("iwo9", lowercase(on_msg))            ||
                      occursin("atomic", lowercase(on_msg))          ||
                      occursin("unsupported llvm opcode", lowercase(on_msg)) ||
                      occursin("U14", on_msg)                        ||
                      occursin("U81", on_msg)                        ||
                      occursin("VoidType", on_msg)                   ||
                      occursin("sret", lowercase(on_msg))            ||
                      occursin("U15", on_msg)                        ||
                      occursin("no registered callee", on_msg)       ||
                      occursin("closed-world", on_msg)               ||
                      occursin("PointerType", on_msg)
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
