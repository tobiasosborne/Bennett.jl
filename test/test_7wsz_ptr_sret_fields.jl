# Bennett-7wsz — pointer-typed sret STRUCT FIELDS under the `ptr_cells` gate.
#
# CONTEXT. Bennett-dv1z taught the extractor to model a heterogeneous
# bits-struct sret pointee (`{i64,i8}`) as a packed integer aggregate. It
# deliberately rejected any non-integer field, pointer fields included. That
# reject is the wall the P0 `bennettvm-xkl` chain hit after Bennett-40ys:
# Julia's outlined `_growend!` closure returns a `MemoryRef` — LLVM
# `sret({ptr,ptr})` — so BOTH the closure (callee-side `_detect_sret`) and its
# caller (caller-side 416r.16 `_collect_consumed_sret`) died at
# `_sret_struct_fields`.
#
# THIS BEAD. Under `ptr_cells=true` (and ONLY there) a pointer sret field is
# admitted as ONE 64-bit VM cell — the identical value class a `ptr` argument,
# a `ptr` return (ADR 0020 D3) and a `ptr` load/store (D4) already carry. Two
# admission arms are needed, not one:
#   1. `_sret_struct_fields`  — the field-layout predicate (both entry paths);
#   2. `_try_handle_sret_scalar_store!` — `store ptr` into an sret field, which
#      is exactly what Julia emits once the pipeline's auto-SROA canonicalises
#      the O0 `alloca`+`memcpy` form. Without arm 2 `push!` re-walls ONE
#      instruction later.
#
# THE GATE IS A CORRECTNESS REQUIREMENT, not a style choice. An un-gated
# admission was demonstrated live (proposal A §3.4) to extract a ptr-field sret
# callee at `ptr_cells=false` with `ret_width=192` — on the CIRCUIT path, where
# pointer args are DROPPED from `ParsedIR.args`, i.e. a silent miscompile. The
# `ptr_cells=false` message must stay byte-identical (five test files pin it).
#
# `return_roots` IS MODELLED VERBATIM — see the anti-fusion testset below and
# the SEMANTICS block in src/extract/sret.jl.

using Test
using Bennett
using Bennett: extract_parsed_ir, extract_parsed_ir_from_ll,
               extract_parsed_ir_set_from_julia,
               ParsedIR, IRCall, IRAlloca, IRLoad, IRStore, IRExtractValue,
               IRInsertBits, IRRet, IRPtrOffset,
               SSAOperand, ConstOperand, ZERO_AGG

# x86-64 SysV datalayout (matches Julia's) so the `_sret_struct_fields`
# offsetof/sizeof datalayout queries resolve on the synthetic .ll fixtures.
const _7wsz_dl = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"

function _7wsz_write_ll(body::String)
    path = tempname() * ".ll"
    open(path, "w") do io
        write(io, "target datalayout = \"$_7wsz_dl\"\n\n")
        write(io, body)
    end
    return path
end

# Extract an .ll body, returning the ParsedIR (throws on reject).
function _7wsz_extract(body::String, entry::String; ptr_cells::Bool=true)
    path = _7wsz_write_ll(body)
    try
        return extract_parsed_ir_from_ll(path; entry_function=entry,
                                          ptr_cells=ptr_cells)
    finally
        rm(path; force=true)
    end
end

# Assert an .ll body rejects with `needle` in the message.
function _7wsz_reject(body::String, entry::String, needle::String;
                      ptr_cells::Bool=true)
    e = try
        _7wsz_extract(body, entry; ptr_cells=ptr_cells)
        nothing
    catch err
        err
    end
    @test e !== nothing
    msg = e isa ErrorException ? e.msg : sprint(showerror, e)
    @test occursin(needle, msg)
    return msg
end

_7wsz_insts(pir) = [i for b in pir.blocks for i in b.instructions]

# ---------------------------------------------------------------------------
# Julia fixtures. The pointer is taken as a PARAMETER and NEVER dereferenced:
#   * a parameter avoids `Ptr{Int64}(x)` → `inttoptr`, which walls at the
#     PRE-EXISTING Bennett-iwo9 determinism guard (a fixture artefact, not a
#     7wsz wall — proposal B §1.3);
#   * never dereferencing keeps the cell value arbitrary, so the native oracle
#     `_use7wsz(Ptr{Int64}(0), 5) == 7` is exactly reproducible on the VM.
# ---------------------------------------------------------------------------
struct _P7wsz
    p::Ptr{Int64}
    a::Int64
end
@noinline _mk7wsz(p::Ptr{Int64}, x::Int64) = _P7wsz(p, x + 1)
_use7wsz(p::Ptr{Int64}, x::Int64) = (r = _mk7wsz(p, x); r.a + 1)

# The canonical P0 repro (mirrors test_40ys_instanceless_callees.jl).
_push7wsz(n::Int64) = (v = Int64[]; push!(v, n); @inbounds v[1])

# Hand-built `return_roots` split-roots pair (testset (E) / (E2)) — mirrors the
# `_growend!` closure's ABI verbatim: sret({ptr,ptr}) + an ordinary
# `return_roots` out-pointer + the `i64 -1` sentinel in the tracked slot.
const _7wsz_rr_mod = """
define void @rr_callee(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %sret_return, ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %return_roots, ptr %data, ptr %mem) {
top:
  store ptr %data, ptr %sret_return, align 8
  store ptr %mem, ptr %return_roots, align 8
  %g = getelementptr inbounds i8, ptr %sret_return, i64 8
  store i64 -1, ptr %g, align 8
  ret void
}

define i64 @rr_caller(ptr %data, ptr %mem) {
top:
  %box = alloca [2 x i64], align 8
  %rr = alloca ptr, align 8
  call void @rr_callee(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %box, ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %rr, ptr %data, ptr %mem)
  %f0 = load i64, ptr %box, align 8
  %g1 = getelementptr inbounds i8, ptr %box, i64 8
  %f1 = load i64, ptr %g1, align 8
  %r0 = load i64, ptr %rr, align 8
  %s = add i64 %f0, %r0
  %s2 = add i64 %s, %f1
  ret i64 %s2
}
"""

@testset "Bennett-7wsz ptr-typed sret struct fields" begin

    # =====================================================================
    # (A) CALLEE-SIDE admission — `_detect_sret` → `_sret_struct_fields`.
    # =====================================================================
    @testset "(A) callee: sret({ptr,i64}) extracts as two 64-bit cells" begin
        pir = extract_parsed_ir(_mk7wsz, Tuple{Ptr{Int64}, Int64};
                                ptr_cells=true)
        @test pir.ret_elem_widths == [64, 64]
        @test pir.ret_width == 128

        ibs = [i for i in _7wsz_insts(pir) if i isa IRInsertBits]
        @test length(ibs) == 2
        # ZERO_AGG-rooted, ascending-contiguous — the invariant BVM's
        # IRInsertBits ingest arm asserts.
        @test ibs[1].agg === ZERO_AGG
        @test ibs[1].bit_offset == 0 && ibs[1].val_width == 64
        @test ibs[1].total_width == 128
        @test ibs[2].agg isa SSAOperand && ibs[2].agg.name == ibs[1].dest
        @test ibs[2].bit_offset == 64 && ibs[2].val_width == 64
        @test ibs[2].total_width == 128
        # field 0 IS the pointer parameter, carried through as a cell.
        @test ibs[1].val isa SSAOperand
        @test occursin("p", String(ibs[1].val.name))

        term = last(pir.blocks).terminator
        @test term isa IRRet
        @test term.width == 128
    end

    # =====================================================================
    # (B) CALLER-SIDE admission — 416r.16 consumed-sret box.
    # =====================================================================
    @testset "(B) caller: consumed box → IRCall(128) + IRExtractValue" begin
        pir = extract_parsed_ir(_use7wsz, Tuple{Ptr{Int64}, Int64};
                                ptr_cells=true)
        @test pir.ret_width == 64
        insts = _7wsz_insts(pir)
        calls = [i for i in insts if i isa IRCall]
        @test length(calls) == 1
        @test calls[1].ret_width == 128
        evs = [i for i in insts if i isa IRExtractValue]
        @test length(evs) == 1
        @test evs[1].index == 1                 # the Int64 field
        @test evs[1].n_elems == 2
        @test evs[1].field_widths == [64, 64]
        @test evs[1].agg isa SSAOperand && evs[1].agg.name == calls[1].dest
        # the sret-out box alloca is SUPPRESSED (not modelled as memory)
        @test !any(i -> i isa IRAlloca && occursin("box", String(i.dest)), insts)
    end

    # =====================================================================
    # (C) THE GATE — `ptr_cells=false` byte-identical reject (the firewall).
    #     R1: an un-gated admission silently miscompiles the circuit path.
    # =====================================================================
    @testset "(C) GATE: ptr_cells=false still rejects, message unchanged" begin
        for (f, sig) in ((_mk7wsz, Tuple{Ptr{Int64}, Int64}),)
            e = try
                extract_parsed_ir(f, sig)          # default ptr_cells=false
                nothing
            catch err
                err
            end
            @test e !== nothing
            msg = e isa ErrorException ? e.msg : sprint(showerror, e)
            @test occursin("sret struct field 0 has type", msg)
            @test occursin("only fixed-width integer bits-struct fields are supported",
                           msg)
            @test occursin("Bennett-dv1z", msg)
        end
        # .ll form of the same gate — the exact dv1z legacy shape.
        _7wsz_reject("""
        define void @g_ptrfield(ptr sret({i64, ptr}) %out, i64 %x) {
        top:
          store i64 %x, ptr %out, align 8
          %g = getelementptr inbounds i8, ptr %out, i64 8
          store i64 0, ptr %g, align 8
          ret void
        }
        """, "g_ptrfield", "Bennett-dv1z"; ptr_cells=false)
    end

    # =====================================================================
    # (D) Still-rejected field shapes UNDER ptr_cells=true. Only PointerType
    #     is newly admitted; everything else keeps its dv1z breadcrumb.
    # =====================================================================
    @testset "(D) non-pointer bad fields still reject under ptr_cells=true" begin
        _7wsz_reject("""
        define void @d_float(ptr sret({i64, float}) %out, i64 %x) {
        top:
          store i64 %x, ptr %out, align 8
          ret void
        }
        """, "d_float", "Bennett-dv1z")

        _7wsz_reject("""
        define void @d_vec(ptr sret({i64, <2 x i32>}) %out, i64 %x) {
        top:
          store i64 %x, ptr %out, align 8
          ret void
        }
        """, "d_vec", "Bennett-dv1z")

        _7wsz_reject("""
        define void @d_nested(ptr sret({i64, {i8, i8}}) %out, i64 %x) {
        top:
          store i64 %x, ptr %out, align 8
          ret void
        }
        """, "d_nested", "Bennett-dv1z")

        _7wsz_reject("""
        define void @d_i7(ptr sret({i7}) %out, i7 %x) {
        top:
          store i7 %x, ptr %out, align 1
          ret void
        }
        """, "d_i7", "Bennett-dv1z")

        # DELIBERATE ASYMMETRY, not an oversight: the HOMOGENEOUS `[N x iM]`
        # arm of `_detect_sret` is untouched, so `[2 x ptr]` still rejects even
        # under the gate. No shape in the corpus produces it (every observed
        # ptr-field sret pointee is a `StructType`), and Rule 9 forbids
        # speculative admission. If one ever appears, admit it THERE, with a
        # fixture.
        _7wsz_reject("""
        define void @d_arr_ptr(ptr sret([2 x ptr]) %out, i64 %x) {
        top:
          store i64 %x, ptr %out, align 8
          ret void
        }
        """, "d_arr_ptr", "float/pointer sret aggregates are not supported")

        # NEW reject: a non-default address space is NOT a flat cell.
        _7wsz_reject("""
        define void @d_as10(ptr sret({ptr addrspace(10), i64}) %out, i64 %x) {
        top:
          %g = getelementptr inbounds i8, ptr %out, i64 8
          store i64 %x, ptr %g, align 8
          ret void
        }
        """, "d_as10", "Bennett-7wsz")
    end

    # =====================================================================
    # (E) ANTI-FUSION PIN — `return_roots` is modelled VERBATIM.
    #
    #     Julia splits a GC-tracked aggregate return: the tracked pointer goes
    #     to an ordinary `return_roots` out-pointer param, and the matching
    #     sret slot receives the literal `i64 -1` sentinel. The CALLER
    #     reassembles (proven by the jfptr wrapper: `sret_box+8` — the
    #     sentinel — is never read; field 1 of the boxed value comes from
    #     `load return_roots[0]`).
    #
    #     THIS TEST EXISTS SO A FUTURE "HELPFUL" FUSION GOES RED. Splicing
    #     return_roots into the sret aggregate would require guessing the
    #     slot↔root pairing from sentinel-store detection — a heuristic
    #     sitting directly on a returned POINTER, i.e. a silent miscompile
    #     if it is backwards. See the SEMANTICS block in src/extract/sret.jl.
    # =====================================================================
    @testset "(E) return_roots modelled verbatim — NO fusion" begin
        pir = _7wsz_extract(_7wsz_rr_mod, "rr_callee")
        @test pir.ret_width == 128
        @test pir.ret_elem_widths == [64, 64]
        # `return_roots` is an ORDINARY 64-bit cell parameter — not elided,
        # not special-cased. (The sret-out param IS elided by its attribute.)
        @test (:return_roots, 64) in pir.args
        @test !any(a -> a[1] === :sret_return, pir.args)

        insts = _7wsz_insts(pir)
        # ... written through with a plain 64-bit cell store.
        sts = [i for i in insts if i isa IRStore]
        @test length(sts) == 1
        @test sts[1].width == 64
        @test sts[1].ptr isa SSAOperand && sts[1].ptr.name === :return_roots

        # ... and the sret slot keeps the literal -1 SENTINEL.
        ibs = [i for i in insts if i isa IRInsertBits]
        @test length(ibs) == 2
        @test ibs[2].bit_offset == 64
        @test ibs[2].val isa ConstOperand
        @test ibs[2].val.value == -1
    end

    @testset "(E2) caller reads the sentinel slot — it IS -1, faithfully" begin
        pir = _7wsz_extract(_7wsz_rr_mod, "rr_caller")
        @test pir.ret_width == 64
        insts = _7wsz_insts(pir)
        calls = [i for i in insts if i isa IRCall]
        @test length(calls) == 1
        @test calls[1].ret_width == 128
        @test calls[1].arg_widths == [64, 64, 64]     # rr, data, mem
        evs = [i for i in insts if i isa IRExtractValue]
        @test length(evs) == 2
        @test sort([e.index for e in evs]) == [0, 1]
        @test all(e -> e.field_widths == [64, 64], evs)
        # return_roots is read back with a PLAIN load off the caller's alloca.
        lds = [i for i in insts if i isa IRLoad]
        @test length(lds) == 1
        @test lds[1].width == 64
        @test lds[1].ptr isa SSAOperand && lds[1].ptr.name === :rr
        @test any(i -> i isa IRAlloca && i.dest === :rr, insts)
    end

    # =====================================================================
    # (F) DEAD-BOX caller — the `push!` ROOT shape. `%sret_box` has exactly
    #     two uses (its alloca and the call), i.e. NO reader. Currently
    #     unpinned; this is the shape the P0 chain actually hits.
    # =====================================================================
    @testset "(F) dead sret box (push!-root shape) still rewrites to value ABI" begin
        pir = _7wsz_extract("""
        declare void @db_callee(ptr sret({ ptr, ptr }), ptr, ptr, ptr)

        define i64 @db_caller(ptr %data, ptr %mem) {
        top:
          %box = alloca [2 x i64], align 8
          %rr = alloca ptr, align 8
          call void @db_callee(ptr noalias nocapture noundef nonnull sret({ ptr, ptr }) align 8 dereferenceable(16) %box, ptr noalias nocapture noundef nonnull align 8 dereferenceable(8) %rr, ptr %data, ptr %mem)
          %r0 = load i64, ptr %rr, align 8
          ret i64 %r0
        }
        """, "db_caller")
        insts = _7wsz_insts(pir)
        calls = [i for i in insts if i isa IRCall]
        @test length(calls) == 1
        @test calls[1].ret_width == 128           # Σ field widths, still
        @test isempty([i for i in insts if i isa IRExtractValue])
        # the box alloca is suppressed; the return_roots alloca is NOT
        @test !any(i -> i isa IRAlloca && i.dest === :box, insts)
        @test any(i -> i isa IRAlloca && i.dest === :rr, insts)
    end

    # =====================================================================
    # (G) WIDTH-based field matching, NOT type equality. Julia stores the
    #     literal `i64 -1` into a ptr-TYPED field (split-roots ABI); a
    #     type-equality match re-walls `push!` immediately.
    # =====================================================================
    @testset "(G) store i64 into a ptr field is accepted (width match)" begin
        pir = _7wsz_extract("""
        define void @g_i64_into_ptr(ptr sret({ ptr, i64 }) %out, i64 %x) {
        top:
          store i64 -1, ptr %out, align 8
          %g = getelementptr inbounds i8, ptr %out, i64 8
          store i64 %x, ptr %g, align 8
          ret void
        }
        """, "g_i64_into_ptr")
        @test pir.ret_width == 128
        ibs = [i for i in _7wsz_insts(pir) if i isa IRInsertBits]
        @test length(ibs) == 2
        @test ibs[1].val isa ConstOperand && ibs[1].val.value == -1
    end

    @testset "(G2) partial-width store into a ptr field still rejects" begin
        _7wsz_reject("""
        define void @g_i32_into_ptr(ptr sret({ ptr, i64 }) %out, i32 %x) {
        top:
          store i32 %x, ptr %out, align 8
          %g = getelementptr inbounds i8, ptr %out, i64 8
          store i64 0, ptr %g, align 8
          ret void
        }
        """, "g_i32_into_ptr", "partial-field writes are not supported")
    end

    # =====================================================================
    # (H) `store ptr null` into a ptr sret field → the ZERO cell. Pins the
    #     `_operand(...; ptr_cells)` thread (Bennett-beaw); without the kwarg
    #     this hits the U80 ConstantPointerNull fail-loud.
    # =====================================================================
    @testset "(H) store ptr null into a ptr field → zero cell" begin
        pir = _7wsz_extract("""
        define void @h_null(ptr sret({ ptr, i64 }) %out, i64 %x) {
        top:
          store ptr null, ptr %out, align 8
          %g = getelementptr inbounds i8, ptr %out, i64 8
          store i64 %x, ptr %g, align 8
          ret void
        }
        """, "h_null")
        ibs = [i for i in _7wsz_insts(pir) if i isa IRInsertBits]
        @test length(ibs) == 2
        @test ibs[1].val isa ConstOperand && ibs[1].val.value == 0
    end

    # =====================================================================
    # (H2) FORWARDING regression (Bennett-59zi Wall A). A parent sret whose
    #      return is "the aggregate a CHILD sret call produced" derives its
    #      `ret_width` from `sum(field widths)` too — 128, not the 72-era
    #      shape and not the 16-byte ABI size. No corpus instance carries ptr
    #      fields through this path yet, so it is pinned here so it cannot
    #      silently rot.
    # =====================================================================
    @testset "(H2) forwarded ptr-field sret keeps ret_width = Σ field widths" begin
        pir = _7wsz_extract("""
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        declare void @fw_child(ptr sret({ ptr, i64 }), i64)

        define void @fw_parent(ptr noalias nocapture sret({ ptr, i64 }) align 8 %out, i64 %x) {
        top:
          %box = alloca [2 x i64], align 8
          call void @fw_child(ptr noalias nocapture sret({ ptr, i64 }) align 8 %box, i64 %x)
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 %box, i64 16, i1 false)
          ret void
        }
        """, "fw_parent")
        @test pir.ret_width == 128
        @test pir.ret_elem_widths == [64, 64]
        call = only(i for i in _7wsz_insts(pir) if i isa IRCall)
        @test call.ret_width == 128
        term = last(pir.blocks).terminator
        @test term isa IRRet && term.width == 128
        @test term.op isa SSAOperand && term.op.name == call.dest
    end

    # =====================================================================
    # (I) CLOSED-WORLD SET — the shape BennettVM ingests (E2E in BVM's
    #     test_7wsz_ptr_sret_vm.jl).
    # =====================================================================
    @testset "(I) closed-world set: caller + ptr-field-sret callee" begin
        set = extract_parsed_ir_set_from_julia(_use7wsz,
                                               Tuple{Ptr{Int64}, Int64};
                                               ptr_cells=true)
        @test length(set) == 2
        ks = String.(first.(set))
        @test any(k -> startswith(k, "_use7wsz#"), ks)
        @test any(k -> startswith(k, "_mk7wsz#"), ks)
        callee = last(set[findfirst(k -> startswith(String(k), "_mk7wsz#"),
                                    first.(set))])
        @test callee.ret_width == 128
        @test callee.ret_elem_widths == [64, 64]
    end

    # =====================================================================
    # (J) WALL MARKER — `push!` advances PAST the dv1z sret wall.
    #
    #     This does NOT assert push! compiles: it asserts the FRONTIER MOVED.
    #     The landing message is an occursin-DISJUNCTION over both successor
    #     walls (which body fails first depends on registration/iteration
    #     order, which is not a contract — the test_lf14 convention).
    #     When the next bead lands this goes red: ADVANCE it, don't delete it.
    # =====================================================================
    @testset "(J) push! advances past the dv1z sret wall" begin
        e = try
            extract_parsed_ir_set_from_julia(_push7wsz, Tuple{Int64};
                                              ptr_cells=true)
            nothing
        catch err
            err
        end
        @test e !== nothing
        @test !(e isa UndefRefError)
        msg = e isa ErrorException ? e.msg : sprint(showerror, e)
        # the OLD wall is gone
        @test !occursin("Bennett-dv1z", msg)
        @test !occursin("sret struct field", msg)
        # ... and we land on one of the two NAMED successor walls:
        #   ROOT    — U114 whole-struct `store { ptr, ptr }`
        #   CLOSURE — unrecognised Julia JIT global @jl_diverror_exception
        @test occursin("jl_diverror_exception", msg) ||
              occursin("UNRECOGNIZED Julia JIT global", msg) ||
              occursin("Bennett-lgzx", msg) ||
              occursin("U114", msg) ||
              occursin("StructType", msg)
    end

    # =====================================================================
    # (J2) The push! ROOT's own landing wall.
    #
    #     MEASURED, not predicted. Both 7wsz design proposals forecast the
    #     root would land on the U114 whole-struct `store { ptr, ptr }` — that
    #     forecast came from an UNGATED in-memory probe. With the (mandatory)
    #     gate in place the root's `ptr_cells=true` body walk now starts, and
    #     dies on its very FIRST instruction: the `movq %fs:0` pgcstack read
    #     (Bennett-5oyt / U15), long before the Array-header store. Reaching
    #     U114 would require pgcstack handling (`mem=:heap`/`:vm`), which is
    #     not this bead. Disjunction over both so the flip is deliberate.
    # =====================================================================
    @testset "(J2) push! ROOT advances past the dv1z sret pre-walk" begin
        e = try
            extract_parsed_ir(_push7wsz, Tuple{Int64}; ptr_cells=true)
            nothing
        catch err
            err
        end
        @test e !== nothing
        msg = e isa ErrorException ? e.msg : sprint(showerror, e)
        @test !occursin("Bennett-dv1z", msg)
        @test !occursin("sret struct field", msg)
        @test occursin("Bennett-5oyt", msg) || occursin("U15", msg) ||
              occursin("Bennett-lgzx", msg) || occursin("U114", msg)
    end
end
