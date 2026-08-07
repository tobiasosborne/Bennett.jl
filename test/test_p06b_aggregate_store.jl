# Bennett-p06b / CW-D (ADR 0017 CW-D workstream) — whole-aggregate `store`
# decomposition under `ptr_cells`. Wall 6 of the `bennettvm-xkl` push!-Vector
# chain, extraction side.
#
# # What changed
#
# Under the closed-world `ptr_cells` gate,
#
#     store <S> %agg, ptr %p            ; S an unpacked StructType
#
# no longer hits the Bennett-lgzx / U114 `vt isa IntegerType` reject. It is
# decomposed into, for each field k of S,
#
#     IRExtractValue(fk, <agg>, k, 0, N, field_widths)
#     IRPtrOffset(ak, <p>, LLVMOffsetOfElement(S, k), 64)
#     IRStore(ssa(ak), ssa(fk), 64)
#
# — EXACTLY the field-wise spelling the extractor already admits (the
# Bennett-6bu3 `extractvalue` arm, the BVM ADR 0020 D4 two-index struct-GEP
# arm, and the Bennett-ares/beaw `store ptr` cell arm). p06b introduces no new
# `IRInst`, no new BVM opcode, and no new emission vocabulary: it is a
# REPRESENTATION NORMALISATION of an already-admitted operation, not a new
# semantic capability. BennettVM src changes: ZERO.
#
# # The certified shape (the arm's own comment block is the authority)
#
#   (P1) S is NOT the LITERAL `{i64,ptr}` GenericMemory header (CW-D4 / 9n3y
#        stamps that ONE type byte-granular).
#   (P2) S passes `_struct_field_widths` — the Bennett-6bu3 reject surface,
#        REUSED, not re-implemented (packed / empty / i1 / float / nested /
#        array / vector fields all keep naming Bennett-6bu3).
#   (P3) EVERY field is exactly 64 bits at byte offset 8k (LLVMOffsetOfElement,
#        never hand-computed). Sub-cell / padded layouts are refused.
#   (P4a) the target is a REGISTERED SSA name — with p06b's OWN bead name on
#        the reject (hostile-review D5: the lgzx-verbatim reuse was reachable
#        here and would have been misread as the store-type wall).
#   (P4b) ... AND a CERTIFIED cell pointer: a `load` whose own pointer operand
#        is registered, an ALLOCATOR `call`, or an `alloca` of a MODELLED
#        allocated type — all in addrspace 0, and none SUPPRESSED by the module
#        walk (D1b). `phi`/`select`/`getelementptr`/pointer-ARGUMENT targets are
#        refused, each with its own named reason.
#   (P4c) ... AND it CERTIFIABLY RESERVES >= N cells at width 64 (D1). For
#        `:load` the extent is NOT statically knowable and is NOT certified —
#        see the arm's disclosure and the residual note at the foot of this file.
#   (P5) the target object has no CONFLICTING-GRANULARITY address-forming use,
#        scanned across SIBLING RE-LOADS of the same slot (D3), with no
#        index-0 GEP carve-out (D2).
#   (P6) the value is an `insertvalue` INSTRUCTION whose CHAIN ROOT is a
#        constant aggregate (D4) — BennettVM's `agg_dests` contract.
#
# # What this file pins
#
#   (a) the CORPUS shape decomposes, asserted as VALUES, including the
#       CELL-AGREEMENT theorem: p06b's `IRPtrOffset`s carry the IDENTICAL
#       `(offset_bytes, elem_width)` pairs as the untouched D4 GEP arm's
#       read-back of the SAME object;
#   (b) general N (three fields at 0/8/16) — the test a
#       "restrict to exactly two pointer fields" refactor cannot pass;
#   (c) the (P4) target whitelist is non-vacuous (call / alloca-ptr / named
#       struct targets admitted; pointer-ARGUMENT targets are a named DEFERRAL,
#       not an admission) and the self-referential case is order-immaterial;
#   (d) every REJECT class, each naming the RIGHT bead, with the load-bearing
#       negatives that prove it is not some OTHER wall;
#   (e) GATE-OFF byte-identity on an ALL-INTEGER-FIELD witness whose only
#       ptr_cells-dependent construct is the aggregate store itself;
#   (f) the REAL-CORPUS advance: the push! closed-world set walks past
#       `_growend!` `%L93` and lands on the Bennett-583s `%idxend41` ptrtoint
#       (bead Bennett-foz5), with the lgzx substrings as load-bearing
#       negatives.
#
# # Message-hygiene constraint (Bennett-0ncn)
#
# NONE of the p06b reject strings may contain `store of non-integer
# type`, `Bennett-lgzx`, `U114`, `ptrtoint`, `memmove`, `Bennett-iwo9`,
# `not yet lowered to reversible gates`, or `sret struct field` — every one of
# those is a load-bearing NEGATIVE in an existing wall marker, and reusing one
# would make a marker silently pass on the wrong wall. Testset (h) asserts this
# mechanically over every p06b message this file produces.
#
# # Ref
#   * `src/extract/instructions.jl` — the p06b arm + its determinism comment.
#   * `../BennettVM.jl/test/test_p06b_aggregate_store_vm.jl` — the E2E half.
#   * `docs/design/p06b/proposal_A.md` / `proposal_B.md` — the 3+1 designs.
#
# # RESIDUAL — read before trusting (P4c)
#
# For a `:load` target — WHICH IS THE REAL CORPUS SHAPE — the capacity is NOT
# certified and nothing in this file or the arm checks it. Measured 2026-08-06:
# `_growend!`'s target `%1 = load ptr, ptr %0` carries NO extent metadata, its
# pointer operand is a GEP off a `dereferenceable(0)` ARGUMENT, and the adequate
# allocation lives in the CALLER. Enforcement is deferred to BennettVM's
# out-of-reservation check (`bennettvm-pdqx`), which — measured — rejects only
# accesses landing outside ALL live reservations and does NOT reject a store
# that clobbers an ADJACENT live allocation. Closing that class needs pointer
# provenance. Do not read (P4c) as a whole-arm capacity guarantee.

using Test
using Bennett

const _FP06B = joinpath(@__DIR__, "fixtures", "ll", "p06b_agg_store.ll")

_p06b_parse(entry; ptr_cells=true) =
    Bennett.extract_parsed_ir_from_ll(_FP06B; entry_function=entry,
                                      ptr_cells=ptr_cells)

_p06b_insts(entry; ptr_cells=true) = begin
    p = _p06b_parse(entry; ptr_cells=ptr_cells)
    vcat([blk.instructions for blk in p.blocks]...)
end

_p06b_msg(entry; ptr_cells=true) = begin
    try
        _p06b_parse(entry; ptr_cells=ptr_cells)
        ""
    catch e
        e isa InterruptException && rethrow()
        sprint(showerror, e)
    end
end

# Every substring that is a load-bearing NEGATIVE in some other wall marker.
# A p06b message containing any of these would silently satisfy that marker.
const _P06B_FORBIDDEN = ("store of non-integer type", "Bennett-lgzx", "U114",
                         "ptrtoint", "memmove", "Bennett-iwo9",
                         "not yet lowered to reversible gates",
                         "sret struct field", "Bennett-dv1z")

# The real closed-world advancement target: the `push!` chain, whose
# `_growend!` slow path is outlined into a closure (Bennett-40ys) that
# write-backs the grown `MemoryRef` with the whole-struct store this bead
# admits.
function _pushp06b(n::Int64)
    v = Int64[]
    push!(v, n)
    return length(v)
end

@testset "Bennett-p06b: aggregate store decomposition under ptr_cells" begin

    # ==================================================================
    # (a) GREEN — the CORPUS shape, asserted as VALUES, plus the
    #     CELL-AGREEMENT theorem against the untouched D4 GEP arm.
    # ==================================================================
    @testset "(a) corpus shape → per-field extract/offset/store triples" begin
        insts = _p06b_insts("p06b_load_target")

        # the target is a real modelled cell: `load ptr` → IRLoad(_, _, 64)
        ld = only([i for i in insts if i isa Bennett.IRLoad && i.dest === :slot])
        @test ld.width == 64

        # exactly ONE aggregate store decomposed → 2 extracts, 2 offsets,
        # 2 stores (plus the 2 read-back GEPs and 2 scalar loads).
        evs = [i for i in insts if i isa Bennett.IRExtractValue]
        @test length(evs) == 2
        @test [e.index for e in evs] == [0, 1]
        for e in evs
            @test e.agg == Bennett.SSAOperand(:agg)
            @test e.elem_width == 0          # the 6bu3 StructType discriminator
            @test e.n_elems == 2
            @test e.field_widths == [64, 64]
        end

        sts = [i for i in insts if i isa Bennett.IRStore]
        @test length(sts) == 2
        @test all(s -> s.width == 64, sts)
        @test all(s -> s.ptr isa Bennett.SSAOperand, sts)
        # each store's value is the matching extract's dest, in field order
        @test [s.val for s in sts] ==
              [Bennett.SSAOperand(evs[1].dest), Bennett.SSAOperand(evs[2].dest)]

        # the p06b address nodes: byte offsets 0 and 8, cell stride 64
        store_ptr_names = Symbol[s.ptr.name for s in sts]
        pos = [i for i in insts if i isa Bennett.IRPtrOffset]
        p06b_pos = [o for o in pos if o.dest in store_ptr_names]
        @test length(p06b_pos) == 2
        @test all(o -> o.base == Bennett.SSAOperand(:slot), p06b_pos)
        @test [(o.offset_bytes, o.elem_width) for o in p06b_pos] ==
              [(0, 64), (8, 64)]

        # ---- THE CELL-AGREEMENT THEOREM, as a test ----
        # The SAME object `%slot` is READ BACK through the untouched BVM
        # ADR 0020 D4 two-index struct-GEP arm. Its `IRPtrOffset`s must carry
        # the IDENTICAL (offset_bytes, elem_width) pairs — otherwise the store
        # and the load would land on different VM cells (CW-D4 / 9n3y).
        f0 = only([o for o in pos if o.dest === :f0])
        f1 = only([o for o in pos if o.dest === :f1])
        @test (f0.offset_bytes, f0.elem_width) == (0, 64)
        @test (f1.offset_bytes, f1.elem_width) == (8, 64)
        @test Set((o.offset_bytes, o.elem_width) for o in p06b_pos) ==
              Set([(f0.offset_bytes, f0.elem_width),
                   (f1.offset_bytes, f1.elem_width)])
        @test f0.base == f1.base == Bennett.SSAOperand(:slot)

        # emission ORDER is deterministic and field-ascending: for each field,
        # extract → offset → store, fields 0 then 1.
        kinds = [(typeof(i), i isa Bennett.IRExtractValue ? i.index :
                             i isa Bennett.IRPtrOffset ? i.offset_bytes : -1)
                 for i in insts
                 if (i isa Bennett.IRExtractValue) ||
                    (i isa Bennett.IRPtrOffset && i.dest in store_ptr_names) ||
                    (i isa Bennett.IRStore)]
        @test kinds == [(Bennett.IRExtractValue, 0), (Bennett.IRPtrOffset, 0),
                        (Bennett.IRStore, -1),
                        (Bennett.IRExtractValue, 1), (Bennett.IRPtrOffset, 8),
                        (Bennett.IRStore, -1)]
    end

    # ==================================================================
    # (b) GREEN — general N. Three 64-bit fields at 0/8/16.
    # ==================================================================
    @testset "(b) general-N: {i64,i64,i64} → three triples at 0/8/16" begin
        insts = _p06b_insts("p06b_3x64")
        evs = [i for i in insts if i isa Bennett.IRExtractValue]
        @test length(evs) == 3
        @test [e.index for e in evs] == [0, 1, 2]
        @test all(e -> e.n_elems == 3 && e.field_widths == [64, 64, 64], evs)
        sts = [i for i in insts if i isa Bennett.IRStore]
        @test length(sts) == 3
        @test all(s -> s.width == 64, sts)
        names = Symbol[s.ptr.name for s in sts]
        offs = [o.offset_bytes for o in insts
                if o isa Bennett.IRPtrOffset && o.dest in names]
        @test offs == [0, 8, 16]
        @test all(o.elem_width == 64 for o in insts
                  if o isa Bennett.IRPtrOffset && o.dest in names)
        # the alloca really reserved the cells (no dangling target)
        al = only([i for i in insts if i isa Bennett.IRAlloca])
        @test al.dest === :slot
    end

    # ==================================================================
    # (c) GREEN — the (P4) target whitelist is NOT VACUOUS, and the
    #     self-referential case is order-immaterial.
    # ==================================================================
    @testset "(c) certified target kinds: call / alloca-ptr / named struct" begin
        for entry in ("p06b_call_target", "p06b_alloca_ptr_target",
                      "p06b_named_struct")
            insts = _p06b_insts(entry)
            sts = [i for i in insts if i isa Bennett.IRStore]
            @test length(sts) == 2
            @test all(s -> s.width == 64, sts)
            evs = [i for i in insts if i isa Bennett.IRExtractValue]
            @test length(evs) == 2
            @test [e.index for e in evs] == [0, 1]
        end
        # the modelled `alloca ptr, i32 2` really emits a cell reservation
        ai = only([i for i in _p06b_insts("p06b_alloca_ptr_target")
                   if i isa Bennett.IRAlloca])
        @test ai.dest === :slot
        @test ai.elem_width == 64
    end

    @testset "(c2) self-referential store (target also a field value)" begin
        # Every field value is read from the SSA aggregate (registers), never
        # from memory, so the N cell writes cannot observe each other and the
        # ascending order is a formatting choice, not a semantic one.
        insts = _p06b_insts("p06b_self_ref")
        evs = [i for i in insts if i isa Bennett.IRExtractValue]
        @test length(evs) == 2
        @test all(e -> e.agg == Bennett.SSAOperand(:agg), evs)
        sts = [i for i in insts if i isa Bennett.IRStore]
        @test length(sts) == 2
        names = Symbol[s.ptr.name for s in sts]
        @test [o.offset_bytes for o in insts
               if o isa Bennett.IRPtrOffset && o.dest in names] == [0, 8]
    end

    # ==================================================================
    # (d) REJECT (P1) — the LITERAL {i64,ptr} GenericMemory header, and
    #     its NAMED-struct discriminator (which must be ADMITTED).
    # ==================================================================
    @testset "(d) (P1) literal {i64,ptr} header rejects; named struct admits" begin
        msg = _p06b_msg("p06b_hdr_literal")
        @test occursin("Bennett-p06b", msg)
        @test occursin("9n3y", msg) || occursin("byte-granular", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
        # the discriminator: a NAMED %struct.p06bT = type {i64, ptr} is not a
        # literal struct, so it keeps the word-granular stamp and IS admitted.
        @test length([i for i in _p06b_insts("p06b_named_struct")
                      if i isa Bennett.IRStore]) == 2
    end

    # ==================================================================
    # (e) REJECT (P3) — sub-cell / padded field layouts.
    #     MUTATION-PROVABLE: without the guard, {i32,i32} would emit TWO
    #     whole-cell writes where the native store writes ONE 8-byte word.
    # ==================================================================
    @testset "(e) (P3) sub-cell layouts reject, naming p06b not 6bu3" begin
        for entry in ("p06b_2x32", "p06b_i64_i8", "p06b_i8_i64")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            @test occursin("64-bit cell", msg) || occursin("whole 64-bit", msg)
            # NOT annexed from 6bu3 and NOT the lgzx catch-all
            @test !occursin("Bennett-6bu3", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
    end

    # ==================================================================
    # (f) REJECT — the Bennett-6bu3 field surface is INHERITED, not
    #     annexed: every message must still name Bennett-6bu3.
    # ==================================================================
    @testset "(f) 6bu3 field-certification surface is delegated, unchanged" begin
        for entry in ("p06b_packed", "p06b_empty", "p06b_i64_i1",
                      "p06b_double_field", "p06b_nested")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-6bu3", msg)
            @test !occursin("Bennett-p06b", msg)
        end
    end

    # ==================================================================
    # (g) REJECT (P4)/(P5)/(P6) — the target and value certifications.
    # ==================================================================
    # (g1) DELETED by hostile-review defect D5 — it pinned the lgzx-verbatim
    # reuse, which is exactly the bug. Superseded by the (D5) testset below,
    # which pins the same fixture with the OPPOSITE expectation. The original
    # lgzx site keeps its text; that is pinned by test_lgzx_store_fail_loud.jl
    # and by testset (i)/(j) here (the ArrayType and gate-off rejects).

    @testset "(g2) (P4) the SILENT-ALLOCA hazard: alloca {ptr,ptr} rejects" begin
        # THE test a "just use haskey(names, ptr.ref)" simplification cannot
        # pass. `alloca { ptr, ptr }` has a StructType allocated type, which
        # the alloca arm SILENTLY SKIPS (no IRAlloca) while module_walk.jl has
        # already registered the dest symbol — so a naive registration-only
        # guard emits stores into a cell nothing ever reserved.
        msg = _p06b_msg("p06b_alloca_struct_target")
        @test occursin("Bennett-p06b", msg)
        @test occursin("alloca", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
        # the hazard is real: the alloca genuinely emits NOTHING today. Pin it
        # on a shape that DOES extract, so the claim is measured, not asserted.
        @test !any(i -> i isa Bennett.IRAlloca,
                   _p06b_insts("p06b_load_target"))   # (no alloca in that fn)
    end

    @testset "(g2b) (P4) pointer ARGUMENT target is a DEFERRED reject" begin
        # `module_walk.jl` gives a pointer parameter TWO models — the Julia
        # `dereferenceable(N)` FLAT WIRE ARRAY and the ADR 0020 D2 opaque cell
        # address — and the sret parameter is claimed by the dv1z pre-walk.
        # Only the second is a cell. Refused rather than discriminated on no
        # corpus witness; the message names the deferral so the widener knows
        # what is missing (a fixture + the deref/sret discrimination).
        msg = _p06b_msg("p06b_arg_target")
        @test occursin("Bennett-p06b", msg)
        @test occursin("ARGUMENT", msg)
        @test occursin("deferred", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
    end

    @testset "(g3) (P4) phi/select pointer targets reject (cc0 M2b sentinel)" begin
        for entry in ("p06b_phi_target", "p06b_select_target")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            @test occursin("WIDTH-0 SENTINEL", msg)
            @test occursin("Bennett-cc0", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
    end

    @testset "(g4) (P5) cell-granularity split rejects; control admits" begin
        msg = _p06b_msg("p06b_granularity")
        @test occursin("Bennett-p06b", msg)
        @test occursin("9n3y", msg) || occursin("granularity", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
        # POSITIVE CONTROL: the same shape WITHOUT the byte-granular GEP is
        # admitted, so the guard is discriminating, not blanket.
        @test length([i for i in _p06b_insts("p06b_call_target")
                      if i isa Bennett.IRStore]) == 2
    end

    @testset "(g5) (P6) non-insertvalue aggregate values reject" begin
        for entry in ("p06b_zeroinit_value", "p06b_load_value",
                      "p06b_undef_value")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            @test occursin("insertvalue", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
    end

    # ==================================================================
    # HOSTILE-REVIEW GATES (2026-08-06). Every reviewer repro is a
    # permanent gate here. Each testset names the defect it closes and,
    # where the defect was a SILENT MISCOMPILE, cites the executed
    # witness in the review scratchpad.
    # ==================================================================

    @testset "(D1) (P4c) target CAPACITY is certified, not assumed" begin
        # THE defect: (P4) certified that the producer WOULD emit an IRAlloca,
        # never that it reserves >= N cells at width 64. Executed witness
        # (scratchpad e2e2.jl / e2e3.jl): a 2-field store into a ONE-cell
        # reservation clobbered the neighbouring allocation on BOTH tiers —
        # EXPECTED 999, ACTUAL 42, no error raised.
        for entry in ("p06b_alloca_1cell", "p06b_malloc_1cell",
                      "p06b_alloca_dyncount", "p06b_alloca_i8arr")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            @test occursin("cell", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
        # the CAPACITY-ADEQUATE positive controls still admit, so (P4c) is
        # discriminating rather than blanket: `alloca ptr, i32 2` (2 cells),
        # `alloca i64, i32 3` (3 cells), `malloc(16)` (2 cells).
        for entry in ("p06b_alloca_ptr_target", "p06b_3x64", "p06b_call_target")
            @test length([i for i in _p06b_insts(entry)
                          if i isa Bennett.IRStore]) >= 2
        end
    end

    @testset "(D2) (P5) the index-0 GEP carve-out is DROPPED" begin
        # THE defect: an accepted 2-op index-0 GEP emits IRPtrOffset(_,_,0,8) —
        # a FRESH BYTE-granular base the one-level scan never followed — so a
        # gep-of-gep re-derived byte-cell 8 while the store wrote cell 1. The
        # carve-out bought nothing (measured: refusing costs zero frontier
        # progress) and is gone.
        msg = _p06b_msg("p06b_gep_of_gep")
        @test occursin("Bennett-p06b", msg)
        @test occursin("granularity", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
    end

    @testset "(D7) (P5) a struct-strided GEP is named accurately" begin
        # A 2-op GEP whose source element type is the STRUCT steps by a whole
        # 16-byte struct — calling that "BYTE-granular" was simply wrong.
        msg = _p06b_msg("p06b_struct_stride")
        @test occursin("Bennett-p06b", msg)
        @test occursin("struct-strided", msg)
        @test !occursin("BYTE-granular getelementptr", msg)
    end

    @testset "(D3) (P5) the scan follows SIBLING re-loads of the same slot" begin
        # THE defect: the scan was SSA-scoped, not object-scoped. Two
        # `load ptr, ptr %root` of the same slot give two SSA names, and the
        # scan over one never saw the other's byte GEP — the canonical GC
        # reload-after-safepoint shape.
        msg = _p06b_msg("p06b_realias")
        @test occursin("Bennett-p06b", msg)
        @test occursin("granularity", msg)
        @test occursin("sibling", msg) || occursin("re-load", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
    end

    @testset "(D4) (P6) the insertvalue CHAIN ROOT is certified" begin
        # THE defect: (P6) checked only the OUTERMOST insertvalue. A chain
        # rooted at a `load {ptr,ptr}` was admitted, and since BennettVM's
        # IRInsertValue has no `agg_dests` guard of its own, it died as a
        # contextless KeyError in the WRONG repo.
        msg = _p06b_msg("p06b_chainroot_load")
        @test occursin("Bennett-p06b", msg)
        @test occursin("chain", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
        # MEASURED, and worth recording: an `undef`-rooted chain never reaches
        # p06b at all — the 6bu3 insertvalue arm resolves its aggregate operand
        # through `_operand`, whose Bennett-bjdg / U80 guard rejects `undef`
        # first. The chain-root predicate accepts undef/poison as a matter of
        # semantics, but the pipeline cannot deliver one, so the ONLY reachable
        # certified root is `zeroinitializer` (every admit fixture in this file).
        umsg = _p06b_msg("p06b_chainroot_undef")
        @test occursin("UndefValue", umsg) || occursin("undef", umsg)
        @test !occursin("Bennett-p06b", umsg)
    end

    @testset "(D5) (P4a) unregistered target names p06b, not lgzx" begin
        # THE defect: the lgzx-verbatim reuse is REACHABLE on p06b shapes, so a
        # (P4a) firing on the corpus would be misattributed to the lgzx wall by
        # the three advanced markers, whose `!occursin("Bennett-lgzx")` is a
        # LOAD-BEARING negative. It also escaped the (h) sweep by construction.
        msg = _p06b_msg("p06b_global_target")
        @test occursin("Bennett-p06b", msg)
        @test !occursin("Bennett-lgzx", msg)
        @test !occursin("U114", msg)
        # the cross-reference may still appear as context, but not as the
        # leading bead name — and never as a bare substring another marker pins
        @test occursin("registered SSA name", msg)
    end

    # ==================================================================
    # HOSTILE REVIEW ROUND 2 — defects found by probing the round-1 FIXES.
    # ==================================================================

    @testset "(N1) (P4c) capacity is DERIVED from the arm, not mirrored" begin
        # THE defect: the mirror read the ArrayType count operand that the
        # alloca arm DISCARDS, so `alloca [1 x i64], i32 4` reserved ONE cell
        # and certified FOUR. Executed witness (scratchpad h1_e2e.jl):
        # EXPECTED 999, ACTUAL 42. Capacity now comes from the arm's OWN
        # `_alloca_reservation`; a mirrored predicate is a latent miscompile
        # with a docstring.
        msg = _p06b_msg("p06b_arr_count")
        @test occursin("Bennett-p06b", msg)
        @test occursin("cell", msg)
        for f in _P06B_FORBIDDEN
            @test !occursin(f, msg)
        end
        # POSITIVE CONTROL: `alloca [2 x i64]` (implicit count 1) really does
        # reserve 2 word cells, so the guard is discriminating, not blanket.
        @test length([i for i in _p06b_insts("p06b_arr_ok")
                      if i isa Bennett.IRStore]) == 2
        # ... and the emitted IRAlloca agrees with what was certified.
        aa = only([i for i in _p06b_insts("p06b_arr_ok")
                   if i isa Bennett.IRAlloca])
        @test aa.elem_width == 64
        @test aa.n_elems == Bennett.ConstOperand(2)
    end

    @testset "(N2) (P5) the alias key is CANONICAL, not syntactic" begin
        # THE defect: two IDENTICAL `getelementptr i8, ptr %root, i64 0` gave
        # two SSA refs, so the ref-keyed alias group never linked the loads and
        # the byte GEP went unseen — ADMITTED, VM returned 0 where LLVM says 42.
        # `optimize=false` (mandated by Rule 5) emits redundant GEPs routinely.
        for entry in ("p06b_redundant_gep", "p06b_shared_gep")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            @test occursin("granularity", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
        # POSITIVE CONTROL: a sibling re-load whose only use is a WORD-granular
        # struct GEP still AGREES and must stay admitted.
        @test length([i for i in _p06b_insts("p06b_sibling_ok")
                      if i isa Bennett.IRStore]) == 2
    end

    @testset "(N3) (P4b) julia.gc_alloc_obj is ADMITTED, BYTE-stamped" begin
        # THE ORIGINAL DEFECT (p06b hostile review N3): admitted at WORD
        # granularity while BennettVM stamps the Julia heap tier BYTE-granular
        # (`_byte_cells`, BVM src/ir/intrinsics.jl:256-257). A field read at
        # byte offset 8 landed on cell base+8 while p06b wrote base+1 —
        # EXPECTED 42, ACTUAL 0 (scratchpad h17_e2e.jl). p06b refused the tier
        # outright and NAMED the widening.
        #
        # INVERTED BY Bennett-bvmd (xkl wall 8). The tier is now admitted at the
        # granularity BennettVM actually reserves for it: `elem_width = 8`, so
        # field k lands on BYTE cell `o_k` — the same cell the object's `gep i8`
        # readers name. The h17 repro is sound under the new emission because
        # the D4 two-index struct-GEP arm was RE-STAMPED in the same change
        # (provenance-first union); without that the defect would merely have
        # flipped from "store word, read byte" to "store byte, read word".
        #
        # Note what is NOT re-asserted here: the retired reject text pinned the
        # string `9n3y`, a DANGLING ID in both trackers (the live filings are
        # `Bennett-zdd6` and `bennettvm-rxgy`). It is not reintroduced.
        insts = _p06b_insts("p06b_gc_alloc_target")
        offs = [o for o in insts if o isa Bennett.IRPtrOffset]
        @test length([i for i in insts if i isa Bennett.IRStore]) == 2
        # byte offsets 0 and 8, BYTE-stamped ⇒ cells +0 and +8, inside the
        # 24-byte-cell `_alloc_cells(::IntrinsicGCAlloc)` reservation.
        @test Set((o.offset_bytes, o.elem_width) for o in offs) ==
              Set([(0, 8), (8, 8)])
        # and the whole-file byte-tier / word-tier contract lives in
        # test/test_bvmd_root_scale.jl — this is the p06b-local pin.
    end

    @testset "(D1b-pin) suppressed roots are refused — UNIT test" begin
        # D1b had no direct gate. A full `.ll` reaching consumed-sret
        # suppression is impractical to hand-write, so this is a UNIT test on
        # the predicate with a CONSTRUCTED suppressed set — which is exactly
        # what `module_walk.jl` hands it (the union of `sret_writes.suppressed`,
        # `.call_return_suppressed` and `consumed_sret.suppressed`).
        path = _FP06B
        mktempdir() do _
            ctx = Bennett.LLVM.Context()
            Bennett.LLVM.activate(ctx)
            mod = parse(Bennett.LLVM.Module, read(path, String))
            fn = only([f for f in Bennett.LLVM.functions(mod)
                       if Bennett.LLVM.name(f) == "p06b_alloca_ptr_target"])
            names = Dict{Bennett._LLVMRef,Symbol}()
            slot = nothing
            for bb in Bennett.LLVM.blocks(fn), i in Bennett.LLVM.instructions(bb)
                names[i.ref] = Symbol(Bennett.LLVM.name(i))
                Bennett.LLVM.name(i) == "slot" && (slot = i)
            end
            @test slot !== nothing
            # NOT suppressed → certified, with capacity 2.
            k0, c0 = Bennett._p06b_cell_ptr_target_kind(
                slot, names, true, Set{Bennett._LLVMRef}())
            @test k0 === :alloca
            @test c0 == 2
            # SUPPRESSED → refused outright, regardless of the type rules.
            k1, c1 = Bennett._p06b_cell_ptr_target_kind(
                slot, names, true, Set{Bennett._LLVMRef}([slot.ref]))
            @test k1 === :none
            @test c1 == 0
            # ... and the reject WORDING names the suppression, not the type.
            nm = Bennett._p06b_target_kind_name(
                slot, Set{Bennett._LLVMRef}([slot.ref]))
            @test occursin("SUPPRESSED", nm)
            @test occursin("module walk", nm)
        end
    end

    @testset "(khb2) KNOWN-ADMITTED residual: :load has no capacity proof" begin
        # ******************************************************************
        # * This is NOT desired behaviour. A `:load` target's extent is not *
        # * statically knowable (it is the REAL CORPUS SHAPE), so (P4c)     *
        # * does not certify it and this program IS admitted — and would    *
        # * silently clobber its neighbour on the VM.                       *
        # *                                                                 *
        # * IF THIS TESTSET GOES RED, someone closed Bennett-khb2. That is  *
        # * the signal to FLIP the assertion to a reject, NOT to delete it. *
        # ******************************************************************
        insts = _p06b_insts("p06b_khb2_loadclobber")
        # 2 decomposed field stores (+1 scalar `store ptr %small, ptr %slot`)
        @test length([i for i in insts if i isa Bennett.IRExtractValue]) == 2
        @test length([i for i in insts if i isa Bennett.IRStore]) == 3
        # the disclosure is load-bearing: nothing here proves capacity
        @test _p06b_msg("p06b_khb2_loadclobber") == ""
    end

    # ==================================================================
    # (h) MESSAGE HYGIENE — mechanical sweep over every p06b message.
    # ==================================================================
    @testset "(h) no p06b message collides with another marker's negative" begin
        for entry in ("p06b_hdr_literal", "p06b_2x32", "p06b_i64_i8",
                      "p06b_i8_i64", "p06b_alloca_struct_target",
                      "p06b_arg_target",
                      "p06b_phi_target", "p06b_select_target",
                      "p06b_granularity", "p06b_zeroinit_value",
                      "p06b_load_value", "p06b_undef_value",
                      # hostile-review additions (D5 in particular: the P4a
                      # message escaped this sweep by construction before)
                      "p06b_global_target",
                      "p06b_alloca_1cell", "p06b_malloc_1cell",
                      "p06b_alloca_dyncount", "p06b_alloca_i8arr",
                      "p06b_gep_of_gep", "p06b_struct_stride",
                      "p06b_realias", "p06b_chainroot_load",
                      # round-2 additions
                      "p06b_arr_count", "p06b_redundant_gep",
                      "p06b_shared_gep",
                      # Bennett-bvmd: `p06b_gc_alloc_target` LEFT this sweep —
                      # it is now an ADMIT fixture (see (N3)), so it produces no
                      # message to sweep. Its replacement keeps the gc_alloc arm
                      # covered: a byte-tier box too SMALL for the
                      # decomposition, which is the one gc_alloc reject that
                      # survives bvmd ((P4c), in byte cells).
                      "p06b_gc_alloc_small")
            msg = _p06b_msg(entry)
            @test occursin("Bennett-p06b", msg)
            for f in _P06B_FORBIDDEN
                @test !occursin(f, msg)
            end
        end
    end

    # ==================================================================
    # (i) UNCHANGED REJECTS — ArrayType aggregates and the 4mmt guards.
    # ==================================================================
    @testset "(i) ArrayType store and volatile store are untouched" begin
        for pc in (true, false)
            msg = _p06b_msg("p06b_array_store"; ptr_cells=pc)
            @test occursin("Bennett-lgzx", msg)
            @test occursin("U114", msg)
            @test occursin("store of non-integer type", msg)
            @test !occursin("Bennett-p06b", msg)
        end
        vmsg = _p06b_msg("p06b_volatile"; ptr_cells=true)
        @test occursin("Bennett-4mmt", vmsg)
        @test !occursin("Bennett-p06b", vmsg)
    end

    # ==================================================================
    # (j) GATE WITNESS — ptr_cells=false is byte-identical.
    #     The fixture's fields are ALL plain i64, so `_struct_field_widths`
    #     certifies its `insertvalue`s at BOTH gate settings and the ONLY
    #     gate-dependent construct is the aggregate STORE itself. (A
    #     `{ptr,ptr}` fixture rejects EARLIER, at the 6bu3 pointer-field
    #     guard, and would not witness the STORE arm's gating.)
    # ==================================================================
    @testset "(j) gate witness: same .ll, admitted ON, lgzx-rejected OFF" begin
        insts = _p06b_insts("p06b_2x64_gate"; ptr_cells=true)
        @test length([i for i in insts if i isa Bennett.IRStore]) == 2
        @test length([i for i in insts if i isa Bennett.IRExtractValue]) == 2

        msg = _p06b_msg("p06b_2x64_gate"; ptr_cells=false)
        @test occursin("Bennett-lgzx", msg)
        @test occursin("U114", msg)
        @test occursin("store of non-integer type", msg)
        @test occursin("{ i64, i64 }", msg)
        @test !occursin("Bennett-p06b", msg)
    end

    # ==================================================================
    # (k) REAL-CORPUS ADVANCE — the push! closed-world set walks past
    #     `_growend!` `%L93` and lands on the NEXT named wall.
    #
    #     MEASURED, not predicted (Rule 9 / the jbko lesson). Deliberately
    #     NOT pinned: SSA names (`%memory_ref15` vs `%memory_ref12`), entry
    #     manglings (`_1048` / `_1066`), block labels — all drift per Julia
    #     process (Rule 5).
    # ==================================================================
    @testset "(k) push! set advances past the %L93 aggregate store" begin
        e = try
            Bennett.extract_parsed_ir_set_from_julia(_pushp06b, Tuple{Int64};
                                                     ptr_cells=true)
            nothing
        catch err
            err isa InterruptException && rethrow()
            err
        end
        if e === nothing
            @test true      # fully extracted — stronger than a wall advance
        else
            msg = e isa ErrorException ? e.msg : sprint(showerror, e)
            # LOAD-BEARING NEGATIVES — the lgzx aggregate-store wall is
            # CLEARED. Without these the positive alone would keep passing if
            # p06b regressed to a differently-worded store reject.
            @test !occursin("store of non-integer type", msg)
            @test !occursin("Bennett-lgzx", msg)
            # ... and p06b's OWN rejects did NOT fire on the `%L93` MemoryRef
            # write-back this gate is about: it was ADMITTED, not re-rejected
            # under a new name. This is the half that catches an over-tight
            # (P3)/(P4)/(P5)/(P6).
            #
            # NARROWED TWICE by Bennett-foz5 (2026-08-06), then INVERTED by
            # Bennett-bvmd (2026-08-06). foz5 left the wall at the ROOT body's
            # (P4b) BYTE-granular `julia.gc_alloc_obj` target refusal (wall 8)
            # and had to tolerate it; bvmd ADMITTED that tier at elem_width 8,
            # so the tolerance is now a REGRESSION DETECTOR. Keep BOTH
            # narrowings — they fail for different reasons, which is exactly why
            # neither alone is enough:
            #   * BODY SCOPE — preserves the original intent verbatim (p06b must
            #     not reject inside the CLOSURE), recycling the retired
            #     `occursin("_growend!")` positive as the scope term.
            @test !(occursin("Bennett-p06b", msg) && occursin("_growend!", msg))
            #   * DISCRIMINATOR, INVERTED (Bennett-bvmd). Pre-bvmd this read
            #     `!p06b || gc_alloc_obj` — "the ONLY p06b reject tolerated here
            #     is the byte-granular gc_alloc_obj target refusal". That
            #     refusal is GONE, so a p06b reject NAMING `gc_alloc_obj` is now
            #     the regression, not the expected wall.
            @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
            #   * (P5) must not be the new wall. If it is, the D4 struct-GEP
            #     re-stamp was skipped and the arc is a no-op: a (P4b)-only
            #     widening moves the reject from (P4b) to (P5) and clears
            #     NOTHING (scout §5, executed probe `b06_p5.jl`).
            @test !occursin("BYTE-granular getelementptr", msg)
            #   * bvmd's own (SC) stream guard must not be the new wall either.
            @test !occursin("Bennett-bvmd", msg)
            # still-cleared predecessors (vau9 / jbko)
            @test !occursin("memmove", msg)
            @test !occursin("Bennett-iwo9", msg)
            # LOAD-BEARING NEGATIVE: wall 7 — the `%idxend41` split-captured
            # MemoryRef bounds cluster — is CLEARED by Bennett-foz5 under the
            # ADR 0017 §4a CONFINED-VALUE contract.
            #
            # NARROWED to BODY SCOPE by Bennett-sy29 (xkl wall 9). The bvmd
            # comment here predicted exactly this: the trap "fires ONE BEAD
            # LATER". It has. Wall 10 IS a 583s reject, so the blanket negatives
            # cannot survive — but deleting them would throw away their intent
            # (wall 7 was the CLOSURE's `%idxend41` cluster, cleared by
            # Bennett-foz5), so scope the negative to the CLOSURE body instead.
            # bvmd's suggested `udiv exact` discriminator is NOT constructible:
            # the `_ir_error` prefix quotes the *ptrtoint*, not the cluster, so
            # the message text contains no `udiv` (docs/design/sy29_scout.md
            # §10.2).
            @test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
            # ===================== WALL 10 CLEARED — Bennett-57hd =====================
            # ADVANCED by Bennett-57hd (ADR 0017 §4b, the VALUE-IDENTITY contract): wall
            # 10 — the ROOT body's `%12 = ptrtoint ptr %memory_data3 to i64`, whose
            # base-cancelling difference escaped through `udiv exact` — is CLEARED, so a
            # 583s / foz5 / 57hd reject in the ROOT body is now a REGRESSION rather than
            # the expected wall. (Replaces the sy29-era positive, which asserted exactly
            # that reject.) Non-numeral anchors only (Bennett-0ncn).
            @test !occursin("base-cancelling", msg)
            @test !occursin("_foz5_confined_dead_bounds", msg)
            @test !occursin("_57hd_value_identity_cluster", msg)
            # ===================== WALL 11 CLEARED — Bennett-5viz =====================
            # ADVANCED by Bennett-5viz (xkl wall 11): the loaded-`ptr` (`.mem`) memcpy SRC —
            # corpus site #4 of the sy29 census, `Bennett-8bys` territory — is now certified
            # by `_5viz_global_src_root`, which strips the `extractvalue` with the shipped
            # `_57hd_insertvalue_field` and canonicalises the result with `_57hd_canon`
            # (ZERO ADR 0017 §4b change) down to the EMPTY-`GenericMemory` SINGLETON's
            # `.globals` root; root/capacity/scale then come from `parsed.globals` via
            # doih G8's own formula. WALL 12 is `Bennett-p06b`'s OWN reject: the
            # `alloca { ptr, ptr }` whose allocated type the alloca arm SILENTLY SKIPS, so
            # nothing ever reserved the cells that aggregate store would write.
            @test occursin("Bennett-p06b", msg)
            @test occursin("_p06b_cell_ptr_target_kind", msg)   # names the predicate
            @test occursin("SILENTLY SKIPS", msg)
            # ┌────────── THE `.mem` SUFFIX TRAP — MEASURED, DO NOT SHORTEN ───────────┐
            # │ The wall-11 discriminator INVERTS here: a `Bennett-37mt` / `-8bys` src  │
            # │ reject at the corpus is now a REGRESSION. This negative is STRONGER     │
            # │ than the operand-name pair it replaces — it does not depend on which    │
            # │ operand the `_ir_error` prefix happens to quote.                        │
            # │ BUT: wall 12's message DOES contain the substring `new::Array.ref` (it  │
            # │ quotes `store { ptr, ptr } %"new::Array.ref", …`) and does NOT contain  │
            # │ `new::Array.ref.mem`. KEEP THE `.mem` SUFFIX — dropping it turns the    │
            # │ line RED. Check discriminators against the MESSAGE TEXT, never against  │
            # │ the IR: the Bennett-sy29 lesson, applied to its own successor.          │
            # └────────────────────────────────────────────────────────────────────────┘
            @test !occursin("Bennett-37mt", msg)
            @test !occursin("new::Array.ref.mem", msg)
            @test !occursin("Bennett-5viz", msg)       # 5viz must not be the new wall
            # NOTE FOR WHOEVER CLEARS WALL 12 — all four points MEASURED on the wall-12
            # text itself, not forecast:
            #   * wall 12's own message contains NEITHER `Bennett-1zow` NOR
            #     `_p06b_granularity_violation`, so a marker written against either tag
            #     would never fire. Pin what IS there.
            #   * wall 13 is a SECOND 37mt/8bys memcpy reject (`memcpy operand alloca has
            #     non-integer element type` — corpus site #5's `alloca { ptr, ptr }` src,
            #     still `Bennett-8bys` territory), so `!occursin("Bennett-37mt")` will have
            #     to FLIP BACK to a positive one wall later; the discriminator against wall
            #     11 at that point is the operand pair (`%0` / `env+56`, NO `.mem`).
            #   * wall 14 is the bvmd `SCALE-COHERENCE` reject on the 9×i64 closure alloca.
            #     It PRE-EXISTS 5viz — raised by the already-shipped site-#3 memcpy's word
            #     stamp setting `all_byte[env] = false`, not by anything 5viz emits — and
            #     the 5viz scout's probe `p10` measured that byte-stamping ALL THREE
            #     env-rooted memcpys makes the ROOT extract with NO WALL AT ALL. That tier
            #     decision is deferred to the `Bennett-bvmd` family arc (5viz scout §3);
            #     5viz deliberately keeps the sy29 dst-stamp rule unchanged.
            #   * the `%L21` / `%L43` clusters are NOT future walls — already admitted
            #     under ADR 0017 §4a (gate (S) of test_57hd_value_identity.jl).
            # `occursin("_growend!", msg)` is DROPPED as a POSITIVE — the wall
            # moved to the ROOT body, so the closure name is legitimately absent.
            # It survives above as the body-scope term of the p06b negative.
        end
    end

end
