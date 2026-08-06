# Bennett-vau9 / CW-D (ADR 0017 CW-D workstream) — memmove routing.
#
# Under the closed-world `ptr_cells` gate an
#   `llvm.memmove.p0.p0.i64(dst, src, nbytes, i1 false)`
# routes to
#   IRCall(dest, :memmove, [dst_cell, src_cell, nbytes], [64,64,64], 64)
# instead of the unconditional "memmove is not yet lowered" reject. This reuses
# BennettVM's overlap-safe `IntrinsicMemmove` (`:memmove` ∈ `_HEAP_DISPATCH`,
# `src/ir/ingest_call.jl:171`; `forward` snapshots the whole src range BEFORE
# writing dest — `src/ir/intrinsics_bulk.jl:105-135` — and the L2 dest-range
# delta reverses it). Unblocks the `_growend!` grow-copy, wall 4 of the
# `bennettvm-xkl` push!-Vector chain.
#
# This is the MEMMOVE SIBLING of the ratified Bennett-8bys variable-size-memset
# D5b void-call routing (`test_8bys_variable_memset.jl`), and deliberately
# mirrors that file's structure. Two design differences, both pinned below:
#
#   * TWO SSA pointer operands (dst AND src), both required to resolve to
#     `SSAOperand` — `IntrinsicMemmove` takes two `Symbol` pointer names.
#   * NO legacy const-N unroll to preserve. memmove has ALWAYS failed loud, so
#     the WHOLE arm is gated on `ptr_cells` and a CONST byte count routes
#     through the SAME `IRCall` — testset (b) pins that it is an IRCall and NOT
#     an unroll. (Contrast 8bys testset (b), which pins the opposite for
#     memset, whose const-N unroll predates the gate.)
#
# Design invariants pinned here:
#   (a) GREEN routing  — memmove under ptr_cells=true → exactly one bare
#       IRCall(:memmove), args=[SSA dst, SSA src, nbytes], arg_widths
#       [64,64,64], ret_width=64 (the D5b void-call dest sentinel), NO unroll.
#       nbytes is passed as a BYTE count (BVM's `_cell_count` divides by 8).
#   (b) const-N ALSO routes (no unroll, no fail-loud).
#   (c) gate-off fail loud — under ptr_cells=false the legacy reject stands for
#       every shape, with the legacy substrings intact.
#   (d) volatile memmove STILL fails loud under ptr_cells=true (Rule 1).
#   (e) non-p0 address space fails loud (predicate 1, mirrors memcpy).
#   (f) malformed arity (3-arg intrinsic decl) fails loud, not a BoundsError.
#   (g) real-target advance — the push! closed-world set no longer walls at
#       memmove; it advances to the Bennett-iwo9 ptrtoint-equality wall.
#
# HONEST SCOPE BOUNDARY: routing is EXTRACTION-side. Downstream, BVM's
# `_enforce_julia_heap_tier!` fails loud on an `IntrinsicMemmove` in a
# JULIA-tier program (byte-granular `gc_alloc_obj` /
# `jl_alloc_genericmemory_unchecked` cells) — the `÷8` span would copy an
# eighth of the byte range; bead `bennettvm-rxgy` tracks the byte-exact
# `IntrinsicMemmoveBytes`. So the real `_growend!` copy will meet that wall at
# `lower_vm` once its remaining EXTRACTION walls clear. The cross-repo E2E
# (`../BennettVM.jl/test/test_vau9_memmove_vm.jl`) proves the mechanism on the
# C/word tier, where it is fully modelled.

using Test
using Bennett

const _FVAU9      = joinpath(@__DIR__, "fixtures", "ll", "vau9_memmove_var_n.ll")
const _FVAU9_AR3  = joinpath(@__DIR__, "fixtures", "ll", "vau9_memmove_malformed_arity.ll")
# The Bennett-37mt reject fixture: alloca-i8 src/dst, CONST N=8, i8 return.
# It reaches the memmove arm in BOTH gate modes, so it is the correct fixture
# for the gate-off proof — and exercising the SAME instruction under
# ptr_cells=true directly demonstrates that the gate genuinely gates.
const _F37MT_MM   = joinpath(@__DIR__, "fixtures", "ll", "37mt_memmove_reject.ll")

_vau9_insts(path, entry; ptr_cells=false) = begin
    parsed = Bennett.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=ptr_cells)
    vcat([blk.instructions for blk in parsed.blocks]...)
end

_vau9_msg(path, entry; ptr_cells=false) = begin
    try
        Bennett.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=ptr_cells)
        ""
    catch e
        e isa InterruptException && rethrow()
        sprint(showerror, e)
    end
end

# The closed-world advancement target: the real `push!` chain, whose
# `_growend!` slow path is outlined into a closure (Bennett-40ys) that copies
# the old elements into the grown buffer with `llvm.memmove.p0.p0.i64`.
function _pushvau9(n::Int64)
    v = Int64[]
    push!(v, n)
    return length(v)
end

@testset "Bennett-vau9: memmove routing under ptr_cells" begin

    # ======================================================================
    # (a) GREEN — variable-N memmove under ptr_cells=true → IRCall(:memmove)
    # ======================================================================
    @testset "(a) variable-N memmove → IRCall(:memmove)" begin
        all_insts = _vau9_insts(_FVAU9, "memmove_var_n"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memmove, all_insts)
        @test length(calls) == 1
        c = calls[1]
        @test c.callee === :memmove
        @test length(c.args) == 3
        @test c.args[1] isa Bennett.SSAOperand          # dst cell
        @test c.args[1].name === :d
        @test c.args[2] isa Bennett.SSAOperand          # src cell — NOT dropped
        @test c.args[2].name === :s
        @test c.args[3] isa Bennett.SSAOperand          # nbytes (variable SSA)
        @test c.args[3].name === :n
        @test c.arg_widths == [64, 64, 64]
        @test c.ret_width == 64                         # D5b void sentinel
        # NO unroll: no byte-granular IRPtrOffset / IRLoad / IRStore pairs.
        @test !any(i -> i isa Bennett.IRPtrOffset, all_insts)
        @test !any(i -> i isa Bennett.IRLoad, all_insts)
        @test !any(i -> i isa Bennett.IRStore, all_insts)
        # ... and exactly one instruction in total (the IRCall).
        @test length(all_insts) == 1
    end

    @testset "(a) dst and src are DISTINCT operands, in LLVM argument order" begin
        # A transposed (src, dst) emission would silently miscopy on the VM and
        # is invisible to a shape-only assertion — pin the ORDER explicitly
        # against the fixture's `memmove(ptr %d, ptr %s, i64 %n)`.
        c = only(filter(i -> i isa Bennett.IRCall && i.callee === :memmove,
                        _vau9_insts(_FVAU9, "memmove_var_n"; ptr_cells=true)))
        @test c.args[1] != c.args[2]
        @test (c.args[1].name, c.args[2].name) == (:d, :s)
    end

    # ======================================================================
    # (b) const-N ALSO routes — no unroll, no fail-loud (the memset contrast)
    # ======================================================================
    @testset "(b) const-N memmove ALSO routes to IRCall(:memmove), NOT an unroll" begin
        all_insts = _vau9_insts(_FVAU9, "memmove_const_n"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memmove, all_insts)
        @test length(calls) == 1
        c = calls[1]
        @test c.args[1] isa Bennett.SSAOperand
        @test c.args[2] isa Bennett.SSAOperand
        # The byte count arrives as a CONSTANT — BVM's `_cell_count` resolves an
        # Int64 `nbytes_operand` exactly as it resolves a Symbol.
        @test c.args[3] isa Bennett.ConstOperand
        @test c.args[3].value == 16                     # BYTES, not cells
        @test c.arg_widths == [64, 64, 64]
        @test c.ret_width == 64
        @test !any(i -> i isa Bennett.IRPtrOffset, all_insts)
        @test !any(i -> i isa Bennett.IRLoad, all_insts)
        @test !any(i -> i isa Bennett.IRStore, all_insts)
    end

    # ======================================================================
    # (c) gate-off fail loud — and the SAME instruction routes when gated on
    # ======================================================================
    @testset "(c) ptr_cells=false: memmove still fails loud (legacy message)" begin
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            _F37MT_MM; entry_function="memmove_user", ptr_cells=false)
        msg = _vau9_msg(_F37MT_MM, "memmove_user"; ptr_cells=false)
        # The legacy substrings the pre-vau9 neighbours pin
        # (test_lqif_memcpy_memmove_reject.jl, test_37mt_memcpy_const_aligned.jl)
        # are all still present — the circuit path is unchanged.
        @test occursin("memmove is not yet lowered to reversible gates", msg)
        @test occursin("Bennett-37mt", msg)
        @test occursin("Bennett-8bys", msg)
        @test occursin("memmove", msg)
        # ... plus the ONE deliberate addition: the message now names the gate
        # and the bead that routes it, so a future agent hitting this reject is
        # pointed at `ptr_cells` rather than at a stale "deferred" note.
        @test occursin("Bennett-vau9", msg)
        @test occursin("ptr_cells", msg)
    end

    @testset "(c) the gate genuinely gates: SAME fixture routes under ptr_cells=true" begin
        # Identical `.ll`, identical instruction — only the gate differs.
        all_insts = _vau9_insts(_F37MT_MM, "memmove_user"; ptr_cells=true)
        calls = filter(i -> i isa Bennett.IRCall && i.callee === :memmove, all_insts)
        @test length(calls) == 1
        c = calls[1]
        @test c.args[1] isa Bennett.SSAOperand && c.args[1].name === :dst
        @test c.args[2] isa Bennett.SSAOperand && c.args[2].name === :src
        @test c.args[3] == Bennett.ConstOperand(8)
        @test c.arg_widths == [64, 64, 64] && c.ret_width == 64
        # Alloca-rooted pointers resolve to plain SSA cells under the gate — no
        # byte-granular expansion of the memmove itself.
        @test count(i -> i isa Bennett.IRAlloca, all_insts) == 2
        @test !any(i -> i isa Bennett.IRPtrOffset, all_insts)
    end

    # ======================================================================
    # (d) volatile fails loud under ptr_cells=true (Rule 1)
    # ======================================================================
    @testset "(d) volatile memmove fails loud under ptr_cells=true (Rule 1)" begin
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            _FVAU9; entry_function="memmove_var_n_volatile", ptr_cells=true)
        msg = _vau9_msg(_FVAU9, "memmove_var_n_volatile"; ptr_cells=true)
        @test occursin("volatile", msg)
        @test occursin("Bennett-vau9", msg)
        # It must NOT fall through to the generic legacy reject: the volatile
        # predicate is what fired, and the diagnostic must say so.
        @test !occursin("no alias analysis", msg)
    end

    # ======================================================================
    # (e) non-p0 address space fails loud (predicate 1)
    # ======================================================================
    @testset "(e) non-p0 addrspace memmove fails loud under ptr_cells=true" begin
        @test_throws ErrorException Bennett.extract_parsed_ir_from_ll(
            _FVAU9; entry_function="memmove_p1_dst", ptr_cells=true)
        msg = _vau9_msg(_FVAU9, "memmove_p1_dst"; ptr_cells=true)
        @test occursin("address space", msg)
        @test occursin("Bennett-vau9", msg)
        @test occursin("llvm.memmove.p1.p0.i64", msg)
        # No IRCall was emitted for a cross-space move.
        @test !occursin("IntrinsicMemmove", msg)
    end

    # ======================================================================
    # (f) malformed arity fails loud — a legible error, not a BoundsError
    # ======================================================================
    @testset "(f) malformed 3-arg memmove fails loud, not a BoundsError" begin
        e = try
            Bennett.extract_parsed_ir_from_ll(_FVAU9_AR3;
                entry_function="memmove_arity3", ptr_cells=true)
            nothing
        catch err
            err
        end
        @test e !== nothing
        @test !(e isa BoundsError)          # the guard, not an ops[4] crash
        @test e isa ErrorException
        msg = sprint(showerror, e)
        @test occursin("malformed memmove call", msg)
        @test occursin("got 3 args", msg)
        @test occursin("Bennett-vau9", msg)
    end

    # ======================================================================
    # (g) THE ADVANCEMENT PIN — the push! closed-world set walks PAST memmove
    #     and lands on the Bennett-583s `%idxend41` ptrtoint wall.
    #
    #     Version-observational (the test_lf14 / test_40ys wall-marker
    #     convention). When the NEXT bead lands this goes RED — that is the
    #     signal to ADVANCE the assertion, not to delete it.
    #
    #     ADVANCED by Bennett-jbko (2026-08-04): this testset DID go red on
    #     landing — it was the only one of the three push!-set wall markers
    #     whose landing disjunction did NOT already admit lgzx/U114, so it is
    #     the one that actually tracked. The `%L84`
    #     `ptrtoint ptr %.ref.ptr_or_offset to i64` is the `MemoryRef`
    #     concurrent-mutation guard and is now ADMITTED as a use-scoped
    #     width-64 cell identity.
    #
    #     ADVANCED AGAIN by Bennett-p06b (2026-08-06): the `%L93` LIVE
    #     whole-struct `store { ptr, ptr }` (the `MemoryRef` write-back) is now
    #     DECOMPOSED into per-field cell stores, so the lgzx / U114 disjunct is
    #     GONE too. MEASURED: the closure now dies in `%idxend41` on
    #     `ptrtoint ptr %memory_data53 to i64` — a GenericMemory `.data`-base
    #     coercion whose root `_memdata_root` does not recognise, i.e.
    #     Bennett-583s, tracked as bead Bennett-foz5 (xkl wall 7).
    #
    #     NOTE ON THE NEGATIVES (Bennett-0ncn): the blanket
    #     `!occursin("ptrtoint", msg)` that jbko added is RETIRED — the
    #     SUCCESSOR wall message itself contains the word `ptrtoint`, so an
    #     opcode-scoped negative is no longer expressible. It is replaced by
    #     ARM-scoped negatives (`Bennett-iwo9`, `type-tag`), which are what
    #     jbko actually cleared, plus the NEW load-bearing p06b negatives.
    # ======================================================================
    @testset "(g) push! set advances PAST memmove to the 583s ptrtoint wall" begin
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            e = try
                Bennett.extract_parsed_ir_set_from_julia(_pushvau9, Tuple{Int64};
                                                         ptr_cells=true)
                nothing
            catch err
                err isa InterruptException && rethrow()
                err
            end
            if e === nothing
                @test true   # fully extracted — stronger than wall-advance
            else
                msg = e isa ErrorException ? e.msg : sprint(showerror, e)
                # LOAD-BEARING NEGATIVE: the memmove wall is CLEARED. Without
                # this the disjunction below would not notice a re-open.
                @test !occursin("memmove", msg)
                @test !occursin("not yet lowered to reversible gates", msg)
                # LOAD-BEARING NEGATIVE: the `%L84` ptrtoint wall is CLEARED
                # by Bennett-jbko. NARROWED from the blanket
                # `!occursin("ptrtoint")` because the SUCCESSOR wall is ITSELF
                # a ptrtoint reject — scope the negative to the ARM that was
                # cleared, not to the opcode (the Bennett-0ncn lesson).
                @test !occursin("Bennett-iwo9", msg)
                @test !occursin("type-tag", msg)
                # LOAD-BEARING NEGATIVE: the `%L93` whole-struct store wall is
                # CLEARED by Bennett-p06b. These are the new load-bearing half.
                @test !occursin("Bennett-lgzx", msg)
                @test !occursin("store of non-integer type", msg)
                # ... and p06b's OWN rejects did NOT fire on the `%L93`
                # MemoryRef write-back this gate is about. NARROWED TWICE by
                # Bennett-foz5, because wall 8 IS a p06b reject and a blanket
                # negative cannot survive — but DELETING it would lose the
                # intent, so keep BOTH narrowings (they fail for different
                # reasons, which is the point):
                #   * BODY SCOPE — preserves the original intent exactly:
                #     p06b must not reject anything in the CLOSURE body. Wall 8
                #     is in the ROOT body (`_pushvau9`). This recycles the
                #     retired `occursin("_growend!")` positive as the negative's
                #     scope term, so nothing is thrown away.
                @test !(occursin("Bennett-p06b", msg) && occursin("_growend!", msg))
                #   * DISCRIMINATOR, INVERTED by Bennett-bvmd (xkl wall 8).
                #     Pre-bvmd the only p06b reject tolerated here was the
                #     byte-granular `gc_alloc_obj` target refusal; bvmd ADMITS
                #     that tier at `elem_width = 8`, so a p06b reject naming
                #     `gc_alloc_obj` is now the REGRESSION. This still turns red
                #     on a p06b re-rejection of `%L93` under any name, which the
                #     body-scoped form alone would not catch.
                @test !(occursin("Bennett-p06b", msg) &&
                        occursin("gc_alloc_obj", msg))
                #   * and (P5) must not be the new wall — a (P4b)-only widening
                #     would move the reject there and clear nothing (scout §5).
                @test !occursin("BYTE-granular getelementptr", msg)
                # LOAD-BEARING NEGATIVE: wall 7 — the `%idxend41` memdata bounds
                # cluster — is CLEARED by Bennett-foz5 (ADR 0017 §4a).
                # MEASURED still-true at wall 9 (Bennett-bvmd).
                @test !occursin("Bennett-583s", msg)
                @test !occursin("base-cancelling", msg)
                # POSITIVE, ADVANCED by Bennett-bvmd: the NEW wall is wall 9 —
                # the ROOT body's arena-src memcpy, whose src operand is not
                # alloca-backed (Bennett-37mt Phase 1 / Bennett-8bys). Kept as a
                # disjunction because WHICH body of the set fails first is
                # registration/iteration order, not a contract. Non-numeral
                # anchors only (Bennett-0ncn: a bare numeral can false-match a
                # future bead tag).
                @test occursin("memcpy", msg) || occursin("Bennett-37mt", msg)
                # `occursin("_growend!", msg)` is DROPPED as a POSITIVE: the wall
                # moved to the ROOT body, so the closure name is legitimately
                # absent. It survives above as the body-scope term of the p06b
                # negative — retired from one role, reused in another.
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
        @test after == before                # registry restored — no leak (Rule 7)
    end

end
