# Bennett-ares — CW-D2 lever 1: VM-gated U14 atomic relaxation.
#
# Bennett-4mmt / U14 made every atomic / volatile load+store fail loud:
# reversible circuit compilation has no semantics for ordering guarantees,
# so silently coercing `load atomic` to a plain IRLoad would erase the
# source program's atomic contract (CLAUDE.md §1). That guard is CORRECT
# for the circuit path.
#
# Bennett-ares relaxes it ONLY under the existing `ptr_cells=true` gate
# (the closed-world / BennettVM cell-model path). The VM is deterministic,
# single-threaded and history-reversible: there is no concurrent observer,
# so a relaxed-consistency ordering contract is vacuous and the access can
# fall through to the EXISTING IRLoad / IRStore lowering (ptr → width 64,
# integer → width N). No new lowering is added — the guard simply stops
# throwing for the accepted band.
#
# Accepted band under the gate (LLVM AtomicOrdering enum):
#   NotAtomic(0), Unordered(1), Monotonic(2), Acquire(4), Release(5).
# Still fail-loud under the gate:
#   AcquireRelease(6), SequentiallyConsistent(7), and `volatile` (an
#   I/O-effect contract, not an ordering one — rejected under BOTH gates).
#
# Circuit path (ptr_cells=false) is BYTE-IDENTICAL: the else-arm is the
# original U14 guard verbatim (test_4mmt pins its text).
#
# Gate map (per the consensus doc, docs/design/Bennett-ares-U14-...):
#   (a) cells=true ACCEPTS unordered/monotonic/acquire LOAD + release STORE
#       as IRLoad/IRStore — assert POSITIVE node shape + width 64, not just
#       "no throw" (Rule 4).
#   (b) cells=false: SAME fixtures still fail loud with the U14 text and NO
#       VM-only suffix (byte-identity witness).
#   (c) acq_rel / seq_cst + volatile fail loud under the gate; an INTEGER
#       atomic under cells=false still walls (the integer fall-through is
#       gate-independent — locks `ptr_cells && relaxable(ord)`, not an
#       ungated relaxation).
#   (d) real setindex!(Dict{Int8,Int8},Int8,Int8) advances PAST the U14
#       atomic-load wall under cells=true (negative assertion + inclusive
#       disjunction of plausible successor walls); cells=false still hits an
#       EARLIER ptr-return wall. Registry snapshot/restore — no leak (Rule 7).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               register_callee!, ParsedIR, IRLoad, IRStore

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent — never
# depend on a particular Julia/LLVM IR shape for the positive assertions).
# Store fixtures return `i32 0` (mirrors test_4mmt) so the atomic-store U14
# guard is the first wall reached under cells=false — a `ret void` body
# would hit the VoidType width wall first and mask the byte-identity check.
# ---------------------------------------------------------------------------

# ptr-typed atomic loads across the accepted band → 64-bit cell IRLoad.
const LOAD_UNORDERED = """
define ptr @vm_load_unordered(ptr %p) {
top:
  %v = load atomic ptr, ptr %p unordered, align 8
  ret ptr %v
}
"""
const LOAD_MONOTONIC = """
define ptr @vm_load_monotonic(ptr %p) {
top:
  %v = load atomic ptr, ptr %p monotonic, align 8
  ret ptr %v
}
"""
const LOAD_ACQUIRE = """
define ptr @vm_load_acquire(ptr %p) {
top:
  %v = load atomic ptr, ptr %p acquire, align 8
  ret ptr %v
}
"""

# Integer atomic loads, returning the loaded iN. These reach the U14 LOAD
# guard FIRST under cells=false (an integer return is width-queryable, so the
# ret_width computation does not pre-empt with a ptr-return wall the way the
# ptr-returning fixtures above do). Used for the cells=false byte-identity
# check on the LOAD guard.
const INT_LOAD_UNORDERED = """
define i32 @vm_int_load_unordered(ptr %p) {
top:
  %v = load atomic i32, ptr %p unordered, align 4
  ret i32 %v
}
"""
const INT_LOAD_ACQUIRE = """
define i32 @vm_int_load_acquire(ptr %p) {
top:
  %v = load atomic i32, ptr %p acquire, align 4
  ret i32 %v
}
"""

# ptr-typed atomic store (release) → 64-bit cell IRStore.
const STORE_RELEASE = """
define i32 @vm_store_release(ptr %p, ptr %v) {
top:
  store atomic ptr %v, ptr %p release, align 8
  ret i32 0
}
"""

# integer atomic load (monotonic) — the integer fall-through arm.
const INT_LOAD_MONOTONIC = """
define i32 @vm_int_load_monotonic(ptr %p) {
top:
  %v = load atomic i32, ptr %p monotonic, align 4
  ret i32 %v
}
"""

# Strong-ordering / volatile — must STAY fail-loud under the gate.
# seq_cst is the ONLY constructible strong ordering for plain load/store:
# AcquireRelease(6) is illegal on `load atomic` / `store atomic` (LLVM rejects
# it — it is valid only on atomicrmw/cmpxchg/fence). The `_vm_relaxable_ordering`
# rejection of 6 is therefore defensive (it never reaches a load/store today);
# 7 (seq_cst) is the witness that the strong-ordering reject path fires.
const STORE_SEQ_CST = """
define i32 @vm_store_seqcst(ptr %p, ptr %v) {
top:
  store atomic ptr %v, ptr %p seq_cst, align 8
  ret i32 0
}
"""
const LOAD_SEQ_CST = """
define i32 @vm_int_load_seqcst(ptr %p) {
top:
  %v = load atomic i32, ptr %p seq_cst, align 4
  ret i32 %v
}
"""
const LOAD_VOLATILE_PTR = """
define ptr @vm_load_volatile(ptr %p) {
top:
  %v = load volatile ptr, ptr %p, align 8
  ret ptr %v
}
"""
const STORE_VOLATILE_PTR = """
define i32 @vm_store_volatile(ptr %p, ptr %v) {
top:
  store volatile ptr %v, ptr %p, align 8
  ret i32 0
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

# Collect all instructions across blocks.
_all_insts(pir) = [ins for b in pir.blocks for ins in b.instructions]

# U14 wall text substrings (per test_4mmt). The byte-identity else-arm must
# preserve these EXACTLY.
_is_u14_wall(msg, op_kw) =
    (occursin("atomic", lowercase(msg)) || occursin("volatile", lowercase(msg))) &&
    occursin(op_kw, lowercase(msg)) &&
    occursin("Bennett-4mmt / U14", msg)

@testset "Bennett-ares VM-gated U14 atomic relaxation" begin

    # =======================================================================
    # GATE (a) — cells=true ACCEPTS the relaxed band as IRLoad/IRStore.
    # Positive node-shape + width assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — cells=true accepts relaxed atomics as cell IRLoad/IRStore" begin
        # ptr atomic loads (unordered/monotonic/acquire) → IRLoad width 64.
        for (nm, ir, entry) in [
            ("load_unordered", LOAD_UNORDERED, "vm_load_unordered"),
            ("load_monotonic", LOAD_MONOTONIC, "vm_load_monotonic"),
            ("load_acquire",   LOAD_ACQUIRE,   "vm_load_acquire"),
        ]
            (st, pir) = _extract_ll(nm, ir, entry; cells=true)
            @test st === :ok
            if st === :ok
                loads = filter(x -> x isa IRLoad, _all_insts(pir))
                @test length(loads) == 1
                @test loads[1].width == 64          # one Int64 VM cell (ADR 0018 §A)
            end
        end

        # ptr atomic store (release) → IRStore width 64.
        (st, pir) = _extract_ll("store_release", STORE_RELEASE, "vm_store_release"; cells=true)
        @test st === :ok
        if st === :ok
            stores = filter(x -> x isa IRStore, _all_insts(pir))
            @test length(stores) == 1
            @test stores[1].width == 64
        end

        # integer atomic loads (unordered/monotonic/acquire) → IRLoad width 32
        # (the gate-independent integer fall-through arm — accepted only because
        # of the `ptr_cells && relaxable(ord)` predicate, NOT ungated).
        for (nm, ir, entry) in [
            ("int_load_unordered", INT_LOAD_UNORDERED, "vm_int_load_unordered"),
            ("int_load_monotonic", INT_LOAD_MONOTONIC, "vm_int_load_monotonic"),
            ("int_load_acquire",   INT_LOAD_ACQUIRE,   "vm_int_load_acquire"),
        ]
            (sti, piri) = _extract_ll(nm, ir, entry; cells=true)
            @test sti === :ok
            if sti === :ok
                loads = filter(x -> x isa IRLoad, _all_insts(piri))
                @test length(loads) == 1
                @test loads[1].width == 32
            end
        end
    end

    # =======================================================================
    # GATE (b) — cells=false: SAME fixtures still fail loud (byte-identity).
    # Same U14 text, NO VM-only suffix.
    # =======================================================================
    @testset "GATE (b) — cells=false still walls (byte-identity, U14 text, no VM suffix)" begin
        # INTEGER atomic loads + the ptr atomic STORE reach the U14 guard FIRST
        # under cells=false (their return type is width-queryable, so ret_width
        # computation does not pre-empt). These are the byte-identity witnesses
        # for the load+store guards.
        for (nm, ir, entry, op_kw) in [
            ("int_load_unordered", INT_LOAD_UNORDERED, "vm_int_load_unordered", "load"),
            ("int_load_acquire",   INT_LOAD_ACQUIRE,   "vm_int_load_acquire",   "load"),
            ("store_release",      STORE_RELEASE,      "vm_store_release",      "store"),
        ]
            (st, msg) = _extract_ll(nm, ir, entry; cells=false)
            @test st === :err
            if st === :err
                @test _is_u14_wall(msg, op_kw)
                # No VM-specific explanatory suffix leaks into the circuit-path
                # error (the suffix lives only inside the ptr_cells=true branch).
                @test !occursin("BennettVM", msg)
                @test !occursin("ptr_cells", msg)
            end
        end

        # The ptr-RETURNING atomic load fixtures wall under cells=false too, but
        # at an EARLIER ptr-return width-query wall (the ret_width computation on
        # a `ptr` return type fails before the body load guard is reached — same
        # wall lf14 documents). Still a fail-loud, and still NO VM suffix; the
        # important byte-identity guarantee (no silent coercion) holds.
        for (nm, ir, entry) in [
            ("load_unordered", LOAD_UNORDERED, "vm_load_unordered"),
            ("load_monotonic", LOAD_MONOTONIC, "vm_load_monotonic"),
            ("load_acquire",   LOAD_ACQUIRE,   "vm_load_acquire"),
        ]
            (st, msg) = _extract_ll(nm, ir, entry; cells=false)
            @test st === :err
            if st === :err
                @test occursin("unsupported LLVM type", msg) && occursin("PointerType", msg)
                @test !occursin("BennettVM", msg)
            end
        end
    end

    # =======================================================================
    # GATE (c) — strong ordering / volatile STILL fail loud under the gate;
    # integer atomic under cells=false STILL walls (gate-independent
    # fall-through ⇒ predicate must be `ptr_cells && relaxable(ord)`).
    # =======================================================================
    @testset "GATE (c) — strong-ordering + volatile fail loud under the gate" begin
        # seq_cst store + seq_cst load fail loud EVEN with cells=true (7 is
        # outside the {0,1,2,4,5} band — the band is NOT broadened).
        (sts7, msgs7) = _extract_ll("store_seqcst", STORE_SEQ_CST, "vm_store_seqcst"; cells=true)
        @test sts7 === :err
        sts7 === :err && @test _is_u14_wall(msgs7, "store")

        (stl7, msgl7) = _extract_ll("load_seqcst", LOAD_SEQ_CST, "vm_int_load_seqcst"; cells=true)
        @test stl7 === :err
        stl7 === :err && @test _is_u14_wall(msgl7, "load")

        # volatile load/store fail loud EVEN with cells=true.
        (stl, msgl) = _extract_ll("load_volatile", LOAD_VOLATILE_PTR, "vm_load_volatile"; cells=true)
        @test stl === :err
        stl === :err && @test _is_u14_wall(msgl, "load")

        (sts, msgs) = _extract_ll("store_volatile", STORE_VOLATILE_PTR, "vm_store_volatile"; cells=true)
        @test sts === :err
        sts === :err && @test _is_u14_wall(msgs, "store")

        # Integer atomic load under cells=false STILL walls (the integer
        # IRLoad fall-through is gate-INDEPENDENT; an ungated relaxation would
        # change circuit-path integer-atomic behavior — byte-identity).
        (sti, msgi) = _extract_ll("int_load_mono_off", INT_LOAD_MONOTONIC, "vm_int_load_monotonic"; cells=false)
        @test sti === :err
        sti === :err && @test _is_u14_wall(msgi, "load")
    end

    # =======================================================================
    # GATE (d) — real setindex! advances PAST the U14 atomic-load wall under
    # cells=true. setindex!(Dict{Int8,Int8},Int8,Int8) emits `load atomic ptr
    # … unordered`; pre-fix it walls at U14 (lf14 GATE-B observed this for
    # rehash!). Post-fix the relaxed load falls through and a LATER wall
    # surfaces. Assert NEGATIVELY (no longer the U14 atomic-load wall) plus an
    # inclusive disjunction of plausible successors (Rule 5 — order-dependent).
    # cells=false still hits the EARLIER ptr-return wall.
    # Registry snapshot/restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (d) — setindex! advances past the U14 atomic-load wall under cells" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        added = String[]
        try
            register_callee!(setindex!)
            push!(added, string(nameof(setindex!)))

            at = Tuple{Dict{Int8,Int8},Int8,Int8}

            # cells=true: the U14 atomic-load wall must be GONE. Either it
            # extracts, or it advances to a DIFFERENT (later) wall.
            on_msg = try
                extract_parsed_ir(setindex!, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the atomic-LOAD U14 wall.
                @test !(occursin("atomic load", lowercase(on_msg)) &&
                        occursin("Bennett-4mmt / U14", on_msg))
                # POSITIVE disjunction: one of the plausible CW-D successors.
                # OBSERVED (2026-06-19, optimize=false, this machine): the next
                # wall is `insertvalue on StructType aggregates` — the `{ ptr,
                # ptr }` memoryref aggregate that setindex! builds after the
                # atomic load. (Rule 5: order-dependent — keep the disjunction
                # inclusive of all plausible successors so an IR shuffle does
                # not falsely red this wall-advance proof.)
                # Bennett-6bu3: insertvalue on {ptr,ptr} StructType bodies is now
                # SUPPORTED in the extractor, so setindex! advances PAST the old
                # insertvalue wall to the `ptrtoint ptr %memory_data to i64`
                # GenericMemory data-pointer wall (Bennett-iwo9 / CW-D3 Lever 1).
                # Added ptrtoint / iwo9 / type-tag disjuncts for the new successor;
                # existing disjuncts kept (harmless under Rule 5).
                @test occursin("ptrtoint", lowercase(on_msg))             ||  # Bennett-6bu3: new iwo9 successor
                      occursin("iwo9", lowercase(on_msg))                 ||  # Bennett-6bu3
                      occursin("type-tag", lowercase(on_msg))             ||  # Bennett-6bu3
                      occursin("insertvalue", lowercase(on_msg))          ||
                      occursin("aggregate", lowercase(on_msg))            ||
                      occursin("structtype", lowercase(on_msg))           ||
                      occursin("fence", lowercase(on_msg))                ||
                      occursin("atomic store", lowercase(on_msg))         ||  # release store is the next U14 site
                      occursin("inline", lowercase(on_msg))               ||
                      occursin("U15", on_msg)                             ||
                      occursin("pgcstack", lowercase(on_msg))             ||
                      occursin("sret", lowercase(on_msg))                 ||
                      occursin("memcpy", lowercase(on_msg))               ||
                      occursin("genericmemory", lowercase(on_msg))        ||
                      occursin("VoidType", on_msg)                        ||
                      occursin("U81", on_msg)                             ||
                      occursin("closed-world", on_msg)                    ||
                      occursin("PointerType", on_msg)
            end

            # cells=false: still the EARLIER ptr-return PointerType wall
            # (lf14 GATE-B: ret_width query on a ptr return fails before the
            # body atomic-load guard is reached).
            off_msg = try
                extract_parsed_ir(setindex!, at; optimize=false, ptr_cells=false)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test off_msg !== nothing
            off_msg !== nothing && @test occursin("unsupported LLVM type", off_msg) &&
                                         occursin("PointerType", off_msg)
        finally
            lock(Bennett._known_callees_lock) do
                for k in added
                    if haskey(before, k)
                        Bennett._known_callees[k] = before[k]
                    else
                        delete!(Bennett._known_callees, k)
                    end
                end
            end
        end

        # No registry leak.
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
