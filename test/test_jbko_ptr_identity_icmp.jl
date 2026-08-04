# Bennett-jbko / CW-D — admit a USE-SCOPED `ptrtoint ptr %p to i64` as the
# width-64 cell identity `IRBinOp(dest, :or, <src>, iconst(0), 64)` under the
# closed-world `ptr_cells=true` gate, BUT ONLY when
#
#   (P1) source and destination widths are both 64;
#   (P2) the source is a CERTIFIED cell-valued pointer SSA — an `extractvalue`
#        of a `StructType` pointer field, or a `load` whose result type is a
#        pointer — in addrspace 0;
#   (P3) the result has >= 1 use and EVERY use is an `icmp eq` / `icmp ne`;
#   (P4) for every such use the SIBLING operand is an in-model SSA value (an
#        instruction or a function argument) or the ZERO cell (null, beaw).
#
# The corpus witness is Julia's `MemoryRef` concurrent-mutation guard in
# `_growend!` `%L84` (the `bennettvm-xkl` push!-Vector frontier, wall 5):
#
#     %.ref.ptr_or_offset = extractvalue { ptr, ptr } %.ref, 0   ; CURRENT data ptr
#     %.unbox14 = load i64, ptr %self_plus_56                    ; CAPTURED copy (a CELL)
#     %coercion = ptrtoint ptr %.ref.ptr_or_offset to i64        ; <-- THE WALL
#     %59 = icmp eq i64 %.unbox14, %coercion                     ; the SOLE use
#     %61 = icmp eq ptr %memoryref_mem30, %.ref.mem              ; ALREADY admitted (8g7m)
#
# Julia compares BOTH halves of the same MemoryRef. The `.mem` half is already
# admitted as a plain `icmp eq ptr` by Bennett-8g7m / U80. jbko adds ZERO
# expressive power over that: it only lets the SAME comparison be spelled
# through an integer coercion, which is what codegen emits when the other side
# happens to be a captured copy stored as an `i64`.
#
# THE USE GATE IS LOAD-BEARING (this file's reason to exist). 8g7m's
# ordering-reject is TYPE-based (`instructions.jl:2917` — it fires only when an
# operand has `PointerType`). An `icmp ult i64 %coerced, %n` has NO
# pointer-typed operand, so an UNGATED `ptrtoint` admission would launder an
# address-MAGNITUDE compare onto the plain integer icmp path and silently
# disable 8g7m. Gate (C) is that pin.
#
# (P2) IS ALSO LOAD-BEARING, and is the file's most important negative test.
# Bennett-cc0 M2b gives pointer-typed `phi` / `select` a WIDTH-0 SENTINEL
# (`instructions.jl:2937`, `:2971`) — their routing is recorded in
# `ptr_provenance` at LOWERING time, not as a value. Coercing one would emit an
# `:or` identity reading a cell that was NEVER MATERIALISED: a SILENT
# miscompile, not a loud one. Gates (G)/(H) pin the reject.
#
# Gate map:
#   (A) GREEN  — the real `%L84` guard shape (extractvalue source, 8g7m sibling
#                intact) extracts; EXACT ParsedIR pins.
#   (B) GREEN  — `load ptr` source, `icmp eq` against an i64 ARGUMENT.
#   (C) GUARD  — ORDERING compare on the coerced value fails loud, message
#                naming Bennett-8g7m. *If this ever goes green the model is
#                silently miscompiling.*
#   (D) GUARD  — arithmetic use (`add`) fails loud.
#   (E) GUARD  — `store` of the coerced value (escape into memory) fails loud.
#   (F) GUARD  — MIXED uses (one `icmp eq` AND one `add`) fail loud: the gate is
#                EVERY use, not SOME use.
#   (G) GUARD  — `phi ptr` source fails loud (the cc0-M2b width-0 sentinel).
#   (H) GUARD  — `select ptr` source fails loud (same).
#   (I) GUARD  — `icmp eq` against a NON-ZERO integer literal fails loud.
#   (J) GREEN  — `icmp eq` against the ZERO cell IS admitted (null, Bennett-beaw).
#   (K) GUARD  — zero uses fail loud (a use-less coercion is a surprise).
#   (L) GUARD  — `ptrtoint ptr -> i32` fails loud on the (P1) width guard.
#   (M) GREEN  — `icmp ne` is admitted too.
#   (N) INERT  — `inttoptr` is untouched: still the GENERIC iwo9 type-tag reject.
#   (O) INERT  — 583s memdata sources keep 583s's own arm and its own message.
#   (P) BYTE-ID— fixture (B) under `ptr_cells=false` still fails loud (gate off).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll,
               IRBinOp, IRICmp, IRLoad, IRExtractValue, IRInsertValue,
               ConstOperand, SSAOperand

# ---------------------------------------------------------------------------
# Hand-built `.ll` fixtures (Rule 5: hermetic, Julia-version-independent).
# Plain `ptr` (addrspace 0) — the demoted form the non-raw walker sees.
# ---------------------------------------------------------------------------

# (A) The `%L84` guard shape: a `{ptr,ptr}` MemoryRef is rebuilt with
# insertvalue, BOTH halves are extracted, the `.ptr_or_offset` half is coerced
# and compared against a captured i64 cell, and the `.mem` half goes through
# the untouched 8g7m `icmp eq ptr` path.
const JBKO_GUARD_EV = """
define i64 @guard_ev(ptr %refp, ptr %capp) {
top:
  %g0 = getelementptr {ptr, ptr}, ptr %refp, i32 0, i32 0
  %d0 = load ptr, ptr %g0
  %g1 = getelementptr {ptr, ptr}, ptr %refp, i32 0, i32 1
  %d1 = load ptr, ptr %g1
  %a0 = insertvalue {ptr, ptr} zeroinitializer, ptr %d0, 0
  %ref = insertvalue {ptr, ptr} %a0, ptr %d1, 1
  %po = extractvalue {ptr, ptr} %ref, 0
  %pm = extractvalue {ptr, ptr} %ref, 1
  %cap = load i64, ptr %capp
  %c = ptrtoint ptr %po to i64
  %e1 = icmp eq i64 %cap, %c
  %e2 = icmp eq ptr %d1, %pm
  %both = and i1 %e1, %e2
  %r = select i1 %both, i64 111, i64 222
  ret i64 %r
}
"""

# (B)/(P) `load ptr` source, sibling is an i64 FUNCTION ARGUMENT (an in-model
# cell, so (P4) admits it). Doubles as the gate-off witness.
const JBKO_GUARD_LOAD = """
define i64 @guard_load(ptr %pp, i64 %cap) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp eq i64 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (M) the `ne` spelling.
const JBKO_GUARD_NE = """
define i64 @guard_ne(ptr %pp, i64 %cap) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp ne i64 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (C) THE 8g7m HOLE — an ORDERING compare on the coerced value. `icmp ult i64`
# has no pointer-typed operand, so 8g7m's TYPE-based guard cannot see it.
const JBKO_ORDERING = """
define i64 @ordering(ptr %pp, i64 %cap) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp ult i64 %c, %cap
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (D) arithmetic on the coerced value: exposes ARENA_BASE to integer maths.
const JBKO_ARITH = """
define i64 @arith(ptr %pp) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %s = add i64 %c, 8
  ret i64 %s
}
"""

# (E) escape into memory.
const JBKO_STORE = """
define i64 @store_use(ptr %pp, ptr %out) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  store i64 %c, ptr %out
  ret i64 0
}
"""

# (F) MIXED uses — one admissible `icmp eq` AND one forbidden `add`.
const JBKO_MIXED = """
define i64 @mixed(ptr %pp, i64 %cap) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp eq i64 %cap, %c
  %s = add i64 %c, 8
  %r = select i1 %e, i64 %s, i64 222
  ret i64 %r
}
"""

# (G) THE SENTINEL HAZARD — a pointer-typed `phi` carries the cc0-M2b WIDTH-0
# sentinel. Coercing it would read an UNMATERIALISED cell (silent miscompile).
const JBKO_PHI_SRC = """
define i64 @phi_src(ptr %a, ptr %b, i1 %sel, i64 %cap) {
top:
  br i1 %sel, label %L, label %R
L:
  br label %J
R:
  br label %J
J:
  %pp = phi ptr [ %a, %L ], [ %b, %R ]
  %c = ptrtoint ptr %pp to i64
  %e = icmp eq i64 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (H) the same hazard through a pointer-typed `select`.
const JBKO_SELECT_SRC = """
define i64 @select_src(ptr %a, ptr %b, i1 %sel, i64 %cap) {
top:
  %pp = select i1 %sel, ptr %a, ptr %b
  %c = ptrtoint ptr %pp to i64
  %e = icmp eq i64 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (I) a hard-coded host address on the other side: layout-dependent by
# construction, and NOT in the image of the address->cell map.
const JBKO_LITCONST = """
define i64 @litconst(ptr %pp) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp eq i64 %c, 140737488355328
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (J) zero IS admitted: null is the zero cell (Bennett-beaw).
const JBKO_ZEROCONST = """
define i64 @zeroconst(ptr %pp) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  %e = icmp eq i64 %c, 0
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (K) a coercion with NO uses at all.
const JBKO_DEADUSE = """
define i64 @deaduse(ptr %pp) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i64
  ret i64 0
}
"""

# (L) the (P1) width guard.
const JBKO_NARROW = """
define i64 @narrow(ptr %pp, i32 %cap) {
top:
  %p = load ptr, ptr %pp
  %c = ptrtoint ptr %p to i32
  %e = icmp eq i32 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (N) `inttoptr` is untouched by jbko: still the GENERIC iwo9 reject.
const JBKO_INTTOPTR = """
define i64 @itp(i64 %x) {
top:
  %p = inttoptr i64 %x to ptr
  %c = ptrtoint ptr %p to i64
  %e = icmp eq i64 %c, %x
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# (O) 583s INERTNESS — a GenericMemory `.data` base whose only use is an
# `icmp eq`. jbko must NOT poach it: `_memdata_root(src) !== nothing`, so the
# 583s arm owns it and rejects with 583s's own (subtraction) message.
const JBKO_MEMDATA_ICMP = """
define i64 @memdata_icmp(ptr %mem, i64 %cap) {
top:
  %g = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %data = load ptr, ptr %g
  %c = ptrtoint ptr %data to i64
  %e = icmp eq i64 %cap, %c
  %r = select i1 %e, i64 111, i64 222
  ret i64 %r
}
"""

# ---------------------------------------------------------------------------
# Helpers (the test_583s_memdata_bounds.jl / test_iwo9_typetag.jl idiom).
# ---------------------------------------------------------------------------
function _jbko_extract(name, ir, entry; cells)
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

# All instructions across blocks INCLUDING terminators.
function _jbko_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# The `IRBinOp(dest, :or, <SSAOperand>, ConstOperand(0), 64)` cell identity, or
# `nothing`. Positive node-shape (Rule 4: no-throw is NOT a pass).
function _jbko_or(pir, dest::Symbol)
    for ins in _jbko_all_insts(pir)
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or && ins.width == 64 &&
           ins.op1 isa SSAOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins
        end
    end
    return nothing
end

function _jbko_icmp(pir, dest::Symbol)
    for ins in _jbko_all_insts(pir)
        ins isa IRICmp && ins.dest === dest && return ins
    end
    return nothing
end

@testset "Bennett-jbko CW-D: identity-use ptrtoint (pointer-equality guards)" begin

    # =======================================================================
    # (A) GREEN — the real `%L84` guard shape. EXACT ParsedIR pins, not
    # "didn't throw": the coercion must be a REAL SSA def (`:or` identity,
    # iwo9 consensus decision 3 — never a zero-IR const-prop), and the 8g7m
    # sibling `icmp eq ptr` must be UNTOUCHED at width 64.
    # =======================================================================
    @testset "(A) GREEN — the %L84 MemoryRef guard shape extracts" begin
        (st, pir) = _jbko_extract("guard_ev", JBKO_GUARD_EV, "guard_ev"; cells=true)
        @test st === :ok
        if st === :ok
            # the jbko emission
            oi = _jbko_or(pir, :c)
            @test oi !== nothing
            if oi !== nothing
                @test oi.op1 == SSAOperand(:po)          # the extractvalue half
                @test oi.op2 == ConstOperand(0)
                @test oi.width == 64
            end
            # the extractvalue source is the width-64 ptr field (6bu3 stamping)
            evs = [x for x in _jbko_all_insts(pir) if x isa IRExtractValue]
            @test length(evs) == 2
            po = only([x for x in evs if x.dest === :po])
            @test po.agg == SSAOperand(:ref)
            @test po.index == 0
            @test po.field_widths == [64, 64]
            # the jbko-admitted comparison
            e1 = _jbko_icmp(pir, :e1)
            @test e1 !== nothing
            if e1 !== nothing
                @test e1.predicate === :eq
                @test e1.op1 == SSAOperand(:cap)
                @test e1.op2 == SSAOperand(:c)
                @test e1.width == 64
            end
            # the 8g7m sibling — UNCHANGED, still the pointer-typed icmp path
            e2 = _jbko_icmp(pir, :e2)
            @test e2 !== nothing
            if e2 !== nothing
                @test e2.predicate === :eq
                @test e2.op1 == SSAOperand(:d1)
                @test e2.op2 == SSAOperand(:pm)
                @test e2.width == 64
            end
            # exactly ONE :or cell identity in the whole body
            @test count(x -> x isa IRBinOp && x.op === :or && x.width == 64 &&
                             x.op2 isa ConstOperand && x.op2.value == 0,
                        _jbko_all_insts(pir)) == 1
            @test pir.ret_width == 64
        end
    end

    # =======================================================================
    # (B) GREEN — a `load ptr` source, sibling an i64 ARGUMENT.
    # =======================================================================
    @testset "(B) GREEN — `load ptr` source, argument sibling" begin
        (st, pir) = _jbko_extract("guard_load", JBKO_GUARD_LOAD, "guard_load"; cells=true)
        @test st === :ok
        if st === :ok
            oi = _jbko_or(pir, :c)
            @test oi !== nothing
            if oi !== nothing
                @test oi.op1 == SSAOperand(:p)
            end
            # the source `load ptr` is the width-64 cell load (Bennett-ares)
            lp = only([x for x in _jbko_all_insts(pir) if x isa IRLoad && x.dest === :p])
            @test lp.width == 64
            e = _jbko_icmp(pir, :e)
            @test e !== nothing
            if e !== nothing
                @test e.predicate === :eq
                @test e.op2 == SSAOperand(:c)
                @test e.width == 64
            end
        end
    end

    # =======================================================================
    # (C) THE 8g7m HOLE. This is the arm's reason to exist. 8g7m's ordering
    # reject is TYPE-based, so an ungated ptrtoint would launder an
    # address-MAGNITUDE compare onto the plain integer icmp path. If this
    # testset ever goes GREEN the model is silently miscompiling.
    # =======================================================================
    @testset "(C) GUARD — ordering compare on the coerced value fails loud" begin
        (st, msg) = _jbko_extract("ordering", JBKO_ORDERING, "ordering"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
            @test occursin("Bennett-8g7m", msg)     # the rule this gate preserves
            @test occursin("icmp", msg)
        end
    end

    # =======================================================================
    # (D)-(F) escape / arithmetic / mixed uses.
    # =======================================================================
    @testset "(D) GUARD — arithmetic use fails loud" begin
        (st, msg) = _jbko_extract("arith", JBKO_ARITH, "arith"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
        end
    end

    @testset "(E) GUARD — store of the coerced value fails loud" begin
        (st, msg) = _jbko_extract("store_use", JBKO_STORE, "store_use"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
        end
    end

    @testset "(F) GUARD — MIXED uses fail loud (EVERY use, not SOME use)" begin
        (st, msg) = _jbko_extract("mixed", JBKO_MIXED, "mixed"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
        end
    end

    # =======================================================================
    # (G)/(H) THE WIDTH-0 SENTINEL HAZARD — the most important negative in
    # this file. A pointer-typed `phi` / `select` carries the Bennett-cc0 M2b
    # WIDTH-0 sentinel; its routing lives in `ptr_provenance` at LOWERING
    # time, not as a value. Emitting the `:or` identity on one would read a
    # cell that was NEVER MATERIALISED — a SILENT miscompile. A future
    # "simplify `_jbko_cell_ptr_src_kind` to `is a pointer`" refactor MUST
    # fail these two testsets.
    # =======================================================================
    @testset "(G) GUARD — `phi ptr` source fails loud (cc0-M2b width-0 sentinel)" begin
        (st, msg) = _jbko_extract("phi_src", JBKO_PHI_SRC, "phi_src"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
            @test occursin("phi", msg)              # names the SOURCE KIND
            @test occursin("width-0", msg) || occursin("Bennett-cc0", msg)
        end
    end

    @testset "(H) GUARD — `select ptr` source fails loud (same sentinel)" begin
        (st, msg) = _jbko_extract("select_src", JBKO_SELECT_SRC, "select_src"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
            @test occursin("select", msg)           # names the SOURCE KIND
        end
    end

    # =======================================================================
    # (I)/(J) the other side of the comparison.
    # =======================================================================
    @testset "(I) GUARD — non-zero integer literal on the other side fails loud" begin
        (st, msg) = _jbko_extract("litconst", JBKO_LITCONST, "litconst"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
            @test occursin("literal", msg)
        end
    end

    @testset "(J) GREEN — the ZERO cell (null, beaw) IS an admissible sibling" begin
        (st, pir) = _jbko_extract("zeroconst", JBKO_ZEROCONST, "zeroconst"; cells=true)
        @test st === :ok
        if st === :ok
            @test _jbko_or(pir, :c) !== nothing
            e = _jbko_icmp(pir, :e)
            @test e !== nothing
            if e !== nothing
                @test e.op2 == ConstOperand(0)
            end
        end
    end

    # =======================================================================
    # (K)/(L) zero uses and the width guard.
    # =======================================================================
    @testset "(K) GUARD — zero uses fail loud" begin
        (st, msg) = _jbko_extract("deaduse", JBKO_DEADUSE, "deaduse"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
        end
    end

    @testset "(L) GUARD — `ptrtoint ptr -> i32` fails loud on the width guard" begin
        (st, msg) = _jbko_extract("narrow", JBKO_NARROW, "narrow"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-jbko", msg)
            @test occursin("NON-64-bit", msg)
        end
    end

    # =======================================================================
    # (M) the `ne` spelling.
    # =======================================================================
    @testset "(M) GREEN — `icmp ne` is admitted too" begin
        (st, pir) = _jbko_extract("guard_ne", JBKO_GUARD_NE, "guard_ne"; cells=true)
        @test st === :ok
        if st === :ok
            @test _jbko_or(pir, :c) !== nothing
            e = _jbko_icmp(pir, :e)
            @test e !== nothing
            if e !== nothing
                @test e.predicate === :ne
            end
        end
    end

    # =======================================================================
    # (N)/(O) INERTNESS — jbko is `LLVMPtrToInt`-only and yields to 583s.
    # =======================================================================
    @testset "(N) INERT — `inttoptr` still hits the GENERIC iwo9 reject" begin
        (st, msg) = _jbko_extract("itp", JBKO_INTTOPTR, "itp"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("Bennett-iwo9", msg)
            @test occursin("type-tag", msg)
            @test !occursin("Bennett-jbko", msg)
        end
    end

    @testset "(O) INERT — a memdata `.data` source stays on the 583s arm" begin
        (st, msg) = _jbko_extract("memdata_icmp", JBKO_MEMDATA_ICMP,
                                  "memdata_icmp"; cells=true)
        @test st === :err
        if st === :err
            # 583s owns memdata-rooted sources (its own SUBTRACTION proof); its
            # own message must fire, NOT jbko's.
            @test occursin("Bennett-583s", msg)
            @test occursin("base-cancelling", msg)
            @test !occursin("Bennett-jbko", msg)
        end
    end

    # =======================================================================
    # (P) BYTE-IDENTITY / gate-off. The whole arm lives inside the existing
    # `&& ptr_cells` block, so with the gate OFF there is no arm at all and
    # the circuit path is byte-identical: fixture (B) walls on a ptr_cells-
    # gated construct (the `load ptr`, or the `ptrtoint` opcode itself).
    # Precedent: test_583s_memdata_bounds.jl (7).
    # =======================================================================
    @testset "(P) BYTE-IDENTITY — fixture (B) fails loud under ptr_cells=false" begin
        (st, msg) = _jbko_extract("guard_load_off", JBKO_GUARD_LOAD,
                                  "guard_load"; cells=false)
        @test st === :err
        if st === :err
            @test !occursin("Bennett-jbko", msg)
            @test occursin("ptrtoint", msg)                  ||
                  occursin("unsupported LLVM opcode", msg)   ||
                  occursin("pointer", lowercase(msg))
        end
    end

end
