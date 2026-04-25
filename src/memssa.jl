# ---- MemorySSA ingest via LLVM's print<memoryssa> pass ----
#
# Per T2a.1 investigation (docs/memory/memssa_investigation.md): LLVM.jl 9.4.6
# does not expose MemorySSA as a queryable C-API object, only as pipeline
# passes. We run `print<memoryssa>`, capture its stderr output (annotation
# comments interleaved with the printed IR), and parse the annotations.
#
# Annotation formats (LLVM IR textual; stable since LLVM 4):
#   ; N = MemoryDef(M)          ; N = MemoryDef(liveOnEntry)
#   ; MemoryUse(N)              ; MemoryUse(liveOnEntry)
#   ; N = MemoryPhi({bb,M},…)
#
# An annotation applies to the next non-annotation line (the actual
# instruction). We key annotations by 1-based line number of the annotated
# instruction within the printed text, so downstream consumers can correlate
# to LLVM.jl's instruction walk (same instruction ordering, same module).

# Bennett-by8j / U44: `MemSSAInfo` struct + zero-arg constructor moved
# to src/ir_types.jl so `ParsedIR.memssa` can be typed concretely as
# `Union{Nothing, MemSSAInfo}` rather than `::Any`.  Parsing methods
# stay here.

const _RE_MEM_DEF = r"^\s*;\s*(\d+)\s*=\s*MemoryDef\(\s*(\d+|liveOnEntry)\s*\)"
const _RE_MEM_USE = r"^\s*;\s*MemoryUse\(\s*(\d+|liveOnEntry)\s*\)"
const _RE_MEM_PHI = r"^\s*;\s*(\d+)\s*=\s*MemoryPhi\(\s*(.+?)\s*\)"
const _RE_PHI_ENTRY = r"\{\s*([^,]+?)\s*,\s*(\d+|liveOnEntry)\s*\}"

"""
    parse_memssa_annotations(annotated_ir::AbstractString) -> MemSSAInfo

Parse the textual output of `print<memoryssa>` into a `MemSSAInfo`.

Each annotation on a `;` comment line is associated with the NEXT non-blank,
non-annotation line's line number in the source text.
"""
function parse_memssa_annotations(annotated_ir::AbstractString)
    info = MemSSAInfo()
    lines = split(annotated_ir, '\n')

    # Pending annotations attached to the next non-annotation line.
    pending_def::Union{Nothing, Tuple{Int, Union{Int, Symbol}}} = nothing
    pending_use::Union{Nothing, Int} = nothing
    pending_phi::Union{Nothing, Int} = nothing

    for (i, line) in enumerate(lines)
        m_def = match(_RE_MEM_DEF, line)
        if m_def !== nothing
            def_id = parse(Int, m_def.captures[1])
            cap2 = m_def.captures[2]
            clobber = cap2 == "liveOnEntry" ? :live_on_entry : parse(Int, cap2)
            info.def_clobber[def_id] = clobber
            pending_def = (def_id, clobber)
            continue
        end
        m_use = match(_RE_MEM_USE, line)
        if m_use !== nothing
            cap = m_use.captures[1]
            if cap != "liveOnEntry"
                pending_use = parse(Int, cap)
            else
                pending_use = 0  # 0 sentinel for live-on-entry use
            end
            continue
        end
        m_phi = match(_RE_MEM_PHI, line)
        if m_phi !== nothing
            phi_id = parse(Int, m_phi.captures[1])
            incoming = Tuple{Symbol, Int}[]
            for em in eachmatch(_RE_PHI_ENTRY, m_phi.captures[2])
                bb = Symbol(em.captures[1])
                val = em.captures[2] == "liveOnEntry" ? 0 : parse(Int, em.captures[2])
                push!(incoming, (bb, val))
            end
            info.phis[phi_id] = incoming
            pending_phi = phi_id
            continue
        end

        # Blank line: annotation stays pending (LLVM sometimes leaves blank
        # lines between annotation and instruction).
        isempty(strip(line)) && continue

        # Non-annotation, non-blank line: attach pending annotations here.
        if pending_def !== nothing
            info.def_at_line[i] = pending_def[1]
            pending_def = nothing
        end
        if pending_use !== nothing
            info.use_at_line[i] = pending_use
            pending_use = nothing
        end
        if pending_phi !== nothing
            # Phi annotations precede the block's first instruction; we record
            # the Phi ID at the instruction line too so the walker can find it.
            info.def_at_line[i] = pending_phi
            pending_phi = nothing
        end
    end

    return MemSSAInfo(info.def_at_line, info.def_clobber, info.use_at_line,
                      info.phis, String(annotated_ir))
end

"""
    run_memssa(f, arg_types::Type{<:Tuple}; preprocess::Bool=true) -> MemSSAInfo

Compile `f` to LLVM IR, run (optional) preprocessing passes, then run
`print<memoryssa>`; return the parsed annotation graph.

When `preprocess=true` runs the default pipeline (sroa/mem2reg/simplifycfg/
instcombine) BEFORE memssa. Most real Julia code wants this — it eliminates
most memory ops before MemorySSA computes, shrinking the graph. Disable only
for tests or debugging the pre-preprocessing IR.
"""
function run_memssa(f, arg_types::Type{<:Tuple}; preprocess::Bool=true)
    ir_string = sprint(io -> code_llvm(io, f, arg_types;
                                        debuginfo=:none, optimize=false, dump_module=true))

    annotated = _run_memssa_on_ir(ir_string; preprocess)
    return parse_memssa_annotations(annotated)
end

function _run_memssa_on_ir(ir_string::AbstractString; preprocess::Bool=true)
    pipe = Pipe()
    local captured::String
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        if preprocess
            _run_passes!(mod, DEFAULT_PREPROCESSING_PASSES)
        end
        # Capture the printer's stderr into a pipe. LLVM writes to a raw
        # ostream that normally maps to stderr — hijack it with redirect_stderr.
        Base.redirect_stderr(pipe) do
            @dispose pb = LLVM.NewPMPassBuilder() begin
                LLVM.add!(pb, "print<memoryssa>")
                LLVM.run!(pb, mod)
            end
        end
        dispose(mod)
    end
    close(pipe.in)
    return read(pipe, String)
end
