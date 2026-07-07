# Bennett-lbot / CW-D (ADR 0017 CW-D workstream) — overflow-arith intrinsics
# under the closed-world `ptr_cells=true` VM gate.
#
# Julia's GenericMemory allocation-size check emits
#
#   %c = call {i64,i1} @llvm.smul.with.overflow.i64(i64 %newsz, i64 1)
#   %p = extractvalue {i64,i1} %c, 0        ; the wrapped product
#   %o = extractvalue {i64,i1} %c, 1        ; the overflow bit
#   br i1 %o, label %oflow, label %ok
#
# The `{iN,i1}` aggregate is NEVER modeled (an i1 struct field hits the 6bu3
# i1-field reject on BOTH repos). Instead the intrinsic + its two extractvalues
# are FUSED into SCALAR IRInsts, re-deriving the scalars directly from the
# intrinsic call's own operands:
#   - extractvalue-0 (product/sum)  → IRBinOp(dest, :mul|:add, a, b, N)
#   - extractvalue-1 (overflow bit) → IRBinOp(dest, :add, iconst(0), iconst(0), 1)
#     ONLY when the operation is PROVABLY no-overflow, else FAIL LOUD.
#
# CRITICAL fold predicate (both blind proposers independently corrected the
# brief): the provably-no-overflow constant set for MUL is `{0,1}` ONLY — NOT
# `{-1,0,1}`. Signed `smul(x,-1) = -x` overflows at x = INT_MIN
# (`-2^(N-1) * -1 = 2^(N-1)` is not representable). For ADD the set is `{0}`.
# Anything else → fail loud (NO placeholder-0: a wrong 0 would route away from
# the throw the native code takes and is UNSOUND).
#
# Mechanism: STATELESS fuse (no side-table). Two ptr_cells-gated spots in
# src/extract/instructions.jl — a CALL "return nothing" skip (the {iN,i1} call
# emits no IRInst; its ref is consumed ONLY by the two extractvalues) and an
# extractvalue-handler fuse to `_fuse_overflow_extractvalue`. Auto-gated ⇒
# byte-identical when ptr_cells=false.
#
# Baseline walls (captured 2026-07-07, pre-lbot):
#   ptr_cells=true : "...unsupported return type LLVM.StructType({ i64, i1 })
#                     under ptr_cells; ... (BVM ADR 0020 D5 / chunk C)"  (the
#                     ptr_cells C-call D5 return-type reject)
#   ptr_cells=false: "...has no registered callee handler ... (Bennett-5oyt / U15)"

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               extract_parsed_ir_set_from_julia,
               ParsedIR, IRBinOp, IRCall, IRExtractValue,
               ConstOperand, SSAOperand

# --- Fixtures -------------------------------------------------------------

# GREEN fixture builder: `%o` is kept LIVE (fed to a `br i1`) so it is not
# DCE'd. extraction runs no DCE but keeping it live matches the real IR shape.
function _lbot_fixture(intr::AbstractString, cst::AbstractString)
    """
    declare {i64,i1} @llvm.$(intr).with.overflow.i64(i64, i64)
    define i64 @f(i64 %x) {
    top:
      %c = call {i64,i1} @llvm.$(intr).with.overflow.i64(i64 %x, i64 $(cst))
      %p = extractvalue {i64,i1} %c, 0
      %o = extractvalue {i64,i1} %c, 1
      br i1 %o, label %oflow, label %ok
    ok:    ret i64 %p
    oflow: ret i64 0
    }
    """
end

# Two-variable smul (%y is a 2nd arg): product folds, but the overflow bit is
# NOT provably zero → fail loud.
const LBOT_TWO_VAR = """
declare {i64,i1} @llvm.smul.with.overflow.i64(i64, i64)
define i64 @f(i64 %x, i64 %y) {
top:
  %c = call {i64,i1} @llvm.smul.with.overflow.i64(i64 %x, i64 %y)
  %p = extractvalue {i64,i1} %c, 0
  %o = extractvalue {i64,i1} %c, 1
  br i1 %o, label %oflow, label %ok
ok:    ret i64 %p
oflow: ret i64 0
}
"""

# Nonzero-const sadd(%x, 5): x+5 CAN overflow → overflow bit not provably zero.
const LBOT_ADD5 = """
declare {i64,i1} @llvm.sadd.with.overflow.i64(i64, i64)
define i64 @f(i64 %x) {
top:
  %c = call {i64,i1} @llvm.sadd.with.overflow.i64(i64 %x, i64 5)
  %p = extractvalue {i64,i1} %c, 0
  %o = extractvalue {i64,i1} %c, 1
  br i1 %o, label %oflow, label %ok
ok:    ret i64 %p
oflow: ret i64 0
}
"""

# --- Extraction helper ----------------------------------------------------
function _extract_ll_lbot(name, ir, entry; cells)
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

_all_insts_lbot(pir) = [ins for b in pir.blocks for ins in b.instructions]

@testset "Bennett-lbot CW-D: overflow-arith intrinsic fuse under ptr_cells" begin

    # =====================================================================
    # GATE (a) — GREEN: the {i64,i1} smul(%x,1) fuses to scalar IRBinOps.
    # =====================================================================
    @testset "GATE (a) — smul(%x,1) fuses; product IRBinOp + bit=0; no call/extractvalue survive" begin
        (st, pir) = _extract_ll_lbot("smul1", _lbot_fixture("smul", "1"), "f"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_lbot(pir)
            # Exactly one IRBinOp product: dest=:p, op=:mul, op1=SSA(:x), op2=const 1, w=64.
            prod = filter(x -> x isa IRBinOp && x.dest === :p && x.op === :mul &&
                               x.width == 64 &&
                               x.op1 isa SSAOperand && x.op1.name === :x &&
                               x.op2 isa ConstOperand && x.op2.value == 1, insts)
            @test length(prod) == 1
            # Exactly one IRBinOp overflow bit: dest=:o, op1==op2==const 0.
            bit = filter(x -> x isa IRBinOp && x.dest === :o &&
                              x.op1 isa ConstOperand && x.op1.value == 0 &&
                              x.op2 isa ConstOperand && x.op2.value == 0, insts)
            @test length(bit) == 1
            # NO IRCall to any llvm.*.with.overflow survives.
            @test !any(x -> x isa IRCall &&
                            occursin("with.overflow", String(x.callee isa Symbol ? x.callee : Symbol(x.callee))),
                       insts)
            # NO IRExtractValue of the {i64,i1} aggregate survives.
            @test !any(x -> x isa IRExtractValue, insts)
        end
    end

    # =====================================================================
    # GATE (a-variants) — umul(%x,0), sadd(%x,0), uadd(%x,0): each product folds
    # with the right op and each overflow bit folds to 0.
    # =====================================================================
    @testset "GATE (a-variants) — umul/sadd/uadd fold bit to 0 with right op" begin
        for (intr, expected_op) in (("umul", :mul), ("sadd", :add), ("uadd", :add))
            (st, pir) = _extract_ll_lbot(intr, _lbot_fixture(intr, "0"), "f"; cells=true)
            @test st === :ok
            if st === :ok
                insts = _all_insts_lbot(pir)
                prod = filter(x -> x isa IRBinOp && x.dest === :p && x.op === expected_op &&
                                   x.width == 64 &&
                                   x.op1 isa SSAOperand && x.op1.name === :x &&
                                   x.op2 isa ConstOperand && x.op2.value == 0, insts)
                @test length(prod) == 1
                bit = filter(x -> x isa IRBinOp && x.dest === :o &&
                                  x.op1 isa ConstOperand && x.op1.value == 0 &&
                                  x.op2 isa ConstOperand && x.op2.value == 0, insts)
                @test length(bit) == 1
                @test !any(x -> x isa IRExtractValue, insts)
            end
        end
    end

    # =====================================================================
    # GATE (b) — FAIL-LOUD: the overflow bit is not provably zero.
    #   (b1) two-variable smul(%x,%y)
    #   (b2) nonzero-const sadd(%x,5)
    # =====================================================================
    @testset "GATE (b) — non-provably-zero overflow bit fails loud" begin
        (st1, msg1) = _extract_ll_lbot("twovar", LBOT_TWO_VAR, "f"; cells=true)
        @test st1 === :err
        if st1 === :err
            @test occursin("not provably zero", msg1)
            @test occursin("Bennett-lbot", msg1)
        end

        (st2, msg2) = _extract_ll_lbot("add5", LBOT_ADD5, "f"; cells=true)
        @test st2 === :err
        if st2 === :err
            @test occursin("not provably zero", msg2)
            @test occursin("Bennett-lbot", msg2)
        end
    end

    # =====================================================================
    # GATE (c) — BYTE-IDENTITY: with ptr_cells=false the SAME (a) fixture walls
    # at the pre-existing "no registered callee / U15" reject (the fuse arms are
    # ptr_cells-gated; the circuit path is unchanged). Assert it is NOT the
    # fused-success shape.
    # =====================================================================
    @testset "GATE (c) — ptr_cells=false: pre-fix wall unchanged (byte-identity)" begin
        (st, msg) = _extract_ll_lbot("off", _lbot_fixture("smul", "1"), "f"; cells=false)
        @test st === :err
        if st === :err
            @test occursin("unsupported", lowercase(msg)) ||
                  occursin("U15", msg) ||
                  occursin("i64, i1", msg) ||
                  occursin("width 1", msg) ||
                  occursin("6bu3", msg) ||
                  occursin("no registered callee", msg)
        end
    end

    # =====================================================================
    # GATE (d) — REAL TARGET: fdict_d1b set advance under ptr_cells=true. Pre-lbot
    # the closed-world fdict set walls at `llvm.smul.with.overflow.i64` (the
    # GenericMemory alloc-size check in `rehash!`). Post-lbot the smul fuses and
    # the wall ADVANCES to the CW-D2 gc_alloc_obj / genericmemory frontier. Assert
    # NEGATIVELY (no longer the smul/{i64,i1} wall) + inclusive successor
    # disjunction. `_known_callees` snapshot/restore (Rule 7).
    # =====================================================================
    @testset "GATE (d) — fdict_d1b set advances past the smul.with.overflow wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        new_wall = nothing
        try
            msg = try
                extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                 ptr_cells=true, on_extract_error=:skip)
                ""   # fully closed — even stronger than wall-advance
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            new_wall = msg
            # NEGATIVE: the smul / {i64,i1} return-type wall is gone.
            @test !occursin("smul", lowercase(msg))
            @test !occursin("with.overflow", lowercase(msg))
            @test !occursin("{ i64, i1 }", msg)
            # POSITIVE inclusive disjunction of plausible CW-D2 successors.
            @test occursin("gc_alloc_obj", msg)              ||
                  occursin("genericmemory", lowercase(msg))  ||
                  occursin("closed-world violation", msg)    ||
                  msg == ""
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end
        if new_wall !== nothing && new_wall != ""
            @info "Bennett-lbot fdict_d1b new wall" wall=first(split(new_wall, "\n"))
        end

        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
