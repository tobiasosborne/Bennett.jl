# Bennett-a70z / CW-D (ADR 0017) — EXACT constant-operand overflow bit.
#
# Extends Bennett-lbot: for `extractvalue {iN,i1} %c, 1` where
# `%c = llvm.{s,u}{mul,add}.with.overflow.iN(x, c)` and at least one operand is
# an `LLVM.ConstantInt`, the overflow bit is COMPUTED EXACTLY (not walled) as a
# constant-folded admissible-interval membership test on the dynamic operand:
#
#     bit = (x < L) | (x > U)      L = cld/fld bound, folded at extraction time
#
# emitted as ≤ 2 IRICmp + 1 IRBinOp(:or, w=1), with constant-false arms folded
# to a single IRICmp carrying the extractvalue's own dest. All bound arithmetic
# runs in Int128 (the prover itself must not overflow); unsigned intrinsics
# re-decode the constant by masking, because LLVM.jl's `_const_int_as_int` is
# SIGN-EXTENDING. When the runtime bit is 1, the already-extracted or-chain
# routes to the utzc `:__unreachable__` halt sink — the faithful analogue of
# the throw the native code takes. The lbot fold-to-zero set (mul c ∈ {0,1},
# add c = 0) keeps today's exact `IRBinOp(dest,:add,0,0,1)` shape byte-identical
# (zero counter consumption — klgz determinism).
#
# Two-dynamic-operand ops stay FAIL-LOUD (mul-high/add-carry is future work);
# ssub/usub, idx ∉ {0,1}, and ptr_cells=false stay byte-identical.
#
# Oracle throughout: Base.Checked.{mul,add}_with_overflow at native width.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir_set_from_julia,
               ParsedIR, IRBinOp, IRICmp, IRCall, IRExtractValue,
               ConstOperand, SSAOperand
using Base.Checked: mul_with_overflow, add_with_overflow

# --- Fixtures -------------------------------------------------------------

# Width-parametric fixture: `%o` kept live via `br i1` (matches the real
# memorynew shape; extraction runs no DCE but liveness keeps the shape honest).
function _a70z_fixture(intr::AbstractString, w::Int, cst::AbstractString)
    """
    declare {i$w,i1} @llvm.$(intr).with.overflow.i$w(i$w, i$w)
    define i$w @f(i$w %x) {
    top:
      %c = call {i$w,i1} @llvm.$(intr).with.overflow.i$w(i$w %x, i$w $(cst))
      %p = extractvalue {i$w,i1} %c, 0
      %o = extractvalue {i$w,i1} %c, 1
      br i1 %o, label %oflow, label %ok
    ok:    ret i$w %p
    oflow: ret i$w 0
    }
    """
end

# Two-variable smul (%y is a 2nd arg): still FAIL-LOUD (no constant operand).
const A70Z_TWO_VAR = """
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

function _extract_ll_a70z(name, ir, entry; cells)
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

_all_insts_a70z(pir) = [ins for b in pir.blocks for ins in b.instructions]

# --- Mini-evaluator -------------------------------------------------------
# Interprets the extracted straight-line block (product IRBinOp + bit
# IRICmp/IRBinOp sequence) for a concrete x; returns the overflow bit `:o`.
# Semantics: values are N-bit patterns; signed preds sign-extend, unsigned
# preds mask — the same bit-pattern contract ConstOperand carries.
_a70z_mask(N) = (Int128(1) << N) - Int128(1)
_a70z_sxt(v::Int128, N) = ((v & _a70z_mask(N)) ⊻ (Int128(1) << (N - 1))) - (Int128(1) << (N - 1))
_a70z_uns(v::Int128, N) = v & _a70z_mask(N)

function _a70z_eval_bit(pir::ParsedIR, N::Int, xraw::Integer)
    env = Dict{Symbol,Int128}(:x => Int128(xraw) & _a70z_mask(N))
    val(o) = o isa ConstOperand ? Int128(o.value) : env[o.name]
    for ins in pir.blocks[1].instructions
        if ins isa IRBinOp
            v1, v2 = val(ins.op1), val(ins.op2)
            r = ins.op === :add ? v1 + v2 :
                ins.op === :mul ? v1 * v2 :
                ins.op === :or  ? (v1 | v2) :
                error("a70z eval: unexpected binop :$(ins.op)")
            env[ins.dest] = r & _a70z_mask(ins.width)
        elseif ins isa IRICmp
            v1, v2 = val(ins.op1), val(ins.op2)
            w = ins.width
            r = ins.predicate === :slt ? (_a70z_sxt(v1, w) <  _a70z_sxt(v2, w)) :
                ins.predicate === :sgt ? (_a70z_sxt(v1, w) >  _a70z_sxt(v2, w)) :
                ins.predicate === :ult ? (_a70z_uns(v1, w) <  _a70z_uns(v2, w)) :
                ins.predicate === :ugt ? (_a70z_uns(v1, w) >  _a70z_uns(v2, w)) :
                ins.predicate === :eq  ? (_a70z_uns(v1, w) == _a70z_uns(v2, w)) :
                ins.predicate === :ne  ? (_a70z_uns(v1, w) != _a70z_uns(v2, w)) :
                error("a70z eval: unexpected predicate :$(ins.predicate)")
            env[ins.dest] = Int128(r ? 1 : 0)
        else
            error("a70z eval: unexpected inst $(typeof(ins))")
        end
    end
    return env[:o] == 1
end

# Direct-helper oracle predicate: bit from `_ovf_admissible_range` bounds.
function _a70z_range_bit(op::Symbol, c::Int, N::Int, signed::Bool, x::Integer)
    L, U, always0 = Bennett._ovf_admissible_range(op, c, N, signed)
    always0 && return false
    xi = Int128(x)
    return (L !== nothing && xi < L) || (U !== nothing && xi > U)
end

@testset "Bennett-a70z: exact constant-operand overflow bit" begin

    # =====================================================================
    # (a) i8 EXHAUSTIVE via the FULL extraction path: smul + sadd fixtures,
    #     all 256 x values, oracle = Base.Checked at Int8.
    # =====================================================================
    @testset "(a) i8 exhaustive full-path — smul/sadd vs oracle" begin
        for c in (-128, -8, -2, -1, 2, 3, 8, 127)
            (st, pir) = _extract_ll_a70z("smul8_$(c)", _a70z_fixture("smul", 8, string(c)), "f"; cells=true)
            @test st === :ok
            st === :ok || continue
            @test !any(x -> x isa IRExtractValue || x isa IRCall, _all_insts_a70z(pir))
            ok = true
            for x in Int8(-128):Int8(127)
                oracle = mul_with_overflow(x, Int8(c))[2]
                got = _a70z_eval_bit(pir, 8, x)
                got == oracle || (ok = false; @error "smul i8 mismatch" c x oracle got; break)
            end
            @test ok
        end
        for c in (-128, -5, 5, 127)
            (st, pir) = _extract_ll_a70z("sadd8_$(c)", _a70z_fixture("sadd", 8, string(c)), "f"; cells=true)
            @test st === :ok
            st === :ok || continue
            ok = true
            for x in Int8(-128):Int8(127)
                oracle = add_with_overflow(x, Int8(c))[2]
                got = _a70z_eval_bit(pir, 8, x)
                got == oracle || (ok = false; @error "sadd i8 mismatch" c x oracle got; break)
            end
            @test ok
        end
    end

    # =====================================================================
    # (a2) helper unit sweep: ALL 256 i8 constants x ALL 256 inputs x all
    #      4 intrinsic arms, `_ovf_admissible_range` directly vs oracle.
    #      (Full-path coverage above; this closes the constant space.)
    # =====================================================================
    @testset "(a2) _ovf_admissible_range i8 total sweep vs oracle" begin
        bad = 0
        for craw in 0:255
            cs = Int(reinterpret(Int8, UInt8(craw)))   # sext decode, as _const_int_as_int does
            for xraw in 0:255
                xs = reinterpret(Int8, UInt8(xraw))
                xu = UInt8(xraw)
                bad += (_a70z_range_bit(:mul, cs, 8, true,  Int128(xs)) != mul_with_overflow(xs, Int8(cs))[2])
                bad += (_a70z_range_bit(:add, cs, 8, true,  Int128(xs)) != add_with_overflow(xs, Int8(cs))[2])
                bad += (_a70z_range_bit(:mul, cs, 8, false, Int128(xu)) != mul_with_overflow(xu, UInt8(craw))[2])
                bad += (_a70z_range_bit(:add, cs, 8, false, Int128(xu)) != add_with_overflow(xu, UInt8(craw))[2])
            end
        end
        @test bad == 0
    end

    # =====================================================================
    # (b) i64 c=8 — THE WALL CONSTANT. Structural pin of the exact bounds
    #     (cld(typemin,8) / fld(typemax,8)) + boundary semantics vs oracle.
    # =====================================================================
    @testset "(b) smul(x,8) i64 — bound constants + boundary semantics" begin
        lo = cld(Int128(typemin(Int64)), Int128(8))   # -2^60
        hi = fld(Int128(typemax(Int64)), Int128(8))   #  2^60 - 1
        @test lo == -1152921504606846976
        @test hi ==  1152921504606846975
        (st, pir) = _extract_ll_a70z("smul64_8", _a70z_fixture("smul", 64, "8"), "f"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_a70z(pir)
            lows  = filter(x -> x isa IRICmp && x.predicate === :slt && x.width == 64 &&
                                x.op1 isa SSAOperand && x.op1.name === :x &&
                                x.op2 isa ConstOperand && x.op2.value == -1152921504606846976, insts)
            highs = filter(x -> x isa IRICmp && x.predicate === :sgt && x.width == 64 &&
                                x.op1 isa SSAOperand && x.op1.name === :x &&
                                x.op2 isa ConstOperand && x.op2.value == 1152921504606846975, insts)
            ors   = filter(x -> x isa IRBinOp && x.dest === :o && x.op === :or && x.width == 1, insts)
            @test length(lows) == 1 && length(highs) == 1 && length(ors) == 1
            @test !any(x -> x isa IRExtractValue || x isa IRCall, insts)
            for x in (typemin(Int64), typemin(Int64) + 1, Int64(lo) - 1, Int64(lo),
                      Int64(-1), Int64(0), Int64(1), Int64(hi), Int64(hi) + 1,
                      typemax(Int64) - 1, typemax(Int64))
                @test _a70z_eval_bit(pir, 64, x) == mul_with_overflow(x, Int64(8))[2]
            end
        end
    end

    # =====================================================================
    # (c) sadd constant arm — one-sided: exactly ONE IRICmp with the
    #     extractvalue's own dest, no :or, no counter names.
    # =====================================================================
    @testset "(c) sadd(x,±5) i64 — single-arm fold" begin
        (st, pir) = _extract_ll_a70z("sadd64_5", _a70z_fixture("sadd", 64, "5"), "f"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts_a70z(pir)
            bits = filter(x -> x isa IRICmp, insts)
            @test length(bits) == 1
            b = bits[1]
            @test b.dest === :o && b.predicate === :sgt && b.width == 64
            @test b.op2 isa ConstOperand && b.op2.value == typemax(Int64) - 5
            @test !any(x -> startswith(String(x.dest), "__v"), insts)   # zero counter churn
            for x in (typemax(Int64) - 6, typemax(Int64) - 5, typemax(Int64) - 4,
                      typemax(Int64), typemin(Int64), Int64(0))
                @test _a70z_eval_bit(pir, 64, x) == add_with_overflow(x, Int64(5))[2]
            end
        end
        (st2, pir2) = _extract_ll_a70z("sadd64_m5", _a70z_fixture("sadd", 64, "-5"), "f"; cells=true)
        @test st2 === :ok
        if st2 === :ok
            bits = filter(x -> x isa IRICmp, _all_insts_a70z(pir2))
            @test length(bits) == 1
            b = bits[1]
            @test b.dest === :o && b.predicate === :slt && b.width == 64
            @test b.op2 isa ConstOperand && b.op2.value == typemin(Int64) + 5
            for x in (typemin(Int64), typemin(Int64) + 4, typemin(Int64) + 5,
                      typemax(Int64), Int64(0))
                @test _a70z_eval_bit(pir2, 64, x) == add_with_overflow(x, Int64(-5))[2]
            end
        end
    end

    # =====================================================================
    # (d) unsigned arms with HIGH-BIT constants — the sext-decode trap.
    #     `_const_int_as_int` sign-extends; unsigned bounds must be computed
    #     on the MASKED value, and the emitted bound is bit-pattern-encoded.
    # =====================================================================
    @testset "(d) umul/uadd high-bit constants — masked decode" begin
        # umul i64, c = 2^63 + 9 (sext decode = -9223372036854775799):
        # U = fld(2^64-1, 2^63+9) = 1 → single `ugt x, 1`.
        (st, pir) = _extract_ll_a70z("umul64_hb", _a70z_fixture("umul", 64, "-9223372036854775799"), "f"; cells=true)
        @test st === :ok
        if st === :ok
            bits = filter(x -> x isa IRICmp, _all_insts_a70z(pir))
            @test length(bits) == 1
            b = bits[1]
            @test b.dest === :o && b.predicate === :ugt && b.width == 64
            @test b.op2 isa ConstOperand && b.op2.value == 1
            cu = UInt64(1) << 63 + UInt64(9)
            for x in (UInt64(0), UInt64(1), UInt64(2), UInt64(3), typemax(UInt64))
                @test _a70z_eval_bit(pir, 64, x) == mul_with_overflow(x, cu)[2]
            end
        end
        # umul i8, c = 192 (sext decode = -64): U = fld(255,192) = 1 — exhaustive.
        (st2, pir2) = _extract_ll_a70z("umul8_192", _a70z_fixture("umul", 8, "-64"), "f"; cells=true)
        @test st2 === :ok
        if st2 === :ok
            ok = true
            for x in UInt8(0):UInt8(255)
                oracle = mul_with_overflow(x, UInt8(192))[2]
                got = _a70z_eval_bit(pir2, 8, x)
                got == oracle || (ok = false; @error "umul i8 mismatch" x oracle got; break)
                x == UInt8(255) && break
            end
            @test ok
        end
        # uadd i64, c = 1: U = 2^64 - 2 → bit-pattern ConstOperand -2 (this
        # bound does NOT fit a nonnegative Int64 — pins the sext encoding).
        (st3, pir3) = _extract_ll_a70z("uadd64_1", _a70z_fixture("uadd", 64, "1"), "f"; cells=true)
        @test st3 === :ok
        if st3 === :ok
            bits = filter(x -> x isa IRICmp, _all_insts_a70z(pir3))
            @test length(bits) == 1
            b = bits[1]
            @test b.dest === :o && b.predicate === :ugt && b.width == 64
            @test b.op2 isa ConstOperand && b.op2.value == -2   # bit pattern of 2^64-2
            for x in (UInt64(0), typemax(UInt64) - 2, typemax(UInt64) - 1, typemax(UInt64))
                @test _a70z_eval_bit(pir3, 64, x) == add_with_overflow(x, UInt64(1))[2]
            end
        end
    end

    # =====================================================================
    # (i) fold-to-zero fast path BYTE-STABLE (protects lbot GATE (a) pins):
    #     mul c ∈ {0,1} / add c = 0 still emit the exact IRBinOp(0+0) shape,
    #     with ZERO counter consumption (no __vN dests anywhere).
    # =====================================================================
    @testset "(i) zero-set fast path byte-stable" begin
        for (intr, cst) in (("smul", "1"), ("umul", "0"), ("sadd", "0"), ("uadd", "0"))
            (st, pir) = _extract_ll_a70z("z_$(intr)", _a70z_fixture(intr, 64, cst), "f"; cells=true)
            @test st === :ok
            st === :ok || continue
            insts = _all_insts_a70z(pir)
            bit = filter(x -> x isa IRBinOp && x.dest === :o && x.op === :add &&
                              x.width == 1 &&
                              x.op1 isa ConstOperand && x.op1.value == 0 &&
                              x.op2 isa ConstOperand && x.op2.value == 0, insts)
            @test length(bit) == 1
            @test !any(x -> x isa IRICmp, insts)
            @test !any(x -> startswith(String(x.dest), "__v"), insts)
        end
    end

    # =====================================================================
    # (h) two DYNAMIC operands stay FAIL-LOUD (honest message update).
    # =====================================================================
    @testset "(h) two-dynamic-operand smul stays loud" begin
        (st, msg) = _extract_ll_a70z("twovar", A70Z_TWO_VAR, "f"; cells=true)
        @test st === :err
        if st === :err
            @test occursin("two dynamic operands", msg)
            @test occursin("Bennett-a70z", msg)
            @test occursin("Bennett-lbot", msg)
        end
    end

    # =====================================================================
    # (g) ptr_cells=false BYTE-IDENTITY: the fuse is unreachable off-gate;
    #     the pre-lbot wall disjunction still fires (mirror of lbot GATE (c)).
    # =====================================================================
    @testset "(g) ptr_cells=false stays fail-loud (byte-identity)" begin
        (st, msg) = _extract_ll_a70z("off8", _a70z_fixture("smul", 64, "8"), "f"; cells=false)
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
    # (j) determinism: same fixture extracted twice → identical inst
    #     sequences including __vN dests (klgz-style local guard).
    # =====================================================================
    @testset "(j) determinism — repeated extraction identical" begin
        (st1, pir1) = _extract_ll_a70z("det1", _a70z_fixture("smul", 64, "8"), "f"; cells=true)
        (st2, pir2) = _extract_ll_a70z("det2", _a70z_fixture("smul", 64, "8"), "f"; cells=true)
        @test st1 === :ok && st2 === :ok
        if st1 === :ok && st2 === :ok
            @test string(_all_insts_a70z(pir1)) == string(_all_insts_a70z(pir2))
        end
    end

    # =====================================================================
    # (e) END-TO-END TARGET: fdict64 (Dict{Int64,Int64}) — the elsize-8
    #     smul(%value_phi, 8) wall in rehash! must be GONE. Runs under
    #     on_extract_error=:fail_loud (the wall-discovery mode — under :skip
    #     the closed-world check would mask the wall identity behind a generic
    #     "rehash! is NOT in the set"). Wall-advance is the success criterion;
    #     the NEXT wall (if any) is pinned + logged.
    #     `_known_callees` snapshot/restore (lbot GATE (d) pattern).
    # =====================================================================
    @testset "(e) fdict64 e2e — advances past the elsize-8 smul wall" begin
        fdict64(a::Int64, b::Int64) = (d = Dict{Int64,Int64}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        new_wall = nothing
        try
            msg = try
                extract_parsed_ir_set_from_julia(fdict64, Tuple{Int64,Int64};
                                                 ptr_cells=true, on_extract_error=:fail_loud)
                ""   # fully closed — even stronger than wall-advance
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            new_wall = msg
            # NEGATIVE: the smul.with.overflow elsize-8 wall is GONE.
            @test !occursin("with.overflow", lowercase(msg))
            @test !occursin("not provably zero", msg)
            @test !occursin("two dynamic operands", msg)
            # POSITIVE inclusive disjunction of plausible CW-D2 successors.
            @test occursin("gc_alloc_obj", msg)              ||
                  occursin("genericmemory", lowercase(msg))  ||
                  occursin("memoryref", lowercase(msg))      ||
                  occursin("closed-world violation", msg)    ||
                  msg == ""
            # Full closure of the i64 dict set is NOT yet achieved (next wall
            # documented via @info below + worklog); flips when it closes.
            @test_broken msg == ""
        finally
            lock(Bennett._known_callees_lock) do
                empty!(Bennett._known_callees)
                merge!(Bennett._known_callees, before)
            end
        end
        if new_wall !== nothing && new_wall != ""
            @info "Bennett-a70z fdict64 next wall" wall=first(split(new_wall, "\n"))
        end
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

    # =====================================================================
    # (f) NON-REGRESSION: the Dict{Int8,Int8} set (elsize-1 sites take the
    #     unchanged fold-to-zero path) — same wall class as lbot GATE (d).
    # =====================================================================
    @testset "(f) fdict i8 non-regression" begin
        fdict_d1b8(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        try
            msg = try
                extract_parsed_ir_set_from_julia(fdict_d1b8, Tuple{Int8,Int8};
                                                 ptr_cells=true, on_extract_error=:skip)
                ""
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test !occursin("with.overflow", lowercase(msg))
            @test !occursin("not provably zero", msg)
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
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
