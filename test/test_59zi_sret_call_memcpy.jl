using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, extract_parsed_ir, extract_parsed_ir_from_ll,
               register_callee!
using Bennett: IRRet, IRCall, IRAlloca

# Bennett-59zi — sret-returning CALL into a local alloca + llvm.memcpy(parent_sret, alloca).
#
# Ground truth (re-probed 2026-06-25, post-SROA, the IR the extractor actually
# walks): `Base.ht_keyindex2_shorthash!` is self-recursive. Its recursive-tail
# block L171 emits
#     %box  = alloca [2 x i64]                                    (in `top`)
#     call void @ht_keyindex2_shorthash!(sret({i64,i8}) %box, ...) (recursive)
#     call void @llvm.memcpy(%sret_return, %box, 16)               (WALL A)
#     ret void
# while the five ORDINARY return blocks (L5/L85/L116/L129/L156) emit two scalar
# stores (offsets 0, 8) PLUS a 7-byte ABI-padding memcpy
#     call void @llvm.memcpy(%sret_return+9, <[7 x i8] junk alloca>, 7)  (WALL B)
#
# Wall A is the named bead wall. Wall B is hidden behind it (proven by
# neutralizing the Wall-A reject and re-extracting: the next error is the L5
# padding memcpy hitting `_handle_memcpy_arm`'s "dst not alloca-backed" reject).
#
# Fix: in the sret PRE-WALK,
#  * Wall A — recognise memcpy(dst===sret_param, src===alloca that is the sret-out
#    of a producing CALL carrying a call-site `sret` attr, N==agg_byte_size,
#    non-volatile). Suppress the box alloca + memcpy + the producing call's
#    default emission; re-synthesize ONE IRCall (ret_width from the PARENT sret
#    packed width) threaded into IRRet. The call-return block becomes its own
#    value-bearing IRRet block, merged by the existing resolve_phi_predicated!.
#  * Wall B — classify an sret-derived memcpy whose byte range is DISJOINT from
#    every field byte-range (pure padding) as INERT and suppress it. A range that
#    OVERLAPS a field is rejected loud (value-write via memcpy is out of scope).
#
# SCOPING: 59zi clears the EXTRACTION wall only. ht_keyindex2 is self-recursive,
# so `lower_call!` would recurse unboundedly — it does NOT compile to a circuit
# yet (gated on the deferred self-recursive-callee bead + 6x2w/lf14). The
# ht_keyindex2 test below is therefore EXTRACTION-SHAPE-ONLY.

_n_ret_blocks(pir) = count(b -> b.terminator isa IRRet, pir.blocks)
_block_insts(b) = b.instructions

# x86-64 SysV datalayout (matches Julia's; i64 on i64 alignment).
const _59zi_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

function _write_ll(body::String)
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_59zi_dl\"\n\n")
        write(io, body)
    end
    return path
end

function _59zi_reject(name::String, body::String, needle::String; ptr_cells::Bool=false)
    path = _write_ll(body)
    @test_throws Exception extract_parsed_ir_from_ll(path; entry_function=name, ptr_cells=ptr_cells)
    try
        extract_parsed_ir_from_ll(path; entry_function=name, ptr_cells=ptr_cells)
        @test false  # should not reach
    catch e
        e isa InterruptException && rethrow()
        msg = sprint(showerror, e)
        if !occursin(needle, msg)
            @info "reject message mismatch" name needle msg
        end
        @test occursin(needle, msg)
    end
end

# ---- The registered leaf: a non-recursive Julia function returning {i64,i8}. ----
# `_lookup_callee("leaf59zi")` resolves the .ll call `@leaf59zi` to this Function;
# `lower_call!` re-extracts ITS Julia body, so the end-to-end simulate checks the
# caller forwards leaf59zi's true aggregate, not garbage.
leaf59zi(k::Int8) = (Int64(k) + 1000, k ⊻ Int8(0x55))

@testset "Bennett-59zi sret call → memcpy forwarding" begin

    register_callee!(leaf59zi)

    # =====================================================================
    # (a) SYNTHETIC LEAF fixture — extraction shape + END-TO-END verify.
    # =====================================================================
    # @caller59zi forwards leaf59zi's {i64,i8} aggregate via a local alloca +
    # whole-aggregate memcpy into its own sret pointer. This is Wall A in
    # isolation (no padding memcpy — a 16-byte whole-aggregate copy).
    caller_body = """
    declare void @leaf59zi(ptr sret({i64,i8}), i8)
    define void @caller59zi(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 signext %k) {
    top:
      %box = alloca [2 x i64], align 8
      call void @leaf59zi(ptr noalias nocapture sret({i64,i8}) align 8 %box, i8 signext %k)
      call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
      ret void
    }
    declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
    """

    @testset "Wall A: extraction shape (IRCall→IRRet, box/memcpy suppressed)" begin
        path = _write_ll(caller_body)
        pir = extract_parsed_ir_from_ll(path; entry_function="caller59zi")
        @test pir.ret_width == 72
        @test pir.ret_elem_widths == [64, 8]
        # Exactly one return block, carrying one IRCall to the leaf, no alloca.
        blk = only(pir.blocks)
        @test blk.terminator isa IRRet
        @test blk.terminator.width == 72
        calls = filter(i -> i isa IRCall, _block_insts(blk))
        @test length(calls) == 1
        @test calls[1].callee === leaf59zi      # resolved Function, not Symbol
        @test calls[1].ret_width == 72
        @test calls[1].arg_widths == [8]
        @test !any(i -> i isa IRAlloca, _block_insts(blk))  # box suppressed
    end

    @testset "Wall A: END-TO-END verify_reversibility + exhaustive simulate" begin
        # The leaf is non-recursive ⇒ lowerable. Compile the .ll caller to a
        # circuit and check caller(k) == leaf59zi(k) over ALL 256 Int8 inputs,
        # with all ancillae returning to zero (Rule 4). This is the load-bearing
        # semantic check: it proves IRCall→IRRet forwarding computes the RIGHT
        # aggregate.
        path = _write_ll(caller_body)
        pir = extract_parsed_ir_from_ll(path; entry_function="caller59zi")
        c = reversible_compile(pir)
        @test verify_reversibility(c)
        @test c.output_elem_widths == [64, 8]
        for ki in -128:127
            k = Int8(ki)
            out = simulate(c, (k,))
            exp = leaf59zi(k)
            @test (out[1] % Int64) == exp[1]
            @test (out[2] % UInt8) == (exp[2] % UInt8)
        end
    end

    # ---- Wall B variant: padding memcpy at offset 9 alongside Wall A. ----
    # Mirrors the ht_keyindex2 store blocks: two scalar field stores + a 7-byte
    # padding memcpy from a junk [7 x i8] alloca, in the SAME block as a whole-agg
    # call-memcpy is NOT how Julia emits it — Wall B lives in the ordinary STORE
    # blocks. So here the padding memcpy rides a STORE return block; the call/
    # whole-agg memcpy rides a separate branch. This is the jghk store-block shape
    # plus Wall B.
    pad_body = """
    declare void @leaf59zi(ptr sret({i64,i8}), i8)
    define void @caller_pad59zi(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 signext %k, i1 %c) {
    top:
      %junk = alloca [7 x i8], align 1
      br i1 %c, label %store_arm, label %call_arm
    store_arm:
      %kx = sext i8 %k to i64
      store i64 %kx, ptr %out, align 8
      %p8 = getelementptr inbounds i8, ptr %out, i64 8
      store i8 %k, ptr %p8, align 8
      %p9 = getelementptr inbounds i8, ptr %out, i64 9
      call void @llvm.memcpy.p0.p0.i64(ptr align 1 %p9, ptr align 1 %junk, i64 7, i1 false)
      ret void
    call_arm:
      %box = alloca [2 x i64], align 8
      call void @leaf59zi(ptr noalias nocapture sret({i64,i8}) align 8 %box, i8 signext %k)
      call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
      ret void
    }
    declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
    """

    @testset "Wall B: padding memcpy suppressed, two return paths merge" begin
        path = _write_ll(pad_body)
        pir = extract_parsed_ir_from_ll(path; entry_function="caller_pad59zi")
        @test pir.ret_width == 72
        @test pir.ret_elem_widths == [64, 8]
        # One store-arm IRRet + one call-arm IRRet → two value-bearing returns.
        @test _n_ret_blocks(pir) == 2
        # Exactly one leaf call (the call arm); padding memcpy + junk alloca gone.
        all_insts = [i for b in pir.blocks for i in _block_insts(b)]
        leaf_calls = filter(i -> i isa IRCall && i.callee === leaf59zi, all_insts)
        @test length(leaf_calls) == 1
    end

    # =====================================================================
    # (b) Per-reject .ll fixtures (the matrix rows expressible in .ll).
    # =====================================================================
    @testset "rejects (fail-loud matrix)" begin
        # R: partial-size memcpy (N != agg_byte_size).
        _59zi_reject("r_partial", """
        declare void @leaf59zi(ptr sret({i64,i8}), i8)
        define void @r_partial(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @leaf59zi(ptr sret({i64,i8}) %box, i8 %k)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 8, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")

        # R: src is NOT an alloca (it is the function's own parameter pointer).
        _59zi_reject("r_src_param", """
        define void @r_src_param(ptr noalias nocapture sret({i64,i8}) align 8 %out, ptr %src) {
        top:
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %src, i64 16, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")

        # R: src alloca written by a NON-sret call (no sret attr on the writer).
        _59zi_reject("r_nonsret_writer", """
        declare void @notleaf(ptr, i8)
        define void @r_nonsret_writer(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @notleaf(ptr %box, i8 %k)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")

        # R: callee sret pointee type ≠ parent agg type ({i32,i32} vs {i64,i8}).
        _59zi_reject("r_type_mismatch", """
        declare void @leafother(ptr sret({i32,i32}), i8)
        define void @r_type_mismatch(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k) {
        top:
          %box = alloca [2 x i64], align 8
          call void @leafother(ptr sret({i32,i32}) %box, i8 %k)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")

        # R: sret memcpy whose range OVERLAPS a field (offset 4, length 4 covers
        # bytes [4,8) of field 0 [0,8)). The src is a `ptr` PARAMETER so SROA can
        # NOT scalarise the memcpy into a store — it survives to the Wall-B
        # classifier, which rejects the field overlap loud (a value-write via
        # memcpy is out of scope). The valid field stores keep the rest of the
        # return path well-formed so the overlap memcpy is the only offender.
        _59zi_reject("r_field_overlap", """
        define void @r_field_overlap(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k, ptr %src) {
        top:
          store i64 1, ptr %out, align 8
          %p8 = getelementptr inbounds i8, ptr %out, i64 8
          store i8 %k, ptr %p8, align 8
          %p4 = getelementptr inbounds i8, ptr %out, i64 4
          call void @llvm.memcpy.p0.p0.i64(ptr align 1 %p4, ptr align 1 %src, i64 4, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "overlaps field")

        # R: TWO whole-agg memcpys targeting the parent sret in the same block.
        _59zi_reject("r_two_memcpys", """
        declare void @leaf59zi(ptr sret({i64,i8}), i8)
        define void @r_two_memcpys(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k) {
        top:
          %box1 = alloca [2 x i64], align 8
          %box2 = alloca [2 x i64], align 8
          call void @leaf59zi(ptr sret({i64,i8}) %box1, i8 %k)
          call void @leaf59zi(ptr sret({i64,i8}) %box2, i8 %k)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box1, i64 16, i1 false)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box2, i64 16, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")

        # R: block is BOTH a store-block (scalar field store) AND a call-return.
        _59zi_reject("r_mixed_store_call", """
        declare void @leaf59zi(ptr sret({i64,i8}), i8)
        define void @r_mixed_store_call(ptr noalias nocapture sret({i64,i8}) align 8 %out, i8 %k) {
        top:
          %box = alloca [2 x i64], align 8
          store i64 5, ptr %out, align 8
          call void @leaf59zi(ptr sret({i64,i8}) %box, i8 %k)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
          ret void
        }
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        """, "Bennett-59zi")
    end

    # =====================================================================
    # (c) ht_keyindex2 end-to-end EXTRACTION (RED before fix → GREEN after).
    #     STRUCTURAL check only: ht_keyindex2 is self-recursive and canNOT
    #     lower to a circuit yet (deferred bead). We assert only extraction shape.
    # =====================================================================
    @testset "ht_keyindex2 extracts (extraction-shape-only)" begin
        register_callee!(Base.ht_keyindex2_shorthash!)
        # SCOPING / Rule 1 honesty: 59zi clears the TWO sret-memcpy walls (Wall A
        # recursive-call forwarding + Wall B padding). ht_keyindex2 has a THIRD,
        # DEEPER wall that is UNRELATED to 59zi: under `--check-bounds=yes` (the
        # Pkg.test mode, Bennett-2mj3/figa) Julia codegen emits a
        # `ptrtoint ptr %memory_data to i64` in block L71 (a bounds-check pointer-
        # arithmetic artifact). Bennett-583s / CW-D now ADMITS that ptrtoint as a
        # base-cancelling cell identity, so the extract advances PAST it to the
        # NEXT deeper wall: a `store { ptr, ptr } %memory_ref, ptr
        # %"box::GenericMemoryRef"` in the `%oob` block — a non-integer
        # (StructType) store rejected by Bennett-lgzx / U114. Under DEFAULT
        # bounds-checking that ptrtoint (and this store) is absent and the extract
        # completes. So we probe and:
        #   * if extraction SUCCEEDS (default bounds mode) — assert the full
        #     59zi-specific extraction shape (ret_width 72, one recursive IRCall,
        #     six value-bearing IRRets);
        #   * if it throws (check-bounds=yes mode) — accept it as a known deeper
        #     wall and assert the message is the U114 non-integer-struct-store
        #     reject (Bennett-583s's successor), NOT a 59zi memcpy wall (which
        #     would mean 59zi is incomplete) and NOT the now-CLEARED iwo9/583s
        #     ptrtoint reject (which would mean 583s did not land). The deeper
        #     U114 struct-store wall is filed as a follow-up bead.
        local pir = nothing
        local threw = nothing
        try
            pir = extract_parsed_ir(Base.ht_keyindex2_shorthash!,
                      Tuple{Dict{Int8,Int8},Int8}; optimize=false, ptr_cells=true)
        catch e
            e isa InterruptException && rethrow()
            threw = e
        end
        if pir !== nothing
            # Default bounds mode: both 59zi walls cleared, full extract succeeds.
            @test pir.ret_width == 72
            @test pir.ret_elem_widths == [64, 8]
            # Exactly one recursive self-IRCall (the L171 tail).
            rec = [i for b in pir.blocks for i in _block_insts(b)
                   if i isa IRCall && i.callee === Base.ht_keyindex2_shorthash!]
            @test length(rec) == 1
            @test rec[1].ret_width == 72
            # Bennett-416r.17: the recursive-call forwarding path must carry the
            # h::Dict pointer operand as a 64-bit cell (was silently dropped by
            # the integer-only loop ⇒ arg_widths [8]). Correct shape [h, key].
            @test rec[1].arg_widths == [64, 8]
            # Five store-arm IRRets + one call-arm IRRet = six value-bearing returns.
            @test _n_ret_blocks(pir) == 6
        else
            # check-bounds=yes mode: both 59zi memcpy walls are CLEARED, AND the
            # once-deeper iwo9/583s `ptrtoint %memory_data` wall is now ADMITTED
            # (Bennett-583s). The extract advances to the next deeper wall: the
            # `store { ptr, ptr } … %"box::GenericMemoryRef"` non-integer-struct
            # store rejected by Bennett-lgzx / U114. Assert the failure IS that
            # U114 struct-store reject (583s's successor), and is NOT a
            # 59zi/sret-memcpy wall (would mean 59zi incomplete) and NOT the now-
            # cleared iwo9/583s ptrtoint reject (would mean 583s didn't land).
            msg = sprint(showerror, threw)
            @test occursin("U114", msg) ||
                  (occursin("store", lowercase(msg)) &&
                   occursin("structtype", lowercase(msg)))
            # The 583s ptrtoint wall is CLEARED — the deeper wall is NOT a
            # ptrtoint reject anymore (proving 583s admitted the .data ptrtoint).
            @test !occursin("583s / CW-D", msg)
            @test !occursin("iwo9", msg)
            @test !occursin("sret with llvm.memcpy", msg)   # Wall A gone
            @test !occursin("dst operand is not alloca-backed", msg)  # Wall B gone
        end
        # NOTE (Rule 1 honesty): this is EXTRACTION-SHAPE-ONLY regardless of mode.
        # ht_keyindex2 is self-recursive; reversible_compile(...) would recurse
        # unboundedly in lower_call!. End-to-end lowering is deferred (self-
        # recursive-callee inlining bead) and still gated on 6x2w (pgcstack) +
        # lf14 (ptr-return) per worklog 086. The deeper iwo9 ptrtoint-on-
        # %memory_data wall (under check-bounds=yes) is a separate follow-up bead.
    end
end
