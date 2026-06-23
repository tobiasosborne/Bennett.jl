# Bennett-beaw — CW-D: model `ptr null` (LLVM ConstantPointerNull) as a zero
# 64-bit VM cell under the closed-world `ptr_cells=true` gate.
#
# A null pointer is address 0 (ADR 0018 §A — a pointer is one Int64 VM cell),
# so under the C-track cell model a `ptr null` operand lowers to `iconst(0)`
# (a `ConstOperand(0)`) at the cell width 64. On the circuit path
# (`ptr_cells=false`) it stays FAIL-LOUD (the Bennett-bjdg / U80 behaviour) —
# the circuit model has no canonical zero-cell pointer semantics.
#
# This is the fdict-root successor wall past Bennett-iwo9/r92o: with the
# type-tag round-trip (iwo9) and gc_alloc_obj (r92o) modelled, the real
# `fdict_d1b` root now walls at
#   `ConstantPointerNull operand: ptr null … (Bennett-bjdg / U80)`
# from the `store ptr null, ptr %obj` field-inits in the inlined
# setindex!/getindex body.
#
# The `_operand` scalar-operand resolver gains a defaulted kwarg
# `ptr_cells::Bool=false`; only the two ptr_cells-gated call sites that can
# receive a `ptr null` (the `ret ptr %p` arm and the `store ptr %v, ptr %p`
# arm in instructions.jl) pass `ptr_cells=true`. Every other `_operand` call
# site is byte-identical (default false → the U80 fail-loud for null still
# fires).
#
# Gate map:
#   (a) ptr_cells=true: `ret ptr null` and `store ptr null` lower the null to a
#       ConstOperand(0) at width 64 (positive node-shape — Rule 4).
#   (b) ptr_cells=false: the SAME fixtures still wall at the U80
#       ConstantPointerNull fail-loud (byte-identity — the gate is off).
#   (c) FAIL-LOUD preserved: ConstantFP / Poison / Undef are NOT null pointers
#       and stay fail-loud under BOTH gates (not exercised here directly — the
#       arms are untouched; covered by Bennett-bjdg tests).
#   (d) real `fdict_d1b` root wall-ADVANCE (optimize=false, ptr_cells=true):
#       NEGATIVE (no longer the ConstantPointerNull/U80 wall) + an inclusive
#       disjunction of plausible CW-D successors. Registry snapshot/restore
#       (Rule 7 — no _known_callees leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               ParsedIR, IRStore, IRRet, ConstOperand

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). Each
# isolates `ptr null` reaching `_operand(ConstantPointerNull)` via a single
# uncluttered path.
# ---------------------------------------------------------------------------

# `ret ptr null`: the cleanest isolation. The function returns a pointer VALUE
# (one Int64 cell under ptr_cells → ret_width 64, module_walk.jl PointerType
# arm); the returned operand is the ConstantPointerNull, lowered to
# ConstOperand(0).
const RET_NULL = """
define ptr @ret_null() {
top:
  ret ptr null
}
"""

# `store ptr null, ptr %p`: the real fdict shape (field-init writing a null
# pointer into a freshly-allocated object slot). `%p` is a function arg (a
# registered SSA name), so the store-under-ptr_cells arm fires; the stored
# value is the ConstantPointerNull, lowered to ConstOperand(0) at width 64.
const STORE_NULL = """
define i64 @store_null(ptr %p) {
top:
  store ptr null, ptr %p
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

# Collect all instructions across blocks, INCLUDING terminators (IRRet is a
# block terminator, stored in `b.terminator`, not in `b.instructions`).
function _all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# Is `msg` the Bennett-bjdg / U80 ConstantPointerNull fail-loud wall?
_is_null_wall(msg) =
    occursin("ConstantPointerNull operand", msg) &&
    occursin("Bennett-bjdg / U80", msg)

@testset "Bennett-beaw ptr null → zero cell under ptr_cells" begin

    # =======================================================================
    # GATE (a) — ptr_cells=true: `ptr null` lowers to ConstOperand(0) cell.
    # Positive node-shape assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — ret ptr null lowers to ConstOperand(0) cell" begin
        (st, pir) = _extract_ll("ret_null", RET_NULL, "ret_null"; cells=true)
        @test st === :ok
        if st === :ok
            rets = filter(x -> x isa IRRet, _all_insts(pir))
            @test length(rets) == 1
            r = rets[1]
            @test r.op isa ConstOperand
            @test r.op.value == 0            # null pointer = address 0
            @test r.width == 64              # one Int64 VM cell
        end
    end

    @testset "GATE (a) — store ptr null lowers to ConstOperand(0) cell" begin
        (st, pir) = _extract_ll("store_null", STORE_NULL, "store_null"; cells=true)
        @test st === :ok
        if st === :ok
            stores = filter(x -> x isa IRStore, _all_insts(pir))
            @test length(stores) == 1
            s = stores[1]
            @test s.val isa ConstOperand
            @test s.val.value == 0           # null pointer = address 0
            @test s.width == 64              # one Int64 VM cell
        end
    end

    # =======================================================================
    # GATE (b) — ptr_cells=false: the SAME fixtures still wall at the U80
    # ConstantPointerNull fail-loud (byte-identity — the null→0 modeling is
    # gated, and the circuit path has no zero-cell pointer semantics).
    # =======================================================================
    @testset "GATE (b) — ret ptr null walls (byte-identity, U80)" begin
        # Under cells=false the `ret ptr` function-level width derivation hits
        # its own VoidType/PointerType handling, but the operand resolver path
        # for `ptr null` is the wall we pin. The extraction must fail; the
        # message is the ConstantPointerNull U80 wall OR an upstream
        # PointerType-return wall — either proves the gate is off (the null is
        # NOT silently modelled as 0 on the circuit path).
        (st, msg) = _extract_ll("ret_null_off", RET_NULL, "ret_null"; cells=false)
        @test st === :err
        if st === :err
            @test _is_null_wall(msg) ||
                  occursin("PointerType", msg) ||
                  occursin("pointer", lowercase(msg))
        end
    end

    @testset "GATE (b) — store ptr null walls (byte-identity, U80)" begin
        # The store target `%p` is a registered arg, so under cells=false the
        # store arm reaches `_operand(null)` → the U80 ConstantPointerNull wall
        # fires byte-identically (the ptr_cells store arm at 2865 is skipped, so
        # the integer-store path's `_operand(val, names)` at 2887 hits null).
        (st, msg) = _extract_ll("store_null_off", STORE_NULL, "store_null"; cells=false)
        @test st === :err
        if st === :err
            @test _is_null_wall(msg) ||
                  occursin("non-integer type", msg)   # store-of-ptr U114 wall
        end
    end

    # =======================================================================
    # GATE (d) — real fdict_d1b root wall-ADVANCE under cells=true. Pre-fix the
    # root walls at the ConstantPointerNull U80 wall (from `store ptr null`
    # field-inits); post-fix the null→0 modeling fires and a LATER wall
    # surfaces. Assert NEGATIVELY (no longer the U80 null wall) + an inclusive
    # disjunction of plausible successors (Rule 5 — order-dependent).
    # Registry snapshot/restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (d) — fdict_d1b root advances past the ptr-null U80 wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            at = Tuple{Int8,Int8}

            on_msg = try
                extract_parsed_ir(fdict_d1b, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the ConstantPointerNull U80 wall.
                @test !_is_null_wall(on_msg)
                # POSITIVE inclusive disjunction of plausible CW-D successors.
                # The next wall is the inlined setindex!/getindex body: memcpy
                # (Bennett-8bys), sret (Bennett-59zi), genericmemory, or an
                # unregistered callee. Bennett-6bu3 REMOVED the `insertvalue`
                # disjunct — the {ptr,ptr} StructType insertvalue is now
                # supported, so the root advances PAST it (the test must not pass
                # for the wrong reason by matching the now-handled insertvalue).
                @test occursin("aggregate", lowercase(on_msg))       ||
                      occursin("structtype", lowercase(on_msg))      ||
                      occursin("memcpy", lowercase(on_msg))          ||
                      occursin("genericmemory", lowercase(on_msg))   ||
                      occursin("gc_alloc_obj", lowercase(on_msg))    ||
                      occursin("ptrtoint", lowercase(on_msg))        ||
                      occursin("unsupported llvm opcode", lowercase(on_msg)) ||
                      occursin("atomic", lowercase(on_msg))          ||
                      occursin("U14", on_msg)                        ||
                      occursin("VoidType", on_msg)                   ||
                      occursin("U81", on_msg)                        ||
                      occursin("sret", lowercase(on_msg))            ||
                      occursin("U15", on_msg)                        ||
                      occursin("no registered callee", on_msg)       ||
                      occursin("closed-world", on_msg)               ||
                      occursin("PointerType", on_msg)
            end
        finally
            # No callees were intentionally added; restore exactly to `before`.
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end

        # No registry leak.
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
