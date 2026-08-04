# test_3vf2_dead_use_global_load.jl — bead `Bennett-3vf2` (CW-D3 / `bennettvm-xkl`
# wall 3): the DEAD-USE DROP for an unrecognised Julia JIT global pointer load.
#
# # What this pins
#
# Under `ptr_cells`, Julia codegen HOISTS `load ptr, ptr @jl_diverror_exception`
# into the LIVE predecessor of a divisor-validity guard diamond whose throwing
# arm is `unreachable`-terminated:
#
#     L13:                                    ; LIVE
#       %20 = or i1 true, %19                 ; structurally-true guard
#       %divisor_valid = and i1 true, %20
#       %jl_diverror_exception = load ptr, ptr @jl_diverror_exception, align 8
#       br i1 %divisor_valid, label %pass, label %fail
#     fail:                                   ; DEAD (Bennett-utzc prunes the body)
#       call void @ijl_throw(ptr %jl_diverror_exception)
#       unreachable
#
# The load therefore SURVIVES the Bennett-utzc dead-block pruner (it is not in a
# dead block) even though its sole consumer does not, and hit the
# `bennettvm-416r.13` unrecognised-JIT-global fail-loud.
#
# 3vf2's rule is NOT a name whitelist and NOT a throw-callee use-shape. It is:
#
#   > a non-volatile, non-atomic `load ptr, ptr @GlobalVariable` that reached the
#   > 416r.13 reject is DROPPED iff it has >= 1 use and EVERY use's parent block
#   > is in the utzc `dead_blocks` set.
#
# Soundness is a theorem about the pruner, not a claim about Julia's naming:
# the pruner replaces every dead block's body with `IRInst[]`, so NO emitted
# `IRInst` can reference the dropped load — the drop cannot dangle. The drop is
# PURE: no `IRInst`, no `.globals` entry, no SSA alias, and the load's `names`
# entry is DELETED so a use that somehow survives fails loud in `_operand`
# instead of dangling.
#
# The fixtures below are hand-written `.ll`, deliberately DECOUPLED from
# `Base._growend!` (CLAUDE.md Rule 5 — Julia will re-mangle and re-block that
# closure every release; this file must not care). The real-corpus landing is
# pinned separately in `test_40ys_instanceless_callees.jl` gate (I).
#
# Ref: docs/design/3vf2/proposal_A.md, docs/design/3vf2/proposal_B.md,
#      src/extract/instructions.jl (the arm + `_all_uses_in_dead_blocks`),
#      src/extract/vector_vm_cfg.jl (`_vec_vm_dead_blocks`, the oracle),
#      src/extract/module_walk.jl (`dead_blocks` computation + threading).

using Test
import Bennett
const _B3 = Bennett
using Bennett: extract_parsed_ir_from_ll

# Extract a hand-written .ll fixture; return (parsed_ir_or_nothing, message).
function _x3vf2(ir::AbstractString; ptr_cells::Bool)
    pir = nothing
    msg = ""
    mktempdir() do dir
        path = joinpath(dir, "f3vf2.ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function="f3vf2",
                                            ptr_cells=ptr_cells)
        catch e
            msg = sprint(showerror, e)
        end
    end
    return pir, msg
end

# Every SSA operand name mentioned anywhere in a ParsedIR (instructions AND
# terminators) — the "no dangling alias" oracle.
function _all_ssa_names(pir)
    out = Symbol[]
    for b in pir.blocks
        insts = Any[b.instructions...]
        b.terminator === nothing || push!(insts, b.terminator)
        for inst in insts, fld in fieldnames(typeof(inst))
            v = getfield(inst, fld)
            if v isa _B3.SSAOperand
                push!(out, v.name)
            elseif v isa AbstractVector
                for e in v
                    e isa _B3.SSAOperand && push!(out, e.name)
                end
            end
        end
    end
    return out
end

# Structural fingerprint: labels, per-block instruction strings, terminators.
_fingerprint(pir) = (pir.ret_width, pir.args, sort(collect(keys(pir.globals))),
                     [(b.label, string.(b.instructions), string(b.terminator))
                      for b in pir.blocks])

# The load-bearing shape: guard diamond, load hoisted into the LIVE block,
# sole use `ijl_throw` in the `unreachable`-terminated arm.
const _IR_BENIGN = """
@jl_diverror_exception = external constant ptr
declare void @ijl_throw(ptr)
define i64 @f3vf2(i64 signext %n) {
top:
  %c0 = icmp ne i64 4, 0
  %c1 = or i1 true, %c0
  %divisor_valid = and i1 true, %c1
  %exc = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
fail:
  call void @ijl_throw(ptr %exc)
  unreachable
pass:
  %q = sdiv i64 %n, 4
  ret i64 %q
}
"""

# HAZARD: identical, but the SAME load is ALSO read in the LIVE %pass block.
const _IR_HAZARD = """
@jl_diverror_exception = external constant ptr
declare void @ijl_throw(ptr)
define i64 @f3vf2(i64 signext %n) {
top:
  %c0 = icmp ne i64 4, 0
  %c1 = or i1 true, %c0
  %divisor_valid = and i1 true, %c1
  %exc = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
fail:
  call void @ijl_throw(ptr %exc)
  unreachable
pass:
  %live = ptrtoint ptr %exc to i64
  %q = sdiv i64 %n, 4
  %r = add i64 %q, %live
  ret i64 %r
}
"""

# ZERO uses: the throw takes `null`, so the load is consumed by nothing at all.
const _IR_ZEROUSE = """
@jl_diverror_exception = external constant ptr
declare void @ijl_throw(ptr)
define i64 @f3vf2(i64 signext %n) {
top:
  %c0 = icmp ne i64 4, 0
  %c1 = or i1 true, %c0
  %divisor_valid = and i1 true, %c1
  %exc = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
fail:
  call void @ijl_throw(ptr null)
  unreachable
pass:
  %q = sdiv i64 %n, 4
  ret i64 %q
}
"""

const _IR_VOLATILE = replace(_IR_BENIGN,
    "%exc = load ptr, ptr @jl_diverror_exception, align 8" =>
    "%exc = load volatile ptr, ptr @jl_diverror_exception, align 8")

# `acquire` is inside Bennett-ares' RELAXABLE band, so under ptr_cells the 4mmt
# guard does NOT fire and this load reaches the 3vf2 arm — which must decline it.
const _IR_ATOMIC = replace(_IR_BENIGN,
    "%exc = load ptr, ptr @jl_diverror_exception, align 8" =>
    "%exc = load atomic ptr, ptr @jl_diverror_exception acquire, align 8")

# Name-agnosticism: a Julia interned-Symbol global and a wholly invented one,
# both in the benign shape. A name-whitelist implementation CANNOT pass these.
const _IR_SYMGLOBAL = replace(_IR_BENIGN, "@jl_diverror_exception" =>
                                          "@\"jl_sym#convert#999\"")
const _IR_FUTURE    = replace(_IR_BENIGN, "@jl_diverror_exception" =>
                                          "@some_future_julia_global")

@testset "Bennett-3vf2 — dead-use drop of unrecognised JIT-global loads" begin

    # -----------------------------------------------------------------
    # (a) THE BEAD: the benign shape extracts, with the load contributing
    #     NOTHING — no IRInst, no `.globals` key, no SSA operand.
    # -----------------------------------------------------------------
    @testset "(a) benign shape: pure drop under ptr_cells" begin
        pir, msg = _x3vf2(_IR_BENIGN; ptr_cells=true)
        @test pir !== nothing
        @test msg == ""
        if pir !== nothing
            @test [b.label for b in pir.blocks] == [:top, :fail, :pass]
            @test pir.ret_width == 64
            @test pir.args == [(:n, 64)]

            top, fail, pass = pir.blocks
            # the load contributed ZERO instructions: icmp + or + and, nothing else
            @test length(top.instructions) == 3
            @test !any(i -> i isa _B3.IRLoad, top.instructions)
            @test top.terminator == _B3.IRBranch(_B3.ssa(:divisor_valid), :pass, :fail)
            # the dead arm is pruned to the reserved unreachable sink (Bennett-utzc)
            @test isempty(fail.instructions)
            @test fail.terminator == _B3.IRBranch(nothing, :__unreachable__, nothing)
            # the live arm is untouched
            @test length(pass.instructions) == 1
            @test pass.instructions[1] isa _B3.IRBinOp
            @test pass.instructions[1].op == :sdiv
            @test pass.terminator isa _B3.IRRet

            # PURE drop: no `.globals` entry was minted for the singleton
            @test isempty(pir.globals)
            # ...and no dangling alias survives anywhere
            @test !(:exc in _all_ssa_names(pir))
            @test !any(n -> occursin("diverror", String(n)), _all_ssa_names(pir))
        end
    end

    # -----------------------------------------------------------------
    # (b) HAZARD — MUST STAY RED FOREVER. The same load is ALSO read in a
    #     LIVE block, so the drop is NOT licensed: dropping it would leave
    #     the live `ptrtoint` with a dangling operand. This is the single
    #     most important test in the file — it pins the inverted-risk
    #     boundary. If it ever goes green, the arm has become unsound.
    # -----------------------------------------------------------------
    @testset "(b) HAZARD live use: stays fail-loud, names the live block" begin
        pir, msg = _x3vf2(_IR_HAZARD; ptr_cells=true)
        @test pir === nothing
        @test occursin("UNRECOGNIZED Julia JIT global", msg)
        @test occursin("jl_diverror_exception", msg)
        @test occursin("Bennett-3vf2", msg)
        # names the LIVE block that disqualified the drop
        @test occursin("%pass", msg)
        # graft (4a): an exception-singleton name with a LIVE use is called out
        @test occursin("exception singleton", msg)
    end

    # -----------------------------------------------------------------
    # (c) ZERO uses → still rejects. A use-less unrecognised global load is
    #     not evidence of a modelled construct; refusing costs nothing and
    #     keeps 3vf2 from swallowing an incomplete picture of the function.
    #     (This is also the shape of `test_416r13` testset (3), which must
    #     therefore NOT flip.)
    # -----------------------------------------------------------------
    @testset "(c) zero-use load: stays fail-loud" begin
        pir, msg = _x3vf2(_IR_ZEROUSE; ptr_cells=true)
        @test pir === nothing
        @test occursin("UNRECOGNIZED Julia JIT global", msg)
        @test occursin("ZERO uses", msg)
        @test occursin("Bennett-3vf2", msg)
    end

    # -----------------------------------------------------------------
    # (d) VOLATILE → the Bennett-4mmt / U14 guard fires FIRST, at both
    #     gates. A volatile load is an observable I/O event and must never
    #     be dropped; pinned here so a future relaxation of 4mmt (the way
    #     Bennett-ares relaxed the ATOMIC half under ptr_cells) cannot
    #     silently hand a volatile load to the 3vf2 arm unnoticed.
    # -----------------------------------------------------------------
    @testset "(d) volatile load: 4mmt guard wins at both gates" begin
        for pc in (true, false)
            pir, msg = _x3vf2(_IR_VOLATILE; ptr_cells=pc)
            @test pir === nothing
            @test occursin("volatile load not supported", msg)
            @test occursin("Bennett-4mmt", msg)
        end
    end

    # -----------------------------------------------------------------
    # (e) ATOMIC `acquire` under ptr_cells is in Bennett-ares' relaxable
    #     band, so it REACHES the 3vf2 arm — which declines it. The drop is
    #     only proven for a plain, non-atomic load.
    # -----------------------------------------------------------------
    @testset "(e) atomic (relaxable-band) load: 3vf2 declines, stays loud" begin
        pir, msg = _x3vf2(_IR_ATOMIC; ptr_cells=true)
        @test pir === nothing
        @test occursin("UNRECOGNIZED Julia JIT global", msg)
        @test occursin("Bennett-3vf2", msg)
        @test occursin("atomic", msg)
    end

    # -----------------------------------------------------------------
    # (f) NAME-AGNOSTICISM — the design-choice tripwire. 3vf2 is a dead-use
    #     rule, NOT a `jl_*_exception` whitelist. If a future refactor
    #     "simplifies" the arm into a name whitelist, THESE go red and this
    #     comment says why. `@jl_sym#convert#NNN` is not hypothetical: it is
    #     already present in the real `_growend!` body (today its load sits
    #     INSIDE a dead block, so the pruner hides it — one codegen change
    #     from becoming the next wall).
    # -----------------------------------------------------------------
    @testset "(f) name-agnosticism: any global with all-dead uses drops" begin
        for (nm, ir) in (("jl_sym#convert#999", _IR_SYMGLOBAL),
                         ("some_future_julia_global", _IR_FUTURE))
            pir, msg = _x3vf2(ir; ptr_cells=true)
            @test pir !== nothing
            @test msg == ""
            if pir !== nothing
                @test [b.label for b in pir.blocks] == [:top, :fail, :pass]
                @test length(pir.blocks[1].instructions) == 3
                @test isempty(pir.globals)
                @test !(:exc in _all_ssa_names(pir))
            end
        end
    end

    # -----------------------------------------------------------------
    # (g) `ptr_cells=false` BYTE-IDENTITY. The arm lives inside the
    #     `ptr_cells` region and `dead_blocks` is itself gate-empty, so the
    #     circuit path cannot see it. Two pins: (1) the benign fixture's
    #     ptr_cells=false ParsedIR is structurally IDENTICAL to the
    #     ptr_cells=true one (the circuit path has ALWAYS dropped this load,
    #     via the silent `return nothing` non-integer-load skip — 3vf2 only
    #     makes the closed-world path agree, under a proof the circuit path
    #     never had); (2) the hazard fixture keeps its pre-existing
    #     `ptrtoint ... unsupported LLVM opcode` reject.
    # -----------------------------------------------------------------
    @testset "(g) ptr_cells=false: untouched" begin
        on,  _   = _x3vf2(_IR_BENIGN; ptr_cells=true)
        off, msg = _x3vf2(_IR_BENIGN; ptr_cells=false)
        @test off !== nothing
        @test msg == ""
        @test on !== nothing
        if on !== nothing && off !== nothing
            @test _fingerprint(on) == _fingerprint(off)
        end

        hz, hmsg = _x3vf2(_IR_HAZARD; ptr_cells=false)
        @test hz === nothing
        @test occursin("ptrtoint", hmsg)
        @test occursin("unsupported LLVM opcode", hmsg)
        @test !occursin("Bennett-3vf2", hmsg)

        sym, smsg = _x3vf2(_IR_SYMGLOBAL; ptr_cells=false)
        @test sym !== nothing
        @test smsg == ""
    end
end
