# ---- by-signature LLVM IR emission (Bennett-40ys) ----
#
# WHY THIS FILE EXISTS
#
# `extract_parsed_ir(f, arg_types)` needs a callable VALUE, because it goes
# through `InteractiveUtils.code_llvm(io, f, t)`. The closed-world call-graph
# walker (`callgraph.jl`) hands us callee keys that have NO value: Julia 1.12
# outlines `_growend!`'s slow path into a CLOSURE, so `transitive_callees` on
# any `push!`-bearing function yields the key
#
#     Base.var"#_growend!##0#_growend!##1"{Vector{Int64}, …, MemoryRef{Int64}}
#
# — a concrete callable DataType with eight FIELDS, hence no `.instance`.
# Functors (`struct Adder; n; end; (a::Adder)(x) = …`) are instance-less for
# exactly the same reason; closures and functors are one Julia concept, "a
# callable type with fields".
#
# THE OBSERVATION THAT MAKES IT WORK
#
# `InteractiveUtils._dump_function` (Julia 1.12.3, `codeview.jl:193-259`) is
#
#     world = Base.get_world_counter()
#     match = Base._which(signature_type(f, t); world)      # ← the ONLY use of `f`
#     mi    = Base.specialize_method(match)
#     src   = Base.Compiler.typeinf_code(NativeInterpreter(world), mi, true)
#     str   = _dump_function_llvm(mi, src, wrapper, !raw, dump_module, optimize,
#                                 debuginfo, params)
#
# The callable is consumed in exactly one place, `signature_type(f, t) ==
# Tuple{Core.Typeof(f), t...}` — which is PRECISELY the `specTypes` the call
# graph already holds (`callgraph.jl:45` splits it; `_spectypes_of` below puts
# it back). So an instance is structurally unnecessary, not merely avoidable.
# This file reproduces that sequence MINUS the `signature_type` step.
#
# CLAUDE.md Rule 5/9/10 CAVEAT
#
# `Base._which`, `Base.specialize_method`, `Base.Compiler.typeinf_code` and
# `InteractiveUtils._dump_function_llvm` are Julia INTROSPECTION INTERNALS, not
# a stable API. They are the EXACT internals `code_llvm` itself calls, so they
# cannot drift independently of `code_llvm` — which this package already depends
# on (`entry.jl:1`). Same precedent as `callgraph.jl`, which depends on
# `Core.CodeInstance` and the `:invoke` Expr shape and fails loud via `mi_of`.
# `_assert_sig_llvm_supported` is the fail-loud capability gate, naming
# `VERSION`; it runs at every entry, not at load, so a REPL that redefines the
# internals is caught too.
#
# EQUIVALENCE, PROVEN NOT ASSUMED (Rule 10): for a plain function, for a
# NON-dispatch-tuple signature, and for a real closure, this path's output is
# byte-equal to `code_llvm(...; optimize=false, dump_module=true)` modulo
# Julia's per-emission `_NNN` / `#NNN` mangling counters — the same drift
# `julia_set.jl:12-19` and `_lookup_callee` already model as unstable. Pinned by
# `test/test_40ys_instanceless_callees.jl` gate (B).
#
# WORLD AGE: `Base.get_world_counter()` is read INSIDE every entry, never
# cached. Caching it in a `const` silently mis-resolves anything defined later
# in the session (observed during design as a spurious "no unique matching
# method found").
#
# OPTIMIZE SKEW (unchanged contract, worth stating): `transitive_callees`
# harvests edges at `optimize=true` (at O0 there are ZERO `:invoke`s), while
# bodies are extracted at `optimize=false` for predictable IR (Rule 5). For a
# closure that is doubly true — the closure EXISTS only because O2 outlined it,
# yet its body is emitted at O0. That is sound: the `MethodInstance` is the same
# object either way, only codegen differs, and it is exactly what
# `code_llvm(cl, Tuple{}; optimize=false)` does today.

import InteractiveUtils

# Every Julia internal this file reaches for, as (module, symbol) pairs.
const _SIG_LLVM_CAPABILITIES = (
    (Base, :_which),
    (Base, :specialize_method),
    (Base, :CodegenParams),
    (Base, :Compiler),
    (InteractiveUtils, :_dump_function_llvm),
)

"""
    _assert_sig_llvm_supported() -> Nothing

Fail loud (Rule 1/5/9) if this Julia does not expose the reflection internals
the by-signature LLVM path reproduces. Called at the head of every entry in
this file. Names `VERSION` and the `codeview.jl` reference so the next agent
knows exactly what to re-derive (Bennett-40ys).
"""
function _assert_sig_llvm_supported()
    for (m, s) in _SIG_LLVM_CAPABILITIES
        isdefined(m, s) || error(
            "sig_llvm.jl: Julia $(VERSION) does not define `$(m).$(s)` — the " *
            "by-signature LLVM IR path reproduces InteractiveUtils._dump_function " *
            "(stdlib codeview.jl) minus its `signature_type(f, t)` step, and must " *
            "be re-derived for this Julia. Julia introspection internals are not a " *
            "stable API (CLAUDE.md Rule 5/9; Bennett-40ys).")
    end
    (isdefined(Base.Compiler, :typeinf_code) &&
     isdefined(Base.Compiler, :NativeInterpreter)) || error(
        "sig_llvm.jl: Julia $(VERSION) is missing " *
        "`Base.Compiler.typeinf_code` / `Base.Compiler.NativeInterpreter` " *
        "(these moved from `Core.Compiler` in 1.12) — the by-signature LLVM IR " *
        "path cannot infer a MethodInstance's source. Julia introspection " *
        "internals are not a stable API (CLAUDE.md Rule 5/9; Bennett-40ys).")
    return nothing
end

# Bennett-t9rh: the extra internals the PINNED `optimize=true` path
# (`target_pin.jl`) reaches for — LLVM.jl's Julia-pipeline interop and the C
# API calls that emulate `jl_dump_function_ir`'s strip. Checked in addition to
# `_SIG_LLVM_CAPABILITIES` by `_assert_pinned_ir_supported`.
const _PINNED_IR_CAPABILITIES = (
    (LLVM.Interop, :JuliaPipeline),
    (LLVM.Interop, :RemoveJuliaAddrspacesPass),
    (LLVM, :NewPMPassBuilder),
    (LLVM, :TargetMachine),
    (LLVM, :strip_debuginfo!),
    (LLVM.API, :LLVMInstructionGetAllMetadataOtherThanDebugLoc),
    (LLVM.API, :LLVMValueMetadataEntriesGetKind),
    (LLVM.API, :LLVMDisposeValueMetadataEntries),
    (LLVM.API, :LLVMGlobalClearMetadata),
)

"""
    _assert_pinned_ir_supported() -> Nothing

Fail loud if this Julia / LLVM.jl does not expose what the pinned,
host-independent `optimize=true` IR path (`target_pin.jl`, Bennett-t9rh)
needs: every `_SIG_LLVM_CAPABILITIES` internal plus `_PINNED_IR_CAPABILITIES`.
"""
function _assert_pinned_ir_supported()
    _assert_sig_llvm_supported()
    for (m, s) in _PINNED_IR_CAPABILITIES
        isdefined(m, s) || error(
            "sig_llvm.jl: Julia $(VERSION) / LLVM.jl does not define `$(m).$(s)` — " *
            "the pinned optimize=true IR path (target_pin.jl) re-runs Julia's " *
            "`julia<level=2>` pipeline under a pinned TargetMachine and emulates " *
            "jl_dump_function_ir's strip (Julia src/disasm.cpp), and must be " *
            "re-derived for this Julia (CLAUDE.md Rule 5/9; Bennett-t9rh).")
    end
    return nothing
end

"""
    _spectypes_of(callee_key, argtypes::Type{<:Tuple}) -> Type{<:Tuple}

Reassemble the full `specTypes` signature `Tuple{callee_key, argtypes...}` —
the exact inverse of `callgraph.jl`'s `_split_spectypes`, including the
`Vararg` case (`Tuple{Type{InexactError}, Symbol, Any, Vararg{Any}}` round-trips
identically). This is the unit of currency the by-signature path consumes: a
closure carries ALL its state in `callee_key` and has `argtypes == Tuple{}`, so
the argtypes alone are not a usable identifier (see `_canonical_callee_key`).
"""
_spectypes_of(@nospecialize(callee_key), argtypes::Type{<:Tuple}) =
    Tuple{callee_key, argtypes.parameters...}

"""
    _method_instance_of_sig(sig::Type{<:Tuple}) -> Core.MethodInstance

The `MethodInstance` Julia's codegen would compile for the full signature
`sig`. Fails loud (Rule 1) if inference cannot resolve a unique method.
Used both to emit IR (`_code_llvm_by_sig`) and to read the METHOD name that
codegen mangles into the LLVM symbol (`julia_set.jl`'s `_callee_barename`).
"""
function _method_instance_of_sig(@nospecialize(sig::Type))::Core.MethodInstance
    _assert_sig_llvm_supported()
    (sig isa DataType && sig <: Tuple) || throw(ArgumentError(
        "sig_llvm.jl: _method_instance_of_sig: `sig` must be a concrete Tuple " *
        "signature type `Tuple{callee_key, argtypes...}`, got $(sig) " *
        "(::$(typeof(sig))) (Bennett-40ys)."))
    world = Base.get_world_counter()   # per call — NEVER cache (world age, Rule 7)
    match = try
        Base._which(sig; world)
    catch e
        e isa InterruptException && rethrow()
        error("sig_llvm.jl: _method_instance_of_sig: no unique matching method for " *
              "signature `$(sig)` in world $(world) — $(sprint(showerror, e)). " *
              "The typed call graph produced a signature inference cannot " *
              "re-resolve; Julia $(VERSION) (Rule 1; Bennett-40ys).")
    end
    return Base.specialize_method(match)
end

"""
    _code_llvm_by_sig(sig::Type{<:Tuple}; optimize=false, raw=false,
                      dump_module=true, debuginfo=:none, cpu=nothing) -> String

LLVM IR text for the method matching the FULL specTypes signature `sig`
(`Tuple{callee_key, argtypes...}`) — i.e. what
`code_llvm(io, f, t; debuginfo, optimize, dump_module)` would print, for a
callee whose instance cannot be obtained (a closure or a functor).

`optimize=true` (Bennett-t9rh) does NOT use the host JIT pipeline: it is the
pinned, host-independent IR of `target_pin.jl` (`_pinned_optimized_ir`) — what
`code_llvm(...; optimize=true)` prints in a `julia -O2 -C <pinned cpu>`
process. It requires `raw=false` and `debuginfo=:none` (ArgumentError
otherwise). `cpu` overrides the pinned CPU — TEST HOOK ONLY, and only with
`optimize=true`. `optimize=false` is unchanged.

Mirrors `InteractiveUtils._dump_function` except that the `MethodInstance` is
resolved from `sig` directly rather than from `signature_type(f, t)`.

The `GENERIC_SIG_WARNING` comment line is reproduced VERBATIM rather than
upgraded to a fail-loud: `Core.throw_inexacterror` with
`Tuple{Symbol, Type, Int64}` is a real, currently-working, non-dispatch-tuple
callee in the live corpus, and rejecting it would regress it. `;` starts an
LLVM comment, so `parse(LLVM.Module, …)` accepts the line unchanged.
"""
function _code_llvm_by_sig(@nospecialize(sig::Type); optimize::Bool=false,
                           raw::Bool=false, dump_module::Bool=true,
                           debuginfo::Symbol=:none,
                           cpu::Union{Nothing, AbstractString}=nothing)::String
    if optimize
        raw && throw(ArgumentError(
            "sig_llvm.jl: _code_llvm_by_sig: raw=true is not supported with " *
            "optimize=true — the pinned optimize=true path always strips like " *
            "code_llvm's default (Bennett-t9rh)."))
        debuginfo === :none || throw(ArgumentError(
            "sig_llvm.jl: _code_llvm_by_sig: debuginfo=$(repr(debuginfo)) is not " *
            "supported with optimize=true — the pinned path prints no source " *
            "line comments (Bennett-t9rh)."))
    else
        cpu === nothing || throw(ArgumentError(
            "sig_llvm.jl: _code_llvm_by_sig: `cpu` only applies to optimize=true " *
            "(Bennett-t9rh test hook)."))
    end
    mi = _method_instance_of_sig(sig)
    world = Base.get_world_counter()
    src = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
    src isa Core.CodeInfo || error(
        "sig_llvm.jl: _code_llvm_by_sig: inference returned $(typeof(src)) " *
        "(not a `Core.CodeInfo`) for $(mi) — cannot emit LLVM IR " *
        "(Rule 1; Bennett-40ys).")
    warning = Base.isdispatchtuple(mi.specTypes) ? "" :
        "; WARNING: This code may not match what actually runs.\n"
    # Bennett-t9rh: optimize=true never runs the host JIT pipeline.
    optimize && return warning * _pinned_optimized_ir(mi, src;
                                                      dump_module=dump_module, cpu=cpu)
    # `raw=false` is `code_llvm`'s default: strip IR metadata, no entry
    # safepoint, no explicit gcstack argument.
    params = Base.CodegenParams(debug_info_kind=Cint(0), debug_info_level=Cint(2),
                                safepoint_on_entry=raw, gcstack_arg=raw)
    return warning * InteractiveUtils._dump_function_llvm(
        mi, src, false, !raw, dump_module, #=optimize=# false, debuginfo, params)
end
