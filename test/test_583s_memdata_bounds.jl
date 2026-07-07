# Bennett-583s / CW-D — admit `ptrtoint ptr %memory_data to i64` (the Julia
# GenericMemory `.data` base pointer) as a width-64 cell identity
# `IRBinOp(dest, :or, <src>, iconst(0), 64)` under the closed-world
# `ptr_cells=true` gate — BUT ONLY when it is confined to a same-Memory-root,
# base-cancelling bounds check
#
#     %b = ptrtoint ptr %data_base                 ; both trace to the SAME
#     %e = ptrtoint ptr (getelementptr i8 %data_base, %off)  ;   Memory `.data` root
#     %d = sub i64 %e, %b                          ; base cancels → %d == %off
#     %c = icmp ult i64 %d, %len                   ; a dead @boundscheck throw
#
# Soundness (ADR 0017 CW-D; established, not re-litigated): the base cancels in
# `sub(ptrtoint(base+off), ptrtoint(base)) = off`, so the net effect is
# base-INDEPENDENT → matches the native oracle. Admitting a base-DEPENDENT
# value (different Memory roots, or an ESCAPING address — inttoptr-back-to-deref,
# store-of-int, hash, cross-allocation difference) would break oracle-match
# (the bennettvm-90l hazard), so the same-root gate is the SOLE soundness
# boundary: every OTHER ptrtoint of a `.data` base stays FAIL-LOUD (CLAUDE.md §1).
#
# The extractor walks NON-RAW IR (entry.jl → code_llvm(...; raw=false)): 0
# addrspacecast, GEPs are plain `getelementptr {i64,ptr}, ptr %mem, i32 0, i32 1`.
# All fixtures below therefore use plain `ptr` (addrspace 0).
#
# Gate map:
#   (1) GREEN   — a same-Memory base-cancelling cluster extracts under
#                 ptr_cells=true; each ptrtoint lowers to the :or cell identity;
#                 the sub / icmp survive.
#   (2) GUARD   — an ESCAPING ptrtoint (hash / inttoptr-deref) fails loud.
#   (3) GUARD   — a NON-64-bit-width ptrtoint of a `.data` base fails loud.
#   (4) GUARD   — a non-memdata ptrtoint (plain arg pointer) falls to the iwo9
#                 wall (`_memdata_root === nothing`).
#   (5) GUARD   — a cross-Memory difference (roots differ) fails loud.
#   (6) REAL    — `Base.setindex!` wall-ADVANCE: suite mode (--check-bounds=yes)
#                 no longer walls at the memdata ptrtoint; default mode already
#                 extracts past it (byte-identity — 0 ptrtoint there).
#   (7) BYTE-ID — fixture (1) with ptr_cells=false still fails loud (gate off);
#                 a seed `.data` load with NO ptrtoint lowers to IRLoad(_,_,64).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRBinOp, IRICmp, IRLoad, ConstOperand, SSAOperand

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Plain `ptr`
# (addrspace 0) — the demoted form the non-raw walker sees.
# ---------------------------------------------------------------------------

# (1) The base-cancelling bounds cluster: `%pbase` and `%pelem` both trace to the
# SAME `{i64,ptr}` field-1 (`.data`) load off `%mem`; `%d = sub(%e,%b)` cancels
# the base, `%c = icmp ult %d, %len` is the (dead) @boundscheck.
const CLUSTER_OK = """
define i64 @f(ptr %mem, i64 %off, i64 %len) {
top:
  %pbase_gep = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %pbase = load ptr, ptr %pbase_gep
  %pelem_gep = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %pelem_base = load ptr, ptr %pelem_gep
  %pelem = getelementptr i8, ptr %pelem_base, i64 %off
  %b = ptrtoint ptr %pbase to i64
  %e = ptrtoint ptr %pelem to i64
  %d = sub i64 %e, %b
  %c = icmp ult i64 %d, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %d
oob:
  ret i64 0
}
"""

# (2a) ESCAPE — hash: the `.data` base ptrtoint feeds an `add` (a base-DEPENDENT
# integer), not a same-root sub. Base-dependent → forbidden.
const ESCAPE_HASH = """
define i64 @g(ptr %mem) {
top:
  %g = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %data = load ptr, ptr %g
  %pd = ptrtoint ptr %data to i64
  %h = add i64 %pd, 12345
  ret i64 %h
}
"""

# (2b) ESCAPE — inttoptr-back-to-deref: the ptrtoint result is cast BACK to a
# pointer and dereferenced. A genuine address escape.
const ESCAPE_DEREF = """
define i8 @g2(ptr %mem) {
top:
  %g = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %data = load ptr, ptr %g
  %pd = ptrtoint ptr %data to i64
  %bp = inttoptr i64 %pd to ptr
  %v = load i8, ptr %bp
  ret i8 %v
}
"""

# (3) WIDTH — a `.data` base cast to i32 (NOT the 64-bit cell round-trip):
# genuine pointer arithmetic that truncates the Int64 cell.
const WIDTH_I32 = """
define i32 @f3(ptr %mem) {
top:
  %g = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %data = load ptr, ptr %g
  %d = ptrtoint ptr %data to i32
  ret i32 %d
}
"""

# (4) NON-MEMDATA — a plain function-arg pointer (NOT a `{i64,ptr}` field-1
# load) → `_memdata_root === nothing` → falls to the iwo9 wall.
const NON_MEMDATA = """
define i64 @f4(ptr %p) {
top:
  %d = ptrtoint ptr %p to i64
  ret i64 %d
}
"""

# (5) CROSS-MEMORY — `sub(ptrtoint(dataB+off), ptrtoint(dataA))`: the two
# ptrtoints trace to DIFFERENT Memory roots (%memA vs %memB), so the base does
# NOT cancel — a base-dependent difference. Roots differ → gate false.
const CROSS_MEM = """
define i64 @f5(ptr %memA, ptr %memB, i64 %off) {
top:
  %ga = getelementptr {i64, ptr}, ptr %memA, i32 0, i32 1
  %dataA = load ptr, ptr %ga
  %gb = getelementptr {i64, ptr}, ptr %memB, i32 0, i32 1
  %dataB_base = load ptr, ptr %gb
  %dataB = getelementptr i8, ptr %dataB_base, i64 %off
  %b = ptrtoint ptr %dataA to i64
  %e = ptrtoint ptr %dataB to i64
  %d = sub i64 %e, %b
  ret i64 %d
}
"""

# (7-seed) INERTNESS — a `.data` load with NO ptrtoint: the new arm must not
# perturb it (the load still lowers to the 64-bit cell IRLoad).
const SEED_NO_PTRTOINT = """
define i64 @seed(ptr %mem) {
top:
  %g = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %data = load ptr, ptr %g
  ret i64 0
}
"""

# ---------------------------------------------------------------------------
# Helpers (modeled on test_beaw_null_ptr.jl / test_iwo9_typetag.jl).
# ---------------------------------------------------------------------------
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

# All instructions across blocks INCLUDING terminators (IRRet/IRBranch live in
# `b.terminator`, not `b.instructions`).
function _all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# The `IRBinOp(dest, :or, <SSAOperand>, ConstOperand(0), 64)` cell identity for a
# ptrtoint dest, or `nothing`. Positive node-shape (Rule 4: no-throw ≠ pass).
function _memdata_or(pir, dest::Symbol)
    for ins in _all_insts(pir)
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or && ins.width == 64 &&
           ins.op1 isa SSAOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins
        end
    end
    return nothing
end

@testset "Bennett-583s CW-D: memdata `.data` ptrtoint cell identity (bounds-check-confined)" begin

    # =======================================================================
    # (1) GREEN — the same-Memory base-cancelling cluster extracts; each
    # ptrtoint lowers to the :or cell identity; the sub / icmp survive.
    # =======================================================================
    @testset "(1) GREEN — base-cancelling cluster extracts under ptr_cells" begin
        (st, pir) = _extract_ll("cluster_ok", CLUSTER_OK, "f"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts(pir)
            # Both `.data`-base ptrtoints lower to the width-64 :or identity, each
            # binding its source SSA (real SSA def — not a const-prop).
            b = _memdata_or(pir, :b)
            e = _memdata_or(pir, :e)
            @test b !== nothing
            @test e !== nothing
            if b !== nothing
                @test b.op1.name === :pbase
            end
            if e !== nothing
                @test e.op1.name === :pelem
            end
            # The base-cancelling sub survives.
            subs = filter(x -> x isa IRBinOp && x.dest === :d && x.op === :sub &&
                               x.width == 64, insts)
            @test length(subs) == 1
            # The dead @boundscheck icmp survives.
            cmps = filter(x -> x isa IRICmp && x.dest === :c, insts)
            @test length(cmps) == 1
        end
    end

    # =======================================================================
    # (2) GUARD — an ESCAPING ptrtoint of a `.data` base fails loud: (2a) hash
    # (base-dependent add), (2b) inttoptr-back-to-deref.
    # =======================================================================
    @testset "(2a) GUARD — hash of a `.data` base fails loud" begin
        (st, msg) = _extract_ll("escape_hash", ESCAPE_HASH, "g"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("583s", msg)
            @test occursin("bounds", msg) || occursin("escap", msg) ||
                  occursin("base-", msg)
        end
    end

    @testset "(2b) GUARD — inttoptr-back-to-deref fails loud" begin
        (st, msg) = _extract_ll("escape_deref", ESCAPE_DEREF, "g2"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("583s", msg)
            @test occursin("bounds", msg) || occursin("escap", msg) ||
                  occursin("base-", msg)
        end
    end

    # =======================================================================
    # (3) GUARD — a `.data` base cast to a NON-64-bit width fails loud (the
    # width guard: only the 64-bit cell round-trip is a cell identity).
    # =======================================================================
    @testset "(3) GUARD — `.data` ptrtoint to i32 fails loud (width guard)" begin
        (st, msg) = _extract_ll("width_i32", WIDTH_I32, "f3"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("583s", msg)
            @test occursin("width", msg) || occursin("64", msg)
        end
    end

    # =======================================================================
    # (4) GUARD — a non-memdata ptrtoint (plain arg pointer) falls to the iwo9
    # wall (`_memdata_root === nothing`, so the 583s arm never fires).
    # =======================================================================
    @testset "(4) GUARD — non-memdata ptrtoint falls to the iwo9 wall" begin
        (st, msg) = _extract_ll("non_memdata", NON_MEMDATA, "f4"; cells=true)
        @test st === :err
        if st === :err
            # The 583s arm is skipped (src is an Argument, not a `.data` load);
            # the pre-existing iwo9 fail-loud fires.
            @test occursin("iwo9", msg) || occursin("ptrtoint", msg)
        end
    end

    # =======================================================================
    # (5) GUARD — a cross-Memory difference (roots differ) fails loud — the
    # option-(a)-over-(b) discriminator: the same-root gate rejects a
    # base-DEPENDENT diff even though both operands are `.data` ptrtoints.
    # =======================================================================
    @testset "(5) GUARD — cross-Memory difference fails loud" begin
        (st, msg) = _extract_ll("cross_mem", CROSS_MEM, "f5"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("583s", msg)
            @test occursin("bounds", msg) || occursin("escap", msg) ||
                  occursin("base-", msg)
        end
    end

    # =======================================================================
    # (6) REAL-TARGET WALL-ADVANCE — `Base.setindex!(Dict{Int8,Int8}, v, k)`.
    # Suite mode (--check-bounds=yes) is where the memory_data ptrtoint appears;
    # default mode already extracts past it (0 ptrtoint — byte-identity). Guard
    # on `Base.JLOptions().check_bounds == 1`. Registry snapshot/restore
    # (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "(6) REAL — setindex! advances past the memdata ptrtoint wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Dict{Int8,Int8},Int8,Int8}
            msg = try
                extract_parsed_ir(Base.setindex!, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            suite_mode = Base.JLOptions().check_bounds == 1
            if !suite_mode
                # Default check-bounds: 0 ptrtoint; the target already extracts
                # past this point → the memdata ptrtoint wall must NOT be the wall.
                if msg === nothing
                    @test true
                else
                    lc = lowercase(msg)
                    @test !(occursin("ptrtoint", lc) && occursin("memory_data", lc))
                end
            else
                # Suite mode: the memdata ptrtoint is the pre-fix wall. Post-fix it
                # is cleared → a LATER wall (or full extraction).
                if msg === nothing
                    @test true  # fully extracted — stronger than wall-advance
                else
                    lc = lowercase(msg)
                    # LOAD-BEARING NEGATIVE: no longer the memdata ptrtoint wall.
                    @test !(occursin("ptrtoint", lc) && occursin("memory_data", lc))
                    # POSITIVE inclusive disjunction of plausible CW-D successors
                    # (the oob/idxend blocks: gc_loaded / bounds_error /
                    # unreachable / gc_alloc_obj / a store / no-registered-callee).
                    @test occursin("gc_loaded", lc)            ||
                          occursin("gc_alloc", lc)             ||
                          occursin("bounds_error", lc)         ||
                          occursin("unreachable", lc)          ||
                          occursin("no registered callee", lc) ||
                          occursin("closed-world", lc)         ||
                          occursin("memcpy", lc)               ||
                          occursin("store", lc)                ||
                          occursin("pointertype", lc)
                end
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

    # =======================================================================
    # (7) BYTE-IDENTITY / gate-off. Fixture (1) with ptr_cells=false still fails
    # loud (the new arm lives entirely inside the `&& ptr_cells` block, so the
    # circuit path is byte-identical — it walls on the pre-existing ptr_cells-
    # gated construct: the two-index struct GEP / ptrtoint). And a seed `.data`
    # load with NO ptrtoint under ptr_cells=true still lowers to IRLoad(_,_,64).
    # =======================================================================
    @testset "(7) BYTE-IDENTITY — cluster fails loud under ptr_cells=false" begin
        (st, msg) = _extract_ll("cluster_off", CLUSTER_OK, "f"; cells=false)
        @test st === :err
        if st === :err
            # A ptr_cells-gated wall (struct-GEP U16 / qal5, or the ptrtoint
            # opcode) — either proves the gate is OFF (nothing silently modelled).
            @test occursin("ptrtoint", msg)                    ||
                  occursin("getelementptr", lowercase(msg))    ||
                  occursin("U16", msg)                         ||
                  occursin("qal5", msg)                        ||
                  occursin("unsupported LLVM opcode", msg)
        end
    end

    @testset "(7) INERTNESS — seed `.data` load unchanged (IRLoad width 64)" begin
        (st, pir) = _extract_ll("seed", SEED_NO_PTRTOINT, "seed"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts(pir)
            # The `.data` load still lowers to the 64-bit cell IRLoad.
            @test any(x -> x isa IRLoad && x.width == 64, insts)
            # No spurious :or cell identity (there is no ptrtoint in the fixture).
            @test _memdata_or(pir, :data) === nothing
        end
    end

end
