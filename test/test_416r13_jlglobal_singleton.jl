# test_416r13_jlglobal_singleton.jl — bead `bennettvm-416r.13` (CW-D3 Lever 2):
# front-end recognition of `jl_global#NNN` empty-GenericMemory singleton-data
# globals + the tightened fail-loud on an UNRECOGNIZED JIT-global pointer load.
#
# # What this pins (front-end half of Design B)
#
#   (1) `extract_parsed_ir(fdict, …; ptr_cells=true)` seeds a zeroed 16-cell /
#       ew-8 header into `ParsedIR.globals` for every `jl_global#NNN` singleton
#       the Dict constructor references (count/shape asserted, NOT the drifting
#       `#NNN` numbers — LLVM IR is not a stable API, CLAUDE.md Rule 5);
#   (2) every `jl_global…` SSA operand RESOLVES to a `.globals` key — the
#       singleton `load ptr, ptr @"jl_global#NNN"` was dropped and its load-
#       result name aliased to the canonical global-variable name, so NO
#       dangling operand survives (Design B D3, the "loaded twice" wrinkle);
#   (3) a `ptr_cells` `load ptr, ptr @GlobalVariable` whose global is NEITHER a
#       `+Type#N` type-tag NOR a `jl_global#N` singleton FAILS LOUD at the load
#       site (Design A D2 adopted) — never a silently-dropped dangling operand.
#
# The recogniser is name-based (`+` vs `jl_global#` vs neither) because the two
# recognised subsets are BYTE-IDENTICAL in LLVM shape (a `constant ptr @X.jit`
# whose aliasee is an unrepresentable `inttoptr` — `LLVM.initializer` THROWS
# `Unknown value kind LLVMGlobalAliasValueKind`, the opaque-initializer signature
# that gates the zeroed-header arm; settled empirically 2026-07-12).
#
# Ref: scratchpad/design-jlglobal-B.md (D2/D3), scratchpad/scout-jlglobal-
#      census.md (Q2/Q4), src/extract/constexpr.jl
#      (`_is_singleton_data_global_name`), src/extract/module_walk.jl
#      (`_extract_const_globals` init===nothing arm), src/extract/instructions.jl
#      (the load-handler singleton alias + the unrecognized-global fail-loud).

using Test
import Bennett
const _B = Bennett
using Bennett: extract_parsed_ir_set_from_julia, extract_parsed_ir_from_ll

# Collect every SSA operand name (scalar field or Vector element) of an IRInst.
function _ssa_names(inst)
    out = Symbol[]
    for fld in fieldnames(typeof(inst))
        v = getfield(inst, fld)
        if v isa _B.SSAOperand
            push!(out, v.name)
        elseif v isa AbstractVector
            for e in v
                e isa _B.SSAOperand && push!(out, e.name)
            end
        end
    end
    return out
end

@testset "bennettvm-416r.13 — jl_global singleton front-end recognition" begin

    # ---------------------------------------------------------------------
    # (1)+(2) real fdict root: singleton headers seeded + no dangling operand.
    # ---------------------------------------------------------------------
    @testset "(1)+(2) fdict root: singleton headers + no dangling jl_global" begin
        # The SET path (not single-function `extract_parsed_ir`) is required: the
        # root `fdict` LLVM carries the `movq %fs:0` pgcstack inline-asm, which
        # only the closed-world set path (GC-preamble recognition) handles; the
        # single-function path fails loud on it (U15 inline-asm reject).
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                               ptr_cells = true)
        root = first(set).second

        # Every jl_global# globals entry (root PIR) is a zeroed 16-cell / ew-8
        # header. Count asserted (>= 1), numbers NOT pinned (drift-immune).
        singletons = [(k, v) for (k, v) in root.globals
                      if occursin("jl_global", String(k))]
        @test !isempty(singletons)
        for (_k, (data, ew)) in singletons
            @test length(data) == 16
            @test ew == 8
            @test all(==(0), data)                  # ships ONLY zeros (no VM addr)
        end

        # No dangling operand across the WHOLE set: every `jl_global…` SSAOperand
        # resolves to that PIR's `.globals` key (the dropped-load result names
        # were aliased to the canonical global-variable name — Design B D3).
        dangling = Tuple{Symbol,Symbol}[]
        for (fk, pir) in set
            gkeys = keys(pir.globals)
            for blk in pir.blocks, inst in blk.instructions
                for nm in _ssa_names(inst)
                    occursin("jl_global", String(nm)) && !(nm in gkeys) &&
                        push!(dangling, (fk, nm))
                end
            end
        end
        @test isempty(dangling)
    end

    # ---------------------------------------------------------------------
    # (3) an UNRECOGNIZED JIT-global pointer load fails loud (Design A D2).
    # ---------------------------------------------------------------------
    @testset "(3) unrecognized JIT-global pointer load fails loud" begin
        # A `constant ptr` global named neither `+Type#N` nor `jl_global#N`,
        # loaded as a pointer under ptr_cells.
        ir = """
        @"weird_global#5" = private unnamed_addr constant ptr null
        define i64 @wf(ptr noundef %p) {
        entry:
          %x = load ptr, ptr @"weird_global#5", align 8
          ret i64 0
        }
        """
        threw = false
        msg = ""
        mktempdir() do dir
            path = joinpath(dir, "wf.ll")
            write(path, ir)
            try
                extract_parsed_ir_from_ll(path; entry_function = "wf",
                                          ptr_cells = true)
            catch e
                threw = true
                msg = sprint(showerror, e)
            end
        end
        @test threw
        @test occursin("UNRECOGNIZED", msg)
        @test occursin("weird_global#5", msg)       # names the offending global

        # CONTROL: with ptr_cells=false the tightening is INERT — the unused
        # pointer-load keeps its pre-existing silent skip (`return nothing`), so
        # extraction succeeds and our fail-loud never fires.
        threw_off = false
        msg_off = ""
        mktempdir() do dir
            path = joinpath(dir, "wf.ll")
            write(path, ir)
            try
                extract_parsed_ir_from_ll(path; entry_function = "wf",
                                          ptr_cells = false)
            catch e
                threw_off = true
                msg_off = sprint(showerror, e)
            end
        end
        @test !threw_off                             # ptr_cells=false: no wall
        @test !occursin("UNRECOGNIZED", msg_off)     # tightening stayed inert
    end
end
