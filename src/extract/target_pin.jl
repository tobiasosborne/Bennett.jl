# ---- Bennett-t9rh: host-independent `optimize=true` LLVM IR ----
#
# THE PROBLEM
#
# `code_llvm(f, T; optimize=true)` → `jl_get_llvmf_defn(..., optimize=true)`
# runs Julia's NewPM O-pipeline as
#
#     NewPM PM{jl_ExecutionEngine->cloneTargetMachine(),
#              getOptLevel(jl_options.opt_level)};  PM.run(*m)
#
# (Julia 1.12 src/aotcompile.cpp, `jl_get_llvmf_defn_impl`). The JIT
# TargetMachine is the HOST CPU (or `julia -C <cpu>`), and its
# TargetTransformInfo drives the SLP / loop vectorisers, partial/runtime
# unroll factors and speculation costs; the pipeline level is the session's
# `-O` flag. Neither shows up in the printed IR. So before this file, the
# `optimize=true` IR Bennett compiled — and therefore every gate count, and
# even whether a function compiled at all — was a hidden function of the host
# CPU and of `julia -O`:
#
#   * AVX-512 hosts SLP-vectorise `soft_fmul` / `soft_fma` / `soft_fdiv` into a
#     horizontal-add idiom with a poison lane (Bennett-t9rh's crash; fixed
#     soundly in vectors.jl, but the resulting circuit still differed);
#   * unroll factors differ between SSE-class, Intel AVX2 and AMD Zen hosts:
#     `_soft_udiv_compile` (backs every integer `÷`/`%`) measured 825,319 gates
#     under `-C x86-64`, 1,594,161 on Intel AVX2 and 12,594,211 on Zen3.
#
# `Base.CodegenParams` has no target field, so the only in-process lever is to
# run the pipeline OURSELVES under a pinned TargetMachine.
#
# THE RECIPE (proposer A, docs/design/t9rh/; verified faithful)
#
#   1. `InteractiveUtils._dump_function_llvm(mi, src, wrapper=false,
#      strip_ir_metadata=false, dump_module=true, optimize=false, :none, params)`
#      with `code_llvm`'s own params. It MUST be the UNSTRIPPED module: the
#      stripped `optimize=false` text has lost tbaa and the `addrspace(10)`
#      GC-tracked pointer spaces, and Vector/Dict code optimises differently
#      without them.
#   2. Parse it into a fresh `LLVM.Context`.
#   3. Run `LLVM.Interop.JuliaPipeline(opt_level=_PINNED_OPT_LEVEL)` (the
#      pipeline string `julia<level=2>` — Julia's own O2 pipeline, with its
#      custom passes registered by LLVM.jl) under
#      `TargetMachine(triple, _pinned_target_cpu(triple), _PINNED_FEATURES)`.
#   4. Emulate `jl_dump_function_ir(strip_ir_metadata=true)` (Julia 1.12
#      src/disasm.cpp): `RemoveJuliaAddrspacesPass`, erase `llvm.dbg.*`
#      intrinsics, clear every non-debug-loc instruction metadata kind, clear
#      global-object metadata, strip debug info.
#   5. Print.
#
# Pinned with the host's own CPU name this reproduces host `code_llvm(optimize
# =true)`; pinned to `<cpu>` it reproduces `julia -C <cpu>`'s `code_llvm`.
# `test/test_t9rh_pinned_target.jl` holds a fidelity canary against a
# `julia -C x86-64-v3` subprocess, plus host-independence subprocess checks.
#
# WHAT IS PINNED (and why there is no override)
#
# * CPU: `"x86-64-v3"` on x86_64 — MAINTAINER DECISION 2026-09-24 (Bennett-t9rh
#   orchestrator review). Byte-identical to haswell/skylake IR for the whole
#   soft-float family (the historical baseline host class) and keeps cc0.7 SLP
#   coverage. `"generic"` on every other architecture (untested; Julia's
#   frontend codegen is architecture-specific anyway, so gate counts are not
#   promised to match across architectures). Alternative recorded in the
#   review: `"x86-64"` (smaller loop circuits, no SLP).
# * Features: `""` — the CPU name alone determines the feature set.
# * Opt level: 2, whatever `julia -O` says.
#
# There is deliberately NO environment variable or public kwarg to change any
# of these: a hidden input is exactly what this file removes. The `cpu=`
# keyword on the internal helpers exists for tests only.
#
# RESIDUAL HOST DEPENDENCE (known, filed as follow-ups)
#
# * `Base.fma(::Float64)`: `Core.Intrinsics.have_fma` is resolved at CODEGEN
#   time (before this pipeline runs), so the unoptimised IR itself is
#   `llvm.fma.f64` on FMA hosts and `@j_fma_emulated` otherwise.
# * `JULIA_LLVM_ARGS` (global LLVM cl::opts) and `--check-bounds`.
# * Future Julia versions may change what `code_llvm(optimize=true)` does
#   beyond the pipeline; the canary test detects that drift.
#
# CLAUDE.md Rule 5 corollary: never study host `code_llvm(optimize=true)`
# output to learn what Bennett compiles — use `Bennett.extract_ir`.

"""
    _PINNED_OPT_LEVEL

Julia pipeline level for every `optimize=true` extraction (Bennett-t9rh).
Independent of the session's `julia -O` flag.
"""
const _PINNED_OPT_LEVEL = 2

"""
    _PINNED_CPU_X86_64

LLVM CPU name of the TargetMachine used for `optimize=true` extraction on
x86_64 (Bennett-t9rh). MAINTAINER DECISION — do not change without
re-baselining (CLAUDE.md Rule 6).
"""
const _PINNED_CPU_X86_64 = "x86-64-v3"

"""
    _PINNED_CPU_OTHER

LLVM CPU name for every non-x86_64 architecture (Bennett-t9rh). Untested.
"""
const _PINNED_CPU_OTHER = "generic"

"""
    _PINNED_FEATURES

Target-feature string of the pinned TargetMachine — empty, so the CPU name
alone determines the features (Bennett-t9rh).
"""
const _PINNED_FEATURES = ""

"""
    _pinned_target_cpu(triple::AbstractString) -> String

The pinned LLVM CPU for a module target triple: `_PINNED_CPU_X86_64` on
`x86_64-*`, `_PINNED_CPU_OTHER` otherwise.
"""
function _pinned_target_cpu(triple::AbstractString)::String
    arch = first(split(triple, '-'))
    return arch == "x86_64" ? _PINNED_CPU_X86_64 : _PINNED_CPU_OTHER
end

"""
    _strip_like_jl_dump_function_ir!(mod::LLVM.Module) -> LLVM.Module

Emulate what `jl_dump_function_ir(..., strip_ir_metadata=true, ...)` (Julia
1.12 `src/disasm.cpp`: `jl_strip_llvm_addrspaces` + `jl_strip_llvm_debug(m,
all_meta=true)`) does to the module before printing, so the pinned path
prints the same IR `code_llvm` would (Bennett-t9rh).
"""
function _strip_like_jl_dump_function_ir!(mod::LLVM.Module)
    # jl_strip_llvm_addrspaces: addrspace(10/11/12/13) → 0.
    @dispose pb = LLVM.NewPMPassBuilder() begin
        LLVM.add!(pb, LLVM.Interop.RemoveJuliaAddrspacesPass())
        LLVM.run!(pb, mod)
    end
    # jl_strip_llvm_debug(all_meta=true): drop dbg.declare / dbg.value calls
    # and every metadata attachment other than the debug location.
    for f in LLVM.functions(mod), bb in LLVM.blocks(f)
        dead = LLVM.Instruction[]
        for inst in LLVM.instructions(bb)
            if inst isa LLVM.CallInst
                cn = try
                    LLVM.name(LLVM.called_operand(inst))
                catch e
                    e isa InterruptException && rethrow()
                    ""
                end
                if cn == "llvm.dbg.value" || cn == "llvm.dbg.declare"
                    push!(dead, inst)
                    continue
                end
            end
            n = Ref{Csize_t}(0)
            ents = LLVM.API.LLVMInstructionGetAllMetadataOtherThanDebugLoc(inst, n)
            kinds = [LLVM.API.LLVMValueMetadataEntriesGetKind(ents, i)
                     for i in 0:(Int(n[]) - 1)]
            ents == C_NULL || LLVM.API.LLVMDisposeValueMetadataEntries(ents)
            for k in kinds
                LLVM.API.LLVMSetMetadata(inst, k, C_NULL)
            end
        end
        foreach(LLVM.erase!, dead)
    end
    # g.clearMetadata() on every global object (variables AND functions).
    for g in LLVM.globals(mod)
        LLVM.API.LLVMGlobalClearMetadata(g)
    end
    for f in LLVM.functions(mod)
        LLVM.API.LLVMGlobalClearMetadata(f)
    end
    # debug locations, subprograms, llvm.dbg.cu.
    LLVM.strip_debuginfo!(mod)
    return mod
end

# The function `jl_dump_function_ir(dump_module=false)` would print: the
# specFunctionObject, i.e. the first defined `julia_*` function — the same rule
# `_find_entry_function` applies to the parsed module.
function _pinned_entry_function(mod::LLVM.Module)::LLVM.Function
    for f in LLVM.functions(mod)
        (!isempty(LLVM.blocks(f)) && startswith(LLVM.name(f), "julia_")) && return f
    end
    error("target_pin.jl: no defined `julia_*` function in the pinned module; " *
          "cannot print a dump_module=false view (Bennett-t9rh)")
end

"""
    _optimize_pinned(raw::AbstractString; cpu=nothing, dump_module=true) -> String

Run Julia's own `julia<level=\$(_PINNED_OPT_LEVEL)>` pipeline over the
UNSTRIPPED, unoptimised Julia module text `raw` under the pinned
TargetMachine, then strip it the way `code_llvm` does and print it
(Bennett-t9rh). `cpu` overrides `_pinned_target_cpu` — TEST HOOK ONLY.
"""
function _optimize_pinned(raw::AbstractString;
                          cpu::Union{Nothing, AbstractString}=nothing,
                          dump_module::Bool=true)::String
    _assert_pinned_ir_supported()
    local out::String
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, raw)
        try
            tr = LLVM.triple(mod)
            isempty(tr) && error(
                "target_pin.jl: unoptimised Julia module has no target triple; " *
                "cannot build the pinned TargetMachine (Bennett-t9rh)")
            tcpu = cpu === nothing ? _pinned_target_cpu(tr) : String(cpu)
            LLVM.TargetMachine(LLVM.Target(triple=tr), tr, tcpu,
                               _PINNED_FEATURES) do tm
                @dispose pb = LLVM.NewPMPassBuilder() begin
                    LLVM.add!(pb, LLVM.Interop.JuliaPipeline(opt_level=_PINNED_OPT_LEVEL))
                    LLVM.run!(pb, mod, tm)
                end
            end
            _strip_like_jl_dump_function_ir!(mod)
            out = dump_module ? string(mod) : string(_pinned_entry_function(mod))
        finally
            dispose(mod)
        end
    end
    return out
end

"""
    _pinned_optimized_ir(mi, src; dump_module=true, cpu=nothing) -> String

The host-independent `optimize=true` IR for the inferred `mi`/`src` pair:
what `code_llvm(...; optimize=true, debuginfo=:none, dump_module)` would print
in a `julia -O2 -C <pinned cpu>` process (Bennett-t9rh). Reached only through
`_code_llvm_by_sig(sig; optimize=true)`, which owns the MethodInstance
resolution and the GENERIC_SIG_WARNING line. `cpu` is a TEST HOOK ONLY.
"""
function _pinned_optimized_ir(mi::Core.MethodInstance, src::Core.CodeInfo;
                              dump_module::Bool=true,
                              cpu::Union{Nothing, AbstractString}=nothing)::String
    # `code_llvm`'s default (raw=false) params, but strip_ir_metadata=false and
    # optimize=false: the pinned pipeline and the strip are ours. The module
    # must be UNSTRIPPED (tbaa + addrspace(10) drive the memory optimisations).
    params = Base.CodegenParams(debug_info_kind=Cint(0), debug_info_level=Cint(2),
                                safepoint_on_entry=false, gcstack_arg=false)
    raw = InteractiveUtils._dump_function_llvm(mi, src, #=wrapper=# false,
                                               #=strip_ir_metadata=# false,
                                               #=dump_module=# true,
                                               #=optimize=# false, :none, params)
    return _optimize_pinned(raw; cpu=cpu, dump_module=dump_module)
end

"""
    _julia_ir_string(f, arg_types; optimize, dump_module=true) -> String

THE single source of Julia-function LLVM IR text for `extract_parsed_ir` and
`extract_ir` (Rule 12; Bennett-t9rh). `optimize=false` is exactly
`code_llvm(...; debuginfo=:none, optimize=false, dump_module)` (byte-identical
to every prior release); `optimize=true` is the pinned, host-independent
pipeline (`_code_llvm_by_sig(...; optimize=true)` → `_pinned_optimized_ir`).
"""
function _julia_ir_string(f, arg_types::Type{<:Tuple}; optimize::Bool,
                          dump_module::Bool=true)::String
    optimize || return sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none,
                                              optimize=false, dump_module=dump_module))
    # Mirror InteractiveUtils._dump_function's front-door checks.
    f isa Core.Builtin && throw(ArgumentError(
        "argument is not a generic function (Bennett-t9rh pinned IR path)"))
    f isa Core.OpaqueClosure && throw(ArgumentError(
        "target_pin.jl: OpaqueClosure is not supported by the pinned optimize=true " *
        "IR path; pass optimize=false (Bennett-t9rh)"))
    return _code_llvm_by_sig(Base.signature_type(f, arg_types); optimize=true,
                             dump_module=dump_module, debuginfo=:none)
end
