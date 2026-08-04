# test/test_40ys_instanceless_callees.jl — Bennett-40ys
#
# # The bug
#
# `extract_parsed_ir_set_from_julia(f, T)` crashed with a bare
# `UndefRefError: access to undefined reference` — no file, no key, no context —
# for ANY `f` containing `push!`. Root cause (`src/extract/julia_set.jl:100`):
#
#     _callable_of_key(k::Type) = k.instance
#
# `transitive_callees` keys a callee by its `specTypes` head. For a plain
# function that head is a SINGLETON `typeof(g)`, whose `.instance` is `g`. But
# Julia 1.12 OUTLINES `_growend!`'s slow path into a **closure**, so the head is
#
#     Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, Int64, …, MemoryRef{Int64}}
#
# — a concrete callable DataType with EIGHT FIELDS and therefore **no
# `.instance`**. `.instance` on it is an undefined reference. The crash sits in
# the registration loop, OUTSIDE `_extract_one`'s try/catch, so even
# `on_extract_error=:skip` could not rescue it.
#
# # The fix, in one sentence
#
# A callee key's only job is to produce **codegen input**, and Julia's own
# codegen works from a SIGNATURE, not from a value: `InteractiveUtils`'
# `_dump_function` consumes the callable `f` in exactly one place,
# `signature_type(f, t) == Tuple{typeof(f), t...}` — which is precisely the
# `specTypes` the call-graph walker already holds. So `src/extract/sig_llvm.jl`
# reproduces that call sequence MINUS the `signature_type` step
# (`Base._which` → `Base.specialize_method` → `Base.Compiler.typeinf_code` →
# `InteractiveUtils._dump_function_llvm`) and the instance becomes structurally
# unnecessary — for closures AND for functors, which are the same Julia concept
# (a callable type with fields).
#
# # What this file pins (Rule 4 — values and invariants, never "didn't throw")
#
#   (A) CLASSIFIER — `_callee_key_kind` is TOTAL over the key shapes the walker
#       can produce, and every unclassifiable key (including `Core.OpaqueClosure`,
#       which needs a DIFFERENT codegen entry) fails loud naming the key, the
#       kind and the bead. No key shape can reach a bare `UndefRefError`.
#   (B) MECHANISM — `_code_llvm_by_sig(sig)` is byte-equal to `code_llvm`
#       modulo Julia's per-emission `_NNN` / `#NNN` counters, on a plain
#       function, on a NON-dispatch-tuple signature, and on a real closure.
#   (C) REAL CORPUS — the mechanism emits 28 kB of IR for the actual
#       `_growend!` closure key that crashes today, with NO instance anywhere.
#   (D) END-TO-END — `extract_parsed_ir_by_sig` returns a `ParsedIR` for a
#       closure and for a functor given ONLY the type, and the captured state
#       decodes through the existing `IRPtrOffset`/`IRLoad` machinery.
#   (E) NAMING — the barename is `mi.def.name` (what codegen mangles into the
#       LLVM symbol), NOT `nameof(K)` (the closure's TYPE name, which matches no
#       LLVM symbol). The `!=` is pinned so nobody "simplifies" it back.
#   (F) DIGEST — the canonical key digests the FULL specTypes. Two `push!`
#       closures over different element types have `argtypes == Tuple{}` for
#       BOTH, so an argtypes-only digest collides them onto one key.
#   (G) CALL-SITE BINDING — the set is SELF-CONSISTENT: the caller's `IRCall`
#       to an instance-less callee carries the BARE name, not the drift-prone
#       mangled `j_<name>_<NNN>`, so BVM's `_vm_dispatch_name` resolves it
#       against the table key's `_vm_funcname`.
#   (H) REGISTRY HYGIENE — the name registry is restored on BOTH the returning
#       and the throwing path.
#   (I) THE BEAD'S EXIT CRITERION — `push!` no longer `UndefRefError`s; it
#       reaches the NEXT honest wall with that wall's own named message.
#       ADVANCED by Bennett-7wsz (2026-08-04): was Bennett-dv1z
#       (sret-of-pointer), now the unrecognised JIT global
#       `@jl_diverror_exception` (bennettvm-416r.13).
#
# # Honest boundary
#
# `push!` still does NOT extract. Its closure returns `sret({ ptr, ptr })`;
# Bennett-7wsz taught `_sret_struct_fields` to admit ptr fields as 64-bit VM
# cells under `ptr_cells=true`, so the closure now walks its BODY and dies on
# `load ptr, ptr @jl_diverror_exception` (bennettvm-416r.13) instead. The root
# has its own separate wall — the U15 `movq %fs:0` pgcstack read
# (Bennett-5oyt). Gate (I) asserts the wall is REACHED and NAMED; when the
# named wall's bead lands, (I) goes red, which is the signal to advance it to
# the next wall — do not simply delete it.
#
# Fixtures are locally named (`*_40ys`) per the D1a generic-collision lesson
# (`test_d1b_julia_set.jl:31-34`), and no unit gate depends on a Base-internal
# closure name: (C) and (I) are the only ones that touch the real corpus and
# they are marked version-observational.
#
# Ref: `docs/design/40ys/proposal_A.md`, `docs/design/40ys/proposal_B.md`;
#      `../BennettVM.jl/test/test_40ys_closure_callee_vm.jl` (the downstream
#      half: ingest → run → unrun on the functor fixture).

using Test
using Bennett
using InteractiveUtils: code_llvm

const _B40 = Bennett

# ---- fixtures (all local; none depends on a Base-internal name) ----

# A closure over TWO Int64 captures. `@noinline` in body position keeps it an
# `:invoke` edge instead of being inlined away.
function _mk40ys(n::Int64, m::Int64)
    return function ()
        @noinline
        return n * 5 + m
    end
end

# A functor — `isdefined(K, :instance) == false` for exactly the same reason a
# closure's type is, which is why the arm is keyed on the general property
# rather than on "closure".
struct Adder40ys
    n::Int64
end
@noinline (a::Adder40ys)(x::Int64) = x + a.n * 3

# The synthetic E2E root: a genuine `:invoke` to an instance-less callee whose
# captured state is INTEGER ONLY (deliberately avoiding the dv1z ptr-field wall)
# and whose return is a plain `i64` (no sret).
_root40ys(x::Int64) = Adder40ys(x)(x + 1)

# A TWO-field (16-byte) capture. `Adder40ys` above is 8 bytes, so its callee-side
# arg width (`8 * sizeof`) coincidentally equals the caller-side 64-bit cell
# width — the agreement in gate (G) is a coincidence of size, not a property.
# This fixture breaks the coincidence and is what gate (K) pins.
struct Pair40ys
    a::Int64
    b::Int64
end
@noinline (p::Pair40ys)(x::Int64) = x * p.a + p.b
_root2_40ys(x::Int64) = Pair40ys(x, x + 7)(x + 1)

# The real corpus. `@inbounds` keeps the callee set small.
_push40ys(n::Int64) = (v = Int64[]; push!(v, n); @inbounds v[1])
_push8_40ys(n::Int8) = (v = Int8[]; push!(v, n); @inbounds v[1])

# Harvest the (key, argtypes) pair of the single instance-less callee under a root.
function _instanceless_of(f, T)
    hits = [(k, at) for (k, at) in _B40.transitive_callees(f, T)
            if k isa Type && !(k <: Type) && !isdefined(k, :instance)]
    isempty(hits) && error("no instance-less callee under $(f) $(T) — fixture broken")
    return hits
end

# Normalise Julia's per-emission mangling counters (`_1531`, `#121`), the ONLY
# thing that differs between two emissions of the same method.
_norm40ys(s) = replace(s, r"_\d+\b" => "_N", r"#\d+" => "#N")

@testset "Bennett-40ys — instance-less callee keys (closures + functors)" begin

    # ------------------------------------------------------------------
    # (A) The diagnostic floor: a TOTAL classifier, no bare UndefRefError.
    # ------------------------------------------------------------------
    @testset "(A) _callee_key_kind is total; unknown shapes fail loud" begin
        CT = typeof(_mk40ys(Int64(2), Int64(3)))
        @test !isdefined(CT, :instance)              # the precondition
        @test !isdefined(Adder40ys, :instance)

        @test _B40._callee_key_kind(Type{BoundsError}) === :constructor
        @test _B40._callee_key_kind(typeof(sin))      === :singleton
        @test _B40._callee_key_kind(CT)               === :instanceless
        @test _B40._callee_key_kind(Adder40ys)        === :instanceless

        # A non-`Type` key: names the key, its typeof, and the bead.
        e = try _B40._callee_key_kind(3); nothing catch e; e end
        @test e isa ErrorException
        @test !(e isa UndefRefError)
        @test occursin("julia_set.jl", e.msg)
        @test occursin("Int64", e.msg)
        @test occursin("Bennett-40ys", e.msg)

        # `Core.OpaqueClosure` is instance-less too, but needs a DIFFERENT
        # codegen entry (`get_oc_code_rt`, `f.world`) — it must NOT be silently
        # swept into the :instanceless arm.
        e2 = try _B40._callee_key_kind(Core.OpaqueClosure{Tuple{},Int64}); nothing catch e; e end
        @test e2 isa ErrorException
        @test occursin("OpaqueClosure", e2.msg)
        @test occursin("Bennett-40ys", e2.msg)

        # An abstract key can never be codegen input.
        e3 = try _B40._callee_key_kind(Function); nothing catch e; e end
        @test e3 isa ErrorException
        @test occursin("Bennett-40ys", e3.msg)
    end

    # ------------------------------------------------------------------
    # (B) The mechanism IS `code_llvm`'s own path, minus the callable.
    # ------------------------------------------------------------------
    @testset "(B) _code_llvm_by_sig ≡ code_llvm modulo mangling counters" begin
        @test _B40._assert_sig_llvm_supported() === nothing

        _sq40ys(x::Int64) = x * x + 1
        cl = _mk40ys(Int64(7), Int64(11))
        cases = Any[
            (_sq40ys, Tuple{Int64}),                                  # plain function
            (Core.throw_inexacterror, Tuple{Symbol, Type, Int64}),    # NON-dispatchtuple
            (cl, Tuple{}),                                            # closure (no .instance)
            (Adder40ys(Int64(4)), Tuple{Int64}),                      # functor
        ]
        for (f, T) in cases
            sig = Base.signature_type(f, T)
            a = sprint(io -> code_llvm(io, f, T; debuginfo=:none, optimize=false,
                                       dump_module=true))
            b = _B40._code_llvm_by_sig(sig; optimize=false)
            @test _norm40ys(a) == _norm40ys(b)
        end

        # `_spectypes_of` exactly inverts callgraph.jl's `_split_spectypes`,
        # including the `Vararg` case.
        for st in (Tuple{typeof(sin), Float64},
                   Tuple{Type{InexactError}, Symbol, Any, Vararg{Any}},
                   Tuple{typeof(_mk40ys(Int64(1), Int64(2)))})
            k, at = _B40._split_spectypes(st)
            @test _B40._spectypes_of(k, at) === st
        end

        # No-unique-method fails loud with the signature, not a MethodError.
        e = try _B40._code_llvm_by_sig(Tuple{typeof(sin), String}); nothing catch e; e end
        @test e isa ErrorException
        @test occursin("sig_llvm.jl", e.msg)
        @test occursin("Bennett-40ys", e.msg)
    end

    # ------------------------------------------------------------------
    # (C) The REAL key that crashes today emits real IR, with no instance.
    #     Version-observational: asserts the mechanism reaches the live
    #     corpus, not that Julia keeps outlining `_growend!`.
    # ------------------------------------------------------------------
    @testset "(C) real _growend! closure key → LLVM IR from the signature alone" begin
        hits = _instanceless_of(_push40ys, Tuple{Int64})
        @test length(hits) == 1
        k, at = hits[1]
        @test at === Tuple{}                         # everything rides in the type
        @test fieldcount(k) >= 2                     # a real captured-state struct

        ir = _B40._code_llvm_by_sig(_B40._spectypes_of(k, at); optimize=false)
        bare = String(_B40._callee_barename(k, at))
        @test occursin("define", ir)
        @test occursin("julia_" * bare, ir)          # codegen mangled OUR barename
        @test occursin("dereferenceable($(sizeof(k)))", ir)   # the by-pointer self arg
        @test length(ir) > 1000
    end

    # ------------------------------------------------------------------
    # (D) End-to-end ParsedIR from a TYPE — closure and functor.
    # ------------------------------------------------------------------
    @testset "(D) extract_parsed_ir_by_sig on a closure and on a functor" begin
        CT = typeof(_mk40ys(Int64(2), Int64(3)))
        pir = _B40.extract_parsed_ir_by_sig(Tuple{CT}; optimize=false, ptr_cells=true)
        @test pir.ret_width == 64
        @test length(pir.args) == 1                       # the by-pointer self
        @test pir.args[1][2] == 8 * sizeof(CT)            # width from dereferenceable(N)
        # The captured Int64s decode through the EXISTING ptr machinery.
        insts = [i for b in pir.blocks for i in b.instructions]
        @test count(i -> i isa _B40.IRLoad, insts) == 2    # n and m
        @test any(i -> i isa _B40.IRPtrOffset, insts)      # field 2 at a byte offset
        @test any(i -> i isa _B40.IRBinOp && i.op === :mul, insts)

        fpir = _B40.extract_parsed_ir_by_sig(Tuple{Adder40ys, Int64};
                                             optimize=false, ptr_cells=true)
        @test fpir.ret_width == 64
        @test length(fpir.args) == 2
        @test fpir.args[1][2] == 8 * sizeof(Adder40ys)    # self, by pointer
        @test fpir.args[2][2] == 64                       # x::Int64
        finsts = [i for b in fpir.blocks for i in b.instructions]
        @test count(i -> i isa _B40.IRLoad, finsts) == 1
        @test any(i -> i isa _B40.IRBinOp && i.op === :add, finsts)

        # The by-sig entry and the by-value entry agree on structure wherever
        # BOTH can run (a guard against the two entries drifting apart).
        _sq40ys2(x::Int64) = x * x + 1
        p1 = _B40.extract_parsed_ir(_sq40ys2, Tuple{Int64}; optimize=false)
        p2 = _B40.extract_parsed_ir_by_sig(Base.signature_type(_sq40ys2, Tuple{Int64});
                                           optimize=false)
        @test p1.ret_width == p2.ret_width
        @test [w for (_n, w) in p1.args] == [w for (_n, w) in p2.args]
        @test [b.label for b in p1.blocks] == [b.label for b in p2.blocks]
        @test [typeof.(b.instructions) for b in p1.blocks] ==
              [typeof.(b.instructions) for b in p2.blocks]
    end

    # ------------------------------------------------------------------
    # (E) Naming: `mi.def.name`, never `nameof(K)`.
    # ------------------------------------------------------------------
    @testset "(E) barename is the METHOD name codegen mangles" begin
        CT = typeof(_mk40ys(Int64(2), Int64(3)))
        bare = _B40._callee_barename(CT, Tuple{})
        @test bare === Symbol("#_mk40ys##0")
        # THE TRAP: `nameof` gives the closure's TYPE name, which matches no
        # LLVM symbol. Pinned so nobody "simplifies" it back.
        @test nameof(CT) === Symbol("#_mk40ys##0#_mk40ys##1")
        @test bare !== nameof(CT)
        # Independent cross-check against the 1.12 TypeName field (used ONLY
        # as corroboration — `mi.def.name` is what codegen itself reads).
        @test bare === getfield(CT.name, :singletonname)
        # ...and it really is what the emitted symbol carries.
        @test occursin("julia_" * String(bare) * "_",
                       _B40._code_llvm_by_sig(Tuple{CT}; optimize=false))

        # Functors name themselves; the two pre-existing arms are UNCHANGED.
        @test _B40._callee_barename(Adder40ys, Tuple{Int64}) === :Adder40ys
        @test _B40._callee_barename(typeof(sin), Tuple{Float64}) === :sin
        @test _B40._callee_barename(Type{BoundsError}, Tuple{Any}) === :BoundsError
    end

    # ------------------------------------------------------------------
    # (F) The canonical key must digest the FULL specTypes.
    # ------------------------------------------------------------------
    @testset "(F) specTypes digest: two push! closures do NOT collide" begin
        k64, at64 = _instanceless_of(_push40ys, Tuple{Int64})[1]
        k8,  at8  = _instanceless_of(_push8_40ys, Tuple{Int8})[1]
        @test k64 !== k8                                   # genuinely different bodies
        @test at64 === at8 === Tuple{}                     # ...with IDENTICAL argtypes
        @test _B40._callee_barename(k64, at64) === _B40._callee_barename(k8, at8)

        # RED under an argtypes-only digest: `hash(Tuple{})` is a constant.
        @test _B40._argtype_digest(at64) == _B40._argtype_digest(at8)
        key64 = _B40._canonical_callee_key(k64, at64)
        key8  = _B40._canonical_callee_key(k8, at8)
        @test key64 !== key8
        # Shape preserved: BVM's `_CONTENT_DIGEST_RE` requires `#<8hex>`, and
        # `rsplit(…, "#"; limit=2)` must still recover the `#`-bearing barename.
        for key in (key64, key8)
            s = String(key)
            @test occursin(r"#[0-9a-f]{8}$", s)
            @test rsplit(s, "#"; limit=2)[1] == String(_B40._callee_barename(k64, at64))
        end
    end

    # ------------------------------------------------------------------
    # (G) Call-site binding: an extracted set is SELF-CONSISTENT.
    # ------------------------------------------------------------------
    @testset "(G) closed-world set binds the call site to the bare name" begin
        set = _B40.extract_parsed_ir_set_from_julia(_root40ys, Tuple{Int64};
                                                    ptr_cells=true)
        @test length(set) == 2
        keys_ = [p.first for p in set]
        @test startswith(String(keys_[1]), "_root40ys#")             # entry-first
        @test any(k -> startswith(String(k), "Adder40ys#"), keys_)

        calls = [i for (_k, pir) in set for b in pir.blocks
                 for i in b.instructions if i isa _B40.IRCall]
        @test length(calls) == 1
        # BARE, not the drift-prone `j_Adder40ys_<NNN>` — this is what makes
        # BVM's `_vm_dispatch_name` agree with the table key's `_vm_funcname`.
        @test calls[1].callee === :Adder40ys
        @test !occursin("j_", String(calls[1].callee))
        # Arity/width agreement across the boundary (the ABI the VM binds).
        callee_pir = only(p.second for p in set
                          if startswith(String(p.first), "Adder40ys#"))
        @test length(calls[1].args) == length(callee_pir.args) == 2
        @test calls[1].arg_widths == [w for (_n, w) in callee_pir.args] == [64, 64]

        # The set really is closed (the check runs inside the producer, but
        # pin the linkage explicitly: bare name ⇒ in-set key).
        bare = Symbol(rsplit(String(keys_[2]), "#"; limit=2)[1])
        @test bare === calls[1].callee
    end

    # ------------------------------------------------------------------
    # (H) Registry hygiene — restored on BOTH paths.
    # ------------------------------------------------------------------
    @testset "(H) name registry is scoped, including on the throwing path" begin
        @test isempty(_B40._known_callee_names)
        _B40.extract_parsed_ir_set_from_julia(_root40ys, Tuple{Int64}; ptr_cells=true)
        @test isempty(_B40._known_callee_names)
        # Throwing path: push! walls (gate I) — the finally must still fire.
        try
            _B40.extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64}; ptr_cells=true)
        catch e
            e isa InterruptException && rethrow()
        end
        @test isempty(_B40._known_callee_names)

        # Case preservation: the demangler used by the NAME registry must not
        # lowercase its capture (an `Adder40ys` callee would never resolve).
        _B40.register_callee_name!("Adder40ys", :Adder40ys)
        try
            @test _B40._lookup_callee_name("j_Adder40ys_123") === :Adder40ys
            @test _B40._lookup_callee_name("julia_Adder40ys_9") === :Adder40ys
            @test _B40._lookup_callee_name("j_adder40ys_123") === nothing
            @test _B40._lookup_callee_name("Adder40ys") === :Adder40ys
        finally
            lock(_B40._known_callees_lock) do
                delete!(_B40._known_callee_names, "Adder40ys")
            end
        end
        @test isempty(_B40._known_callee_names)
    end

    # ------------------------------------------------------------------
    # (H2) ptr_cells=false has NO hook, on purpose: an instance-less callee
    #      cannot be gate-inlined (`lower_call!` re-extracts the body from a
    #      `Function` value that does not exist). It must fall through to U15
    #      — but with a message that says THAT, rather than the misleading
    #      "register via `register_callee!`" advice.
    # ------------------------------------------------------------------
    @testset "(H2) circuit path (ptr_cells=false) rejects with the right reason" begin
        _B40.register_callee_name!("Adder40ys", :Adder40ys)
        try
            e = try
                _B40.extract_parsed_ir(_root40ys, Tuple{Int64};
                                       optimize=false, ptr_cells=false)
                nothing
            catch e
                e
            end
            @test e !== nothing
            msg = sprint(showerror, e)
            @test occursin("INSTANCE-LESS", msg)
            @test occursin("ptr_cells=false", msg)
            @test occursin("Bennett-40ys", msg)
            @test !occursin("register via `register_callee!`", msg)
        finally
            lock(_B40._known_callees_lock) do
                delete!(_B40._known_callee_names, "Adder40ys")
            end
        end
        @test isempty(_B40._known_callee_names)
    end

    # ------------------------------------------------------------------
    # (I) THE BEAD: push! no longer crashes opaquely; it walls at a NAMED
    #     wall. Version-observational (see the file header's honest
    #     boundary). When the named wall's bead lands this goes RED — that
    #     is the signal to advance the assertion to the next wall, NOT to
    #     delete it.
    #
    #     ADVANCED by Bennett-7wsz (2026-08-04): ptr-typed sret struct
    #     fields are now admitted under `ptr_cells=true`, so the closure no
    #     longer dies at the dv1z `_sret_struct_fields` reject. It now walks
    #     its body and lands on the UNRECOGNISED Julia JIT global
    #     `@jl_diverror_exception` (bennettvm-416r.13) from the growth-factor
    #     `div`. Pinned as an occursin-DISJUNCTION (the test_lf14 landing
    #     convention): which body of the set fails first is registration /
    #     iteration order, which is not a contract — the root's own wall is
    #     the U15 `movq %fs:0` pgcstack read (Bennett-5oyt).
    #
    #     ADVANCED AGAIN by Bennett-3vf2 (2026-08-04): the four hoisted
    #     `load ptr, ptr @jl_diverror_exception` sites are now DROPPED (every
    #     use lies in a Bennett-utzc dead block), so the 416r.13 wall is
    #     gone and the closure walks on to `llvm.memmove.p0.p0.i64` at
    #     `%L79` — Bennett-8bys / Bennett-37mt, explicitly out of 3vf2's
    #     scope. The negatives below are the anti-regression half: the
    #     diverror wall must not quietly re-open.
    #
    #     ADVANCED AGAIN by Bennett-vau9 (2026-08-04): that memmove now
    #     ROUTES to `IRCall(:memmove)` → BVM's overlap-safe
    #     `IntrinsicMemmove` under `ptr_cells`, so the closure walks past
    #     `%L79` and dies at `%L84` on
    #     `%coercion = ptrtoint ptr %.ref.ptr_or_offset to i64` — the
    #     generic Bennett-iwo9 / CW-D3 Lever 1 reject (an unrecognised
    #     pointer↔integer round-trip source). A `!occursin("memmove")`
    #     negative joins the diverror ones.
    #
    #     ADVANCED AGAIN by Bennett-jbko (2026-08-04): that `%L84` ptrtoint is
    #     the `MemoryRef` concurrent-mutation guard, and it is now ADMITTED as
    #     the width-64 cell identity `IRBinOp(:or, src, 0, 64)` under the
    #     use-scoped identity-icmp gate. The closure walks past `%L84` (and
    #     past the utzc-pruned `%L90` throw arm) and dies in `%L93` on the
    #     LIVE whole-struct `store { ptr, ptr } %memory_ref, ptr %1`
    #     (Bennett-lgzx / U114).
    #
    #     NOTE — MEASURED, and it CORRECTS the jbko bead's own forecast: the
    #     bead predicted an 8-byte sret-reassembly memcpy next. There is no
    #     such live memcpy first; the only 8-byte `llvm.memcpy` sits behind two
    #     LIVE aggregate stores. Both jbko proposals reproduced this
    #     independently.
    #
    #     The two negatives below are NOT decoration. This gate's landing
    #     disjunction ALREADY admitted `Bennett-lgzx`/`U114` before jbko, so
    #     the testset did NOT go red on landing — without the negatives the
    #     marker would silently stop tracking the frontier (the Bennett-0ncn
    #     lesson, applied in advance).
    # ------------------------------------------------------------------
    @testset "(I) push! reaches the NEXT named wall, not an UndefRefError" begin
        e = try
            _B40.extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64};
                                                  ptr_cells=true)
            nothing
        catch e
            e
        end
        @test e !== nothing
        @test !(e isa UndefRefError)
        @test e isa ErrorException
        @test !occursin("access to undefined reference", e.msg)
        # the closure key is still named (the 40ys instance-less arm works)
        @test occursin("_growend!", e.msg)
        # the OLD (Bennett-dv1z ptr-sret-field) wall is GONE — 7wsz cleared it
        @test !occursin("Bennett-dv1z", e.msg)
        @test !occursin("sret struct field", e.msg)
        # the PREVIOUS (bennettvm-416r.13 JIT-global) wall is GONE — 3vf2
        # cleared it; these negatives keep it from re-opening unnoticed
        @test !occursin("jl_diverror_exception", e.msg)
        @test !occursin("UNRECOGNIZED Julia JIT global", e.msg)
        # the PREVIOUS (llvm.memmove) wall is GONE — vau9 routes it
        @test !occursin("memmove", e.msg)
        @test !occursin("not yet lowered to reversible gates", e.msg)
        # the PREVIOUS (`%L84` ptrtoint) wall is GONE — jbko admits it
        @test !occursin("Bennett-iwo9", e.msg)
        @test !occursin("ptrtoint", e.msg)
        # ... and we land on one of the NAMED successor walls
        # MEASURED (2026-08-04, --check-bounds=yes): the closure fails first,
        # on `store { ptr, ptr } %memory_ref15, ptr %1` in `%L93`. Kept as a
        # DISJUNCTION rather than a literal pin because WHICH body of the set
        # fails first is registration/iteration order, which is not a contract
        # (the test_lf14 convention this gate has always followed).
        @test occursin("Bennett-lgzx", e.msg) || occursin("U114", e.msg) ||
              occursin("store of non-integer type", e.msg) ||
              occursin("Bennett-5oyt", e.msg) || occursin("U15", e.msg)
    end

    # ==================================================================
    # PINNED KNOWN GAPS — the two testsets below assert what the code
    # does TODAY, which is NOT what it should do. They exist so the gap
    # cannot be forgotten and so the eventual fix announces itself.
    #
    # ******************************************************************
    # * These are NOT desired behaviour. When the named bead lands,     *
    # * the testset MUST go RED — that is the signal to FLIP the        *
    # * assertion to the correct one, NOT to delete the testset.        *
    # ******************************************************************
    #
    # (the `test_tl1l` / a70z wall-marker convention)
    # ==================================================================

    # ------------------------------------------------------------------
    # (J) KNOWN GAP — Bennett-9tg3: `on_extract_error=:skip` silently
    #     drops the ROOT.
    #
    # A closed-world set without its entry routine is not a closed world:
    # `lower_vm(set; entry=first(set).first)` would happily lower a set
    # whose "entry" is an arbitrary surviving helper. 40ys made this
    # REACHABLE (before it, the call `UndefRefError`d before `:skip`
    # could do anything), but the hazard is `_extract_one`'s, not the
    # instance-less arm's: `:skip` records the failure and continues,
    # and the root's `if root_pir !== nothing` guard just... skips it.
    #
    # Live repro pinned below: `push!` under `:skip` returns TWO bodies,
    # both unrelated `throw_*` helpers, with the root absent — because
    # the root AND the `_growend!` closure both still wall (post-vau9: the
    # closure on the `%L84` `ptrtoint ptr %.ref.ptr_or_offset` /
    # Bennett-iwo9, the root on the U15 `movq %fs:0` pgcstack read /
    # Bennett-5oyt).
    #
    # DESIRED behaviour (Bennett-9tg3): fail loud naming the root key.
    # ------------------------------------------------------------------
    @testset "(J) KNOWN GAP Bennett-9tg3: :skip drops the ROOT silently" begin
        out = _B40.extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64};
                                                     ptr_cells=true,
                                                     on_extract_error=:skip)
        # It returns — no error at all. That is the gap.
        @test out isa Vector{Pair{Symbol,_B40.ParsedIR}}

        keys_ = first.(out)
        # THE BUG: the root is NOT in the set, and nothing said so.
        @test !any(k -> startswith(String(k), "_push40ys#"), keys_)
        # ...and what IS returned is two unrelated throw helpers, i.e. a
        # "closed world" consisting entirely of leaves.
        @test length(out) == 2
        @test any(k -> startswith(String(k), "throw_boundserror#"), keys_)
        @test any(k -> startswith(String(k), "throw_inexacterror#"), keys_)
        # Neither body calls the other and neither is reachable from an
        # entry — the set is structurally useless, yet indistinguishable
        # from success at the call site.
        @test all(p -> isempty([i for b in p.second.blocks
                                for i in b.instructions if i isa _B40.IRCall]), out)
    end

    # ------------------------------------------------------------------
    # (K) KNOWN GAP — Bennett-ce9t: `ParsedIR.args` width is wrong for a
    #     by-pointer instance-less callee wider than 8 bytes.
    #
    # The captured state travels BY POINTER. The CALLER passes it as one
    # 64-bit VM cell (`_cell_call_args`), but the CALLEE's arg width is
    # derived from `dereferenceable(N)` as `8 * sizeof(CT)`. For the
    # 8-byte `Adder40ys` those coincide at 64 — which is why gate (G)'s
    # `arg_widths == callee widths` assertion passes there. It is a
    # coincidence of SIZE, not an invariant.
    #
    # For the 16-byte `Pair40ys` the callee declares 128 while the caller
    # passes 64. INERT today: BennettVM's `lower_vm` builds its param
    # list as `Symbol[n for (n, _w) in parsed.args]`, dropping widths
    # entirely, so nothing consumes the wrong number (proven end-to-end
    # in `../BennettVM.jl/test/test_40ys_closure_callee_vm.jl` gate (g),
    # which runs and reverses this exact fixture correctly).
    #
    # DESIRED behaviour (Bennett-ce9t): the two agree — either the callee
    # arg is a 64-bit cell like every other pointer under `ptr_cells`, or
    # the boundary carries the aggregate width explicitly.
    # ------------------------------------------------------------------
    @testset "(K) KNOWN GAP Bennett-ce9t: caller cell width ≠ callee arg width" begin
        set = _B40.extract_parsed_ir_set_from_julia(_root2_40ys, Tuple{Int64};
                                                     ptr_cells=true)
        @test length(set) == 2
        root_pir, callee_pir = set[1].second, set[2].second
        call = only(i for b in root_pir.blocks for i in b.instructions
                    if i isa _B40.IRCall)
        @test call.callee === :Pair40ys

        callee_widths = [w for (_n, w) in callee_pir.args]
        @test sizeof(Pair40ys) == 16                    # the precondition
        # THE BUG, pinned as exact values on both sides.
        @test call.arg_widths == [64, 64]               # caller: two cells
        @test callee_widths == [128, 64]                # callee: 8*sizeof(CT)
        @test call.arg_widths != callee_widths          # ...they disagree
        @test callee_widths[1] == 8 * sizeof(Pair40ys)  # and this is why

        # Contrast: the 8-byte fixture agrees only because 8*8 == 64.
        set1 = _B40.extract_parsed_ir_set_from_julia(_root40ys, Tuple{Int64};
                                                      ptr_cells=true)
        call1 = only(i for b in set1[1].second.blocks for i in b.instructions
                     if i isa _B40.IRCall)
        @test call1.arg_widths == [w for (_n, w) in set1[2].second.args]
        @test 8 * sizeof(Adder40ys) == 64               # the coincidence, named

        # The FIELD DECODE is correct regardless — the widths are the only
        # thing wrong, which is why this is inert rather than a miscompile.
        cinsts = [i for b in callee_pir.blocks for i in b.instructions]
        @test count(i -> i isa _B40.IRLoad, cinsts) == 2          # a and b
        @test any(i -> i isa _B40.IRPtrOffset && i.offset_bytes == 8, cinsts)
    end
end
