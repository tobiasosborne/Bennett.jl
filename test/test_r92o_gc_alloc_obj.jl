# Bennett-r92o / CW-D3 Lever 2 — `julia.gc_alloc_obj` extraction under the
# closed-world `ptr_cells=true` VM gate.
#
# The Julia GC-typed-allocation cluster the `fdict` root hits is:
#
#   %tag  = load ptr, ptr @"+Main.Base.Dict#148"   ; type-tag global  (Lever 1)
#   %Dict = ptrtoint ptr %tag to i64                ; (Lever 1)
#   %1    = inttoptr i64 %Dict to ptr               ; (Lever 1)
#   %obj  = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %1)   ; <- Lever 2
#
# Lever 2 (THIS bead) models ONLY the gc_alloc_obj call — consensus decision 4 of
# docs/design/Bennett-iwo9-CW-D3-typetag-consensus.md. Lever 1 (type-tag globals +
# ptrtoint/inttoptr) and Lever 3 (BennettVM arena ingest) are out of scope.
#
# Consensus decision 4 (verbatim shape):
#   - Intercept `cname == "julia.gc_alloc_obj"` under `ptr_cells=true`, BEFORE the
#     generic C-call lowering / benign-prefix allowlist (inside `if ptr_cells`).
#   - Emit a Symbol-callee IRCall (Bennett-k3ej): callee === :gc_alloc_obj,
#     args = [size_op, tag_op] (the `task` first arg is DROPPED — a %pgcstack GEP
#     with no VM meaning), arg_widths == [64, 64], ret_width == 64.
#   - Fail loud (CLAUDE.md §1) if the arg count ≠ 3.
#   - Under `ptr_cells=false`: NO intercept — the broad `julia.gc_` benign drop /
#     pre-existing wall stays intact, so no :gc_alloc_obj IRCall is produced
#     (circuit path byte-identical).
#
# LLVM operand layout (verified empirically 2026-06-23):
#   `call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %1)` →
#   ops = [task, size, tag, callee]; n_ops == 4; ops[n_ops] is the callee.
#   ops[1]=task(ptr, DROP), ops[2]=size(i64), ops[3]=tag(ptr). Arity check: n_ops==4.
#
# Pre-fix wall (R1, empirically captured 2026-06-23):
#   Under ptr_cells=true the generic C-call arm (instructions.jl ~line 2198)
#   currently catches gc_alloc_obj and emits the WRONG shape:
#     IRCall(:obj, Symbol("julia.gc_alloc_obj"), [SSAOperand(:task), 64, tag], [64,64,64], 64)
#   i.e. callee is the full dotted name (NOT :gc_alloc_obj) and the task arg is
#   carried (3 args, not 2). RED: the consensus-correct assertions below fail.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, ParsedIR, IRCall, ConstOperand, SSAOperand

# --- Fixtures -------------------------------------------------------------
# `@julia.gc_alloc_obj` MUST be `declare`d for the .ll to parse (LLVM rejects
# calls to undefined values). `%task` is a FUNCTION ARG — this avoids the real
# %pgcstack GEP AND the Lever-1 inttoptr-of-non-tag fail-loud (the only inttoptr
# here, %1, is sourced from a recognised type tag, so it lowers cleanly).

# GATE (a): full isolated cluster (tag global → ptrtoint → inttoptr → gc_alloc_obj).
const GC_ALLOC_CLUSTER = """
@"+Main.Base.Dict#148" = external global ptr

declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)

define ptr @f(ptr %task) {
top:
  %tag = load ptr, ptr @"+Main.Base.Dict#148"
  %d = ptrtoint ptr %tag to i64
  %1 = inttoptr i64 %d to ptr
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %1)
  ret ptr %obj
}
"""

# GATE (b): wrong arity — gc_alloc_obj with only 2 args (no tag). `%task` arg
# isolates (no tag cluster). Under ptr_cells=true this must fail loud with a
# gc_alloc_obj / r92o / CW-D3 breadcrumb.
const GC_ALLOC_ARITY2 = """
declare ptr @julia.gc_alloc_obj(ptr, i64)

define ptr @f(ptr %task) {
top:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 64)
  ret ptr %obj
}
"""

# GATE (c): gc_alloc_obj reachable WITHOUT the tag cluster — `%ty` is a function
# arg (so no ptrtoint wall blocks it). Under ptr_cells=false the intercept does
# NOT fire (broad julia.gc_ drop / pre-existing wall) → no :gc_alloc_obj IRCall.
# Under ptr_cells=true the SAME fixture DOES emit the :gc_alloc_obj IRCall.
const GC_ALLOC_NO_TAG = """
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)

define void @h(ptr %task, ptr %ty) {
top:
  %obj = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %ty)
  ret void
}
"""

# --- Extraction helper ----------------------------------------------------
function _extract_ll_r92o(name, ir, entry; cells)
    mktempdir() do dir
        path = joinpath(dir, "$(name).ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=cells)
            return (:ok, pir)
        catch e
            e isa InterruptException && rethrow()
            return (:err, sprint(showerror, e))
        end
    end
end

_all_insts_r92o(pir) = [ins for b in pir.blocks for ins in b.instructions]

# Find every gc_alloc_obj IRCall (callee === :gc_alloc_obj, the Symbol form).
_gc_alloc_calls(pir) =
    [ins for ins in _all_insts_r92o(pir)
         if ins isa IRCall && ins.callee === :gc_alloc_obj]

@testset "Bennett-r92o CW-D3 Lever 2: julia.gc_alloc_obj extraction" begin

    # =====================================================================
    # GATE (a) — ptr_cells=true, full isolated cluster: gc_alloc_obj lowers
    # to a Symbol-callee IRCall(:gc_alloc_obj, [size, tag], [64,64], 64) with
    # the task arg DROPPED and the dest bound (= the %obj symbol).
    # =====================================================================
    @testset "GATE (a) — gc_alloc_obj → :gc_alloc_obj IRCall under ptr_cells" begin
        (st, pir) = _extract_ll_r92o("cluster", GC_ALLOC_CLUSTER, "f"; cells=true)
        @test st === :ok
        if st === :ok
            calls = _gc_alloc_calls(pir)
            @test length(calls) == 1
            if length(calls) == 1
                c = calls[1]
                # Symbol callee (Bennett-k3ej path), not the dotted LLVM name.
                @test c.callee === :gc_alloc_obj
                # task DROPPED → exactly [size, tag].
                @test length(c.args) == 2
                @test c.arg_widths == [64, 64]
                @test c.ret_width == 64
                # dest is the %obj SSA symbol (bound through the normal path).
                @test c.dest === :obj
                # arg 1 = size (constant 64); arg 2 = tag (SSA ref to %1).
                @test c.args[1] isa ConstOperand
                @test c.args[1].value == 64
                # arg 2 = tag: an SSA ref (to the bound inttoptr dest %1; the
                # numeric LLVM name %1 is auto-renamed, so we assert the
                # structural shape, not the brittle auto-name).
                @test c.args[2] isa SSAOperand
                # The dropped task arg never appears as an arg.
                @test !any(a -> a isa SSAOperand && a.name === :task, c.args)
                # The tag operand binds to a real SSA def in the same function
                # (the inttoptr/load chain), not the dropped task arg.
                tag_name = c.args[2].name
                @test tag_name !== :task
            end
        end
    end

    # =====================================================================
    # GATE (b) — FAIL-LOUD: gc_alloc_obj with the wrong arity (2 args, no tag)
    # under ptr_cells=true must fail loud with a gc_alloc_obj / r92o / CW-D3
    # breadcrumb (CLAUDE.md §1).
    # =====================================================================
    @testset "GATE (b) — wrong arity gc_alloc_obj fails loud" begin
        (st, msg) = _extract_ll_r92o("arity2", GC_ALLOC_ARITY2, "f"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("gc_alloc_obj", msg)
            @test occursin("r92o", msg) || occursin("CW-D3", msg)
        end
    end

    # =====================================================================
    # GATE (c) — BYTE-IDENTITY: a gc_alloc_obj reachable without the tag
    # cluster. Under ptr_cells=false NO :gc_alloc_obj IRCall is produced (the
    # intercept is gated off — pre-existing behavior unchanged). Under
    # ptr_cells=true the SAME fixture DOES emit the :gc_alloc_obj IRCall.
    # =====================================================================
    @testset "GATE (c) — ptr_cells gate: off=no IRCall, on=IRCall" begin
        # OFF: intercept does not fire → no :gc_alloc_obj IRCall (whether the
        # fixture errors at a pre-existing wall or extracts without it).
        (st_off, res_off) = _extract_ll_r92o("notag_off", GC_ALLOC_NO_TAG, "h"; cells=false)
        if st_off === :ok
            @test isempty(_gc_alloc_calls(res_off))
        else
            # Pre-existing wall (e.g. U81 void derivation) — definitionally no
            # :gc_alloc_obj IRCall. Baseline unchanged by the gated intercept.
            @test st_off === :err
        end
        # ON: the intercept fires → exactly one :gc_alloc_obj IRCall.
        (st_on, res_on) = _extract_ll_r92o("notag_on", GC_ALLOC_NO_TAG, "h"; cells=true)
        @test st_on === :ok
        if st_on === :ok
            calls = _gc_alloc_calls(res_on)
            @test length(calls) == 1
            if length(calls) == 1
                c = calls[1]
                @test c.callee === :gc_alloc_obj
                @test length(c.args) == 2          # task dropped
                @test c.arg_widths == [64, 64]
                @test c.ret_width == 64
            end
        end
    end

end
