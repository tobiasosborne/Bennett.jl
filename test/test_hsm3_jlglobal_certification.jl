# test_hsm3_jlglobal_certification.jl — bead `Bennett-hsm3` (P1; + Bennett-gcf7
# D1/D2/D3/D4 and Bennett-fnxh / O1): SEMANTIC certification of Julia's
# interned heap literals `@"jl_global#N"` under the closed-world `ptr_cells`
# gate.
#
# # The defect (gcf7 hostile review of 5viz, executed on BennettVM)
#
# Julia's codegen names EVERY interned heap literal `@"jl_global#N"` — a
# `const Ref(…)`, a struct/tuple box, a `String`, a non-empty `Memory`, … — and
# the empty-`GenericMemory` singleton is only ONE of them. Before this bead
# three consumers trusted the NAME (`_is_singleton_data_global_name`, a regex):
# `_extract_const_globals` seeded a 16-byte ZERO blob for every such global, the
# `_handle_load` alias arm aliased every such load onto it, and 5viz's
# `_5viz_singleton_load` admitted it as a memcpy src. So
#
#     const RI = Ref(42); h3(x::Int) = RI[] + x
#
# extracted as `IRLoad(.x, jl_global#N, 64)` off the zero blob and BennettVM
# returned 0/10/-5 against the oracle 42/52/37 — and REVERSED CLEANLY. A silent
# miscompile of ordinary Julia code.
#
# # The fix (orchestrator review, docs/design/hsm3/orchestrator_review.md)
#
#   1. CLASSIFIER — a MEMBERSHIP test, never a dereference: in the producing
#      Julia session, inside a GC-disabled window opened before IR emission,
#      the literal's address K is admitted iff K is the address of a LIVE empty
#      `GenericMemory` singleton (`T.instance` enumerated from the GenericMemory
#      TypeName caches). Two live objects cannot share an address inside the
#      window, so membership is exact; a garbage / foreign / freed address can
#      never crash it.
#   2. WHERE IT FAILS — use-directed: certified objects are seeded under
#      `jl_global#N.obj`; after the walk, ANY surviving use of a refused object
#      (or of a raw SLOT name) fails loud naming Bennett-hsm3.
#   3. SLOT GUARDS — a scalar load of the slot, a GEP / array GEP on the slot, a
#      memcpy from the slot fail loud at the site.
#   4. O1 (Bennett-fnxh) — a use straight through `@"jl_global#N.jit"`
#      (optimize=true folded the slot load) fails loud instead of being silently
#      skipped into a dangling operand.
#   5. 5viz consults the certificate; a refused src gets an hsm3 message, never
#      the misleading 37mt text (gcf7 D4 for this class).
#   6. D3 — the certified header's data pointer is the non-null
#      `_EMPTY_MEMORY_DATA_SENTINEL` (inside BennettVM's globals trap band).
#   7. `.ll`/`.bc` ingest certifies NOTHING by default; `jl_globals =
#      :live_session` opts in (the caller asserts the addresses were produced in
#      THIS process — membership is safe even if they were not).
#
# Rule 5: nothing here pins a `#N` number, an instruction order or LLVM
# formatting; every assertion is over extracted IR nodes, `.globals` keys, or
# NON-NUMERAL anchors of fail-loud messages.

using Test
import Bennett
using Bennett: extract_parsed_ir, extract_parsed_ir_from_ll,
               extract_parsed_ir_set_from_ll, extract_parsed_ir_set_from_julia

# ---------------------------------------------------------------------------
# The gcf7 / hsm3 counterexample programs (module-level consts: kept alive for
# the whole session, exactly like a user's `const`).
# ---------------------------------------------------------------------------
struct _Hsm3S2; a::Int; b::Int; end
struct _Hsm3W1; a::Int; end
const _HSM3_R  = Ref(_Hsm3S2(3, 4))
const _HSM3_RW = Ref(_Hsm3W1(42))
const _HSM3_RI = Ref(42)
const _HSM3_T1 = Ref((77,))
const _HSM3_M3 = Memory{Int}([7, 8, 9])
const _HSM3_UM = Memory{Int}(undef, 0)     # the empty singleton, user-held
const _HSM3_EM = Memory{Int}()             # ditto, other constructor
_hsm3_h1(x::Int) = _HSM3_R[].a + x
_hsm3_h2(x::Int) = _HSM3_RW[].a + x
_hsm3_h3(x::Int) = _HSM3_RI[] + x
_hsm3_h4(x::Int) = _HSM3_T1[][1] + x
_hsm3_k1(x::Int) = (b = Ref(_HSM3_RW); b[][].a + x)
_hsm3_m3(x::Int) = length(_HSM3_M3) + x
_hsm3_u1(x::Int) = length(_HSM3_UM) + x
_hsm3_he(x::Int) = length(_HSM3_EM) + x
_hsm3_thr(x::Int) = x > 0 ? x : throw(ArgumentError("negative input"))

const _HSM3_NEGATIVES = (("h1", _hsm3_h1), ("h2", _hsm3_h2), ("h3", _hsm3_h3),
                         ("h4", _hsm3_h4), ("k1", _hsm3_k1), ("m3", _hsm3_m3))

function _hsm3_msg(thunk)
    try
        thunk()
        return ""
    catch e
        e isa InterruptException && rethrow()
        return sprint(showerror, e)
    end
end

_hsm3_addr(x) = UInt64(UInt(pointer_from_objref(x)))

_hsm3_objkeys(pir) = sort([k for k in keys(pir.globals) if endswith(String(k), ".obj")])
_hsm3_jlkeys(pir)  = sort([k for k in keys(pir.globals) if occursin("jl_global", String(k))])

function _hsm3_ll(ir::AbstractString, fn::AbstractString; kw...)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function = fn, kw...)
    end
end
_hsm3_ll_msg(ir, fn; kw...) = _hsm3_msg(() -> _hsm3_ll(ir, fn; kw...))

_hsm3_insts(pir) = reduce(vcat, [b.instructions for b in pir.blocks];
                          init = Bennett.IRInst[])

# A slot-defined `.ll` fixture. `init` is the slot's initializer spelling.
_hsm3_slot(init::AbstractString) =
    "@\"jl_global#7\" = private unnamed_addr constant ptr $(init)\n"
_hsm3_slot_addr(K::Integer) = _hsm3_slot("inttoptr (i64 $(K) to ptr)")

# `length(mem)` off the loaded literal — the m3/u1 shape, hand-written.
_hsm3_len_ll(slot::AbstractString) = slot * """
define i64 @len(i64 %x) {
top:
  %g = load ptr, ptr @"jl_global#7", align 8
  %n = load i64, ptr %g, align 8
  %r = add i64 %n, %x
  ret i64 %r
}
"""

@testset "Bennett-hsm3 — semantic certification of jl_global#N literals" begin

    # ======================================================================
    # (T1) CLASSIFIER UNITS — membership in the live empty-singleton set.
    # ======================================================================
    @testset "(T1) live empty-GenericMemory singleton set" begin
        # every length-0 allocation of a concrete T IS T.instance
        @test Memory{Int}() === Memory{Int}.instance              # canary
        @test Memory{Int}() !== Memory{UInt8}()                    # distinct per T
        xs = (Memory{Int8}(), Memory{Int64}(), Memory{UInt8}(),
              Memory{Union{Int,Nothing}}(),
              GenericMemory{:atomic,Int,Core.CPU}(undef, 0),
              Memory{_Hsm3S2}(undef, 0),                       # a FRESH type
              Int[].ref.mem)
        # The enumeration is a LIVE SNAPSHOT: a type instantiated after it was
        # taken is not in it (measured — the first draft of this gate enumerated
        # BEFORE building `xs` and missed the three fresh types). The producers
        # enumerate AFTER emission, inside the GC window, so every singleton
        # codegen could have named is already instantiated.
        S = Bennett._live_empty_memory_singletons()
        for x in xs
            @test haskey(S, _hsm3_addr(x))
        end
        # near-misses: NOT the singleton
        wrap0 = unsafe_wrap(Memory{Int}, pointer(Memory{Int}(undef, 4)), 0; own = false)
        @test wrap0 !== Memory{Int}.instance
        big = Memory{Nothing}(undef, 5)
        for x in (_HSM3_RI, _HSM3_R, _HSM3_M3, wrap0, big, "a string",
                  Ref(0), Int[1, 2])
            GC.@preserve x begin
                @test !haskey(S, UInt64(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x))))
            end
        end
        # the data pointer is non-null (D3 — the reason the sentinel exists)
        @test all(f -> f.data_nonnull, values(S))
        # tripwire: the NAME predicate is gone for good
        @test !isdefined(Bennett, :_is_singleton_data_global_name)
    end

    @testset "(T1b) six-address module — never dereferenced, never crashes" begin
        buf = Vector{UInt8}(undef, 64)
        m = Libc.malloc(64)
        live_ref = Ref(42)
        try
            GC.@preserve buf live_ref begin
                addrs = UInt64[0x10, 0xfffffffffffffff8, UInt64(UInt(m)),
                               UInt64(UInt(pointer(buf))), _hsm3_addr(live_ref),
                               _hsm3_addr(Memory{Int64}())]
                ir = join(["@\"jl_global#$(i)\" = private unnamed_addr constant ptr " *
                           "inttoptr (i64 $(a) to ptr)" for (i, a) in enumerate(addrs)], "\n") *
                     "\ndefine i64 @f() {\ntop:\n  ret i64 0\n}\n"
                certs = Bennett._classify_jl_globals_ir(ir; live = true)
                @test length(certs) == 6
                @test [certs["jl_global#$(i)"].certified for i in 1:6] ==
                      [false, false, false, false, false, true]
                @test occursin("NOT the empty GenericMemory singleton",
                               certs["jl_global#5"].desc)
                # without a live session NOTHING is certified, not even the singleton
                certs0 = Bennett._classify_jl_globals_ir(ir; live = false)
                @test !any(c -> c.certified, values(certs0))
            end
        finally
            Libc.free(m)
        end
    end

    # ======================================================================
    # (T2) THE COUNTEREXAMPLES — every non-singleton literal fails loud.
    # ======================================================================
    @testset "(T2) gcf7/hsm3 counterexamples fail loud (set producer)" begin
        for (nm, f) in _HSM3_NEGATIVES
            msg = _hsm3_msg(() -> extract_parsed_ir_set_from_julia(f, Tuple{Int};
                                                                   ptr_cells = true))
            @test msg != ""
            @test occursin("Bennett-hsm3", msg)
            @test occursin("NOT the empty GenericMemory singleton", msg)
            # never the misleading 37mt "not alloca-backed" text (gcf7 D4)
            @test !occursin("Bennett-37mt", msg)
        end
    end

    @testset "(T2b) counterexamples fail loud (single-function producer)" begin
        for (nm, f) in _HSM3_NEGATIVES
            msg = _hsm3_msg(() -> extract_parsed_ir(f, Tuple{Int}; ptr_cells = true,
                                                    optimize = false))
            @test occursin("Bennett-hsm3", msg)
        end
        # best-effort diagnostics name the literal's type (no dereference: the
        # type comes from the inferred source's literal table)
        msg = _hsm3_msg(() -> extract_parsed_ir(_hsm3_h3, Tuple{Int}; ptr_cells = true,
                                                optimize = false))
        @test occursin("RefValue", msg)
        msg = _hsm3_msg(() -> extract_parsed_ir(_hsm3_m3, Tuple{Int}; ptr_cells = true,
                                                optimize = false))
        @test occursin("Memory", msg)
    end

    # ======================================================================
    # (T3) POSITIVES — the empty singleton is admitted, semantically.
    # ======================================================================
    @testset "(T3) user-held empty Memory is certified (u1 / he)" begin
        for f in (_hsm3_u1, _hsm3_he)
            set = extract_parsed_ir_set_from_julia(f, Tuple{Int}; ptr_cells = true)
            root = first(set).second
            ks = _hsm3_objkeys(root)
            @test length(ks) == 1
            @test _hsm3_jlkeys(root) == ks                  # no raw slot keys
            data, ew = root.globals[only(ks)]
            @test ew == 8
            @test length(data) == 16
            @test data[1] == 0                              # length@0
            @test data[9] == Bennett._EMPTY_MEMORY_DATA_SENTINEL   # data-ptr@8 (D3)
            @test all(==(0), data[[2:8; 10:16]])
            # the length read is addressed off the OBJECT key
            @test any(i -> i isa Bennett.IRLoad && i.ptr isa Bennett.SSAOperand &&
                           i.ptr.name === only(ks), _hsm3_insts(root))
        end
        @test Bennett._EMPTY_MEMORY_DATA_SENTINEL != 0
    end

    @testset "(T3b) throw-path String literal is not seeded (thr)" begin
        set = extract_parsed_ir_set_from_julia(_hsm3_thr, Tuple{Int}; ptr_cells = true)
        for (_, pir) in set
            @test isempty(_hsm3_jlkeys(pir))
        end
    end

    @testset "(T3c) fdict root: only certified .obj keys" begin
        fdict(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = extract_parsed_ir_set_from_julia(fdict, Tuple{Int8,Int8}; ptr_cells = true)
        root = first(set).second
        @test !isempty(_hsm3_objkeys(root))
        @test _hsm3_jlkeys(root) == _hsm3_objkeys(root)
        for k in _hsm3_objkeys(root)
            @test root.globals[k][1][9] == Bennett._EMPTY_MEMORY_DATA_SENTINEL
        end
    end

    # ======================================================================
    # (T4) .ll / .bc INGEST — refuse by default; `:live_session` opt-in.
    # ======================================================================
    @testset "(T4) .ll ingest: default refuses, :live_session certifies" begin
        K = _hsm3_addr(Memory{Int64}())
        ll = _hsm3_len_ll(_hsm3_slot_addr(K))
        # default: no live session ⇒ nothing certified ⇒ loud at the use
        msg = _hsm3_ll_msg(ll, "len"; ptr_cells = true)
        @test occursin("Bennett-hsm3", msg)
        @test occursin("no live producing Julia session", msg)
        # opt-in: the address IS the live singleton ⇒ certified
        pir = _hsm3_ll(ll, "len"; ptr_cells = true, jl_globals = :live_session)
        @test _hsm3_objkeys(pir) == [Symbol("jl_global#7.obj")]
        @test pir.globals[Symbol("jl_global#7.obj")][1][9] ==
              Bennett._EMPTY_MEMORY_DATA_SENTINEL
        # Julia's real spelling: slot → `.jit` alias → inttoptr
        ll_alias = "@\"jl_global#7.jit\" = private alias ptr, inttoptr (i64 $(K) to ptr)\n" *
                   _hsm3_len_ll(_hsm3_slot("@\"jl_global#7.jit\""))
        pir2 = _hsm3_ll(ll_alias, "len"; ptr_cells = true, jl_globals = :live_session)
        @test _hsm3_objkeys(pir2) == [Symbol("jl_global#7.obj")]
        # a live NON-singleton address is refused even with :live_session
        GC.@preserve _HSM3_RI begin
            llr = _hsm3_len_ll(_hsm3_slot_addr(_hsm3_addr(_HSM3_RI)))
            msg = _hsm3_ll_msg(llr, "len"; ptr_cells = true, jl_globals = :live_session)
            @test occursin("Bennett-hsm3", msg)
            @test occursin("NOT the empty GenericMemory singleton", msg)
        end
        # `external` (imaging-mode spelling) and `null` slots have no address
        for slot in ("@\"jl_global#7\" = external constant ptr\n",
                     _hsm3_slot("null"))
            msg = _hsm3_ll_msg(_hsm3_len_ll(slot), "len"; ptr_cells = true,
                               jl_globals = :live_session)
            @test occursin("Bennett-hsm3", msg)
        end
        # bad kwarg value
        @test_throws ArgumentError _hsm3_ll(ll, "len"; ptr_cells = true,
                                            jl_globals = :yes_please)
        # circuit path: classification never runs (byte-identical)
        @test _hsm3_ll_msg(ll, "len"; ptr_cells = false) == ""
    end

    @testset "(T4b) two slots, one address ⇒ one object key" begin
        K = _hsm3_addr(Memory{Int64}())
        ll = """
        @"jl_global#7" = private unnamed_addr constant ptr inttoptr (i64 $(K) to ptr)
        @"jl_global#8" = private unnamed_addr constant ptr inttoptr (i64 $(K) to ptr)
        define i64 @two(i64 %x) {
        top:
          %a = load ptr, ptr @"jl_global#7", align 8
          %b = load ptr, ptr @"jl_global#8", align 8
          %na = load i64, ptr %a, align 8
          %nb = load i64, ptr %b, align 8
          %r = add i64 %na, %nb
          ret i64 %r
        }
        """
        pir = _hsm3_ll(ll, "two"; ptr_cells = true, jl_globals = :live_session)
        ks = _hsm3_objkeys(pir)
        @test length(ks) == 1
        bases = Set(i.ptr.name for i in _hsm3_insts(pir)
                    if i isa Bennett.IRLoad && i.ptr isa Bennett.SSAOperand)
        @test bases == Set(ks)
    end

    @testset "(T4c) set_from_ll honours jl_globals" begin
        K = _hsm3_addr(Memory{Int64}())
        ll = _hsm3_len_ll(_hsm3_slot_addr(K))
        mktempdir() do dir
            path = joinpath(dir, "s.ll")
            write(path, ll)
            @test occursin("Bennett-hsm3",
                           _hsm3_msg(() -> extract_parsed_ir_set_from_ll(path; ptr_cells = true)))
            set = extract_parsed_ir_set_from_ll(path; ptr_cells = true,
                                                jl_globals = :live_session)
            @test _hsm3_objkeys(only(set).second) == [Symbol("jl_global#7.obj")]
        end
    end

    # ======================================================================
    # (T5) SLOT GUARDS — the slot is not the object.
    # ======================================================================
    @testset "(T5) slot/object confusion fails loud" begin
        slot = _hsm3_slot_addr(_hsm3_addr(Memory{Int64}()))
        scalar = slot * """
        define i64 @sc() {
        top:
          %v = load i64, ptr @"jl_global#7", align 8
          ret i64 %v
        }
        """
        gep = slot * """
        define i64 @gp() {
        top:
          %p = getelementptr i8, ptr @"jl_global#7", i64 8
          %v = load i64, ptr %p, align 8
          ret i64 %v
        }
        """
        arr = slot * """
        define i64 @ar(i64 %i) {
        top:
          %p = getelementptr [2 x i64], ptr @"jl_global#7", i64 0, i64 %i
          %v = load i64, ptr %p, align 8
          ret i64 %v
        }
        """
        mcp = slot * """
        declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
        define i64 @mc() {
        top:
          %a = alloca i64, align 8
          call void @llvm.memcpy.p0.p0.i64(ptr align 8 %a, ptr align 8 @"jl_global#7", i64 8, i1 false)
          %v = load i64, ptr %a, align 8
          ret i64 %v
        }
        """
        for (ir, fn) in ((scalar, "sc"), (gep, "gp"), (arr, "ar"), (mcp, "mc"))
            msg = _hsm3_ll_msg(ir, fn; ptr_cells = true, jl_globals = :live_session)
            @test occursin("Bennett-hsm3", msg)
            @test occursin("SLOT", msg)
        end
    end

    # ======================================================================
    # (T6) O1 / Bennett-fnxh — a use straight through the `.jit` alias.
    # ======================================================================
    @testset "(T6) O1: load through @\"jl_global#N.jit\" fails loud" begin
        K = _hsm3_addr(Memory{Int64}())
        ll = "@\"jl_global#7.jit\" = private alias ptr, inttoptr (i64 $(K) to ptr)\n" * """
        define i64 @o1(i64 %x) {
        top:
          %n = load i64, ptr @"jl_global#7.jit", align 8
          %r = add i64 %n, %x
          ret i64 %r
        }
        """
        msg = _hsm3_ll_msg(ll, "o1"; ptr_cells = true, jl_globals = :live_session)
        @test occursin("Bennett-hsm3", msg)
        @test occursin("Bennett-fnxh", msg)
        # the real optimize=true shape: previously a DANGLING operand, silently
        for f in (_hsm3_h2, _hsm3_u1)
            msg = _hsm3_msg(() -> extract_parsed_ir(f, Tuple{Int}; ptr_cells = true,
                                                    optimize = true))
            @test occursin("Bennett-fnxh", msg)
        end
    end

    # ======================================================================
    # (T7) 5viz consults the certificate (gcf7 D1 + D4 for this class).
    # ======================================================================
    @testset "(T7) memcpy src reading a refused literal: hsm3, not 37mt" begin
        GC.@preserve _HSM3_R begin
            ll = _hsm3_slot_addr(_hsm3_addr(_HSM3_R)) * """
            declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
            define i64 @mr(i64 %x) {
            top:
              %g = load ptr, ptr @"jl_global#7", align 8
              %a = alloca [2 x i64], align 8
              call void @llvm.memcpy.p0.p0.i64(ptr align 8 %a, ptr align 8 %g, i64 16, i1 false)
              %v = load i64, ptr %a, align 8
              %r = add i64 %v, %x
              ret i64 %r
            }
            """
            msg = _hsm3_ll_msg(ll, "mr"; ptr_cells = true, jl_globals = :live_session)
            @test occursin("Bennett-hsm3", msg)
            @test occursin("memcpy", msg)
            @test !occursin("Bennett-37mt", msg)
        end
    end

    # ======================================================================
    # (T8) GC window hygiene + cache hygiene.
    # ======================================================================
    @testset "(T8) GC state restored; window returns / rethrows" begin
        extract_parsed_ir_set_from_julia(_hsm3_u1, Tuple{Int}; ptr_cells = true)
        @test GC.enable(true) == true            # it was enabled on return
        @test Bennett._gc_pinned(() -> 41 + 1) == 42
        @test GC.enable(true) == true
        @test_throws ErrorException Bennett._gc_pinned(() -> error("boom"))
        @test GC.enable(true) == true
        _ = _hsm3_msg(() -> extract_parsed_ir(_hsm3_h3, Tuple{Int}; ptr_cells = true,
                                              optimize = false))
        @test GC.enable(true) == true            # restored after a refusal too
        # the ptr_cells=false ParsedIR cache never carries a jl_global key
        for (_, pir) in Bennett._parsed_ir_cache
            @test isempty(_hsm3_jlkeys(pir))
        end
    end
end
