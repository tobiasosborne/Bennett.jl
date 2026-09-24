using Test
using Random
using Bennett
using Bennett: IRBinOp, IRPhi, IRRet, IRBranch, IRBasicBlock, IRInst

# Bennett-stwr — `add=:cuccaro` soundness.
#
# Pre-fix, `_pick_add_strategy` returned `:cuccaro` for EVERY add under an
# explicit `add=:cuccaro` without consulting the (already wrong) `op2_dead`
# SSA-liveness guard, so `lower_add_cuccaro!` overwrote op2's wires even when
# op2 was read again later — by a sibling branch (every block executes in the
# predicated lowering), by a phi / multi-ret merge, by a load re-resolving a
# VarGEP index, by a non-LIFO uncompute schedule (ValueEagerStrategy), or by
# the same add (`x + x`). Most instances were SILENT (wrong answers, no
# simulator error): e.g. `soft_fadd` under `add=:cuccaro` was 29/30 wrong.
#
# Fix (3+1: docs/design/stwr/ proposal B criterion + proposal A defence in
# depth): an add operand is an in-place target iff it is a constant, or an SSA
# name with exactly ONE operand occurrence in the whole ParsedIR that is a
# function argument or a fresh-wire def (`_INPLACE_FRESH_DEFS`, IRPhi
# excluded), and — at lowering time — no other live SSA name shares its wires.
# op2 is preferred; op1 is used by commutativity; otherwise op2 is CNOT-copied
# ("copy-in") and Cuccaro runs on the private copy. Loop-unrolling contexts get
# the empty target set. Every add is still MAJ/UMA (2W−3 Toffolis).

# ---- helpers ---------------------------------------------------------------

const _STWR_STRATEGIES = Any[DefaultStrategy(), ValueEagerStrategy(), EagerStrategy(),
                             CheckpointStrategy(), PebbledGroupStrategy(4),
                             PebbledStrategy(40)]

_stwr_insts(p) = IRInst[i for b in p.blocks for i in b.instructions]
_stwr_adds(p) = [i for i in _stwr_insts(p) if i isa IRBinOp && i.op === :add]
_stwr_is(op, name) = op isa SSAOperand && op.name === name
_stwr_arg(p, k) = p.args[k][1]

"Number of operand occurrences of `name` in the whole ParsedIR (insts + terminators)."
function _stwr_occ(p, name::Symbol)
    n = 0
    for b in p.blocks
        for i in b.instructions
            n += count(==(name), Bennett._ssa_operands(i))
        end
        n += count(==(name), Bennett._ssa_operands(b.terminator))
    end
    return n
end

_stwr_block_of(p, pred) = only(b.label for b in p.blocks if any(pred, b.instructions))
_stwr_topo(p) = Bennett.topo_sort(p.blocks; ignore_edges=Bennett.find_back_edges(p.blocks))

"Count (wrong answers, exceptions) of circuit `c` against `f` over `inputs`."
function _stwr_sweep(c, f, inputs)
    nbad = 0; nexc = 0
    for inp in inputs
        try
            simulate(c, inp) == f(inp...) || (nbad += 1)
        catch e
            e isa InterruptException && rethrow()
            nexc += 1
        end
    end
    return nbad, nexc
end

const _STWR_I8  = typemin(Int8):typemax(Int8)
const _STWR_I8x2 = vec([(x, y) for x in _STWR_I8, y in _STWR_I8])
const _STWR_BI8x2 = vec([(c, x, y) for c in (false, true), x in _STWR_I8, y in _STWR_I8])

"""
Lower `parsed` with `add=:cuccaro, fold_constants=false`; assert Cuccaro
actually fired (fewer wires than the `:ripple` lowering — non-vacuity), then
wrap with every Bennett strategy and sweep `inputs` exhaustively. Finally the
end-to-end `reversible_compile(...; add=:cuccaro)` (default fold) when `f`
and `types` are given.
"""
function _stwr_check_all(name, ref, inputs; parsed, K::Int=0, compile=nothing)
    @testset "$name" begin
        lr  = Bennett.lower(parsed; add=:cuccaro, fold_constants=false, max_loop_iterations=K)
        lrr = Bennett.lower(parsed; add=:ripple,  fold_constants=false, max_loop_iterations=K)
        @test lr.n_wires < lrr.n_wires            # Cuccaro fired (non-vacuity)
        for S in _STWR_STRATEGIES
            @testset "$(name) / $(nameof(typeof(S)))" begin
                c = Bennett.bennett(lr; strategy=S)
                nbad, nexc = _stwr_sweep(c, ref, inputs)
                @test nbad == 0
                @test nexc == 0
                @test verify_reversibility(c)
            end
        end
        if compile !== nothing
            @testset "$(name) / reversible_compile" begin
                c = compile()
                nbad, nexc = _stwr_sweep(c, ref, inputs)
                @test nbad == 0
                @test nexc == 0
                @test verify_reversibility(c)
            end
        end
    end
end

# ---- the case functions (all `optimize=false` — rule 5) --------------------

_stwr_xyy(x::Int8, y::Int8) = (x + y) + y
_stwr_xx(x::Int8) = x + x
_stwr_xxx(x::Int8) = x + x + x
_stwr_xxy(x::Int8, y::Int8) = (x + x) + y
_stwr_retmerge(c::Bool, x::Int8, y::Int8) = c ? y : x + y
_stwr_diamond(c::Bool, x::Int8, y::Int8) = (c ? x + y : x - y) + y
_stwr_commute(c::Bool, x::Int8, y::Int8) = c ? x + y : y + x
_stwr_d2(x::Int8, y::Int8) = (x > Int8(0) ? x + y : y) + y
_stwr_d3(x::Int8, y::Int8) = x > Int8(0) ? (y ⊻ Int8(3)) : (x + y)
_stwr_h(x::Int8, y::Int8) = (y & x) ⊻ (x + y)
_stwr_xy(x::Int8, y::Int8) = x + y
_stwr_xyxy(x::Int8, y::Int8) = x * y + x + y

function _stwr_lp(x::Int8, y::Int8)       # proposal B `lp`: post-loop code
    s = x; i = Int8(0); m = y & Int8(3)
    while i < m
        s += Int8(1); i += Int8(1)
    end
    t = s + y
    return t + y
end

function _stwr_loopf(x::Int8, n::Int8)    # proposal A `loopf`
    m = n & Int8(3)
    y = x + m
    s = Int8(0); i = Int8(0)
    while i < m
        s += y; i += Int8(1)
    end
    return s
end

function _stwr_preloop(x::Int8, y::Int8)  # pre-loop value used once, inside the loop
    t = x ⊻ y
    a = x; i = Int8(0)
    while i < (y & Int8(3))
        a = a + t; i += Int8(1)
    end
    return a
end

_stwr_p(f, T) = extract_parsed_ir(f, T; optimize=false)

# ============================================================================

@testset "Bennett-stwr: add=:cuccaro soundness" begin

@testset "straight-line operand reuse" begin
    p = _stwr_p(_stwr_xyy, Tuple{Int8,Int8})
    y = _stwr_arg(p, 2)
    @test length(_stwr_adds(p)) == 2
    @test any(a -> _stwr_is(a.op2, y), _stwr_adds(p)) && _stwr_occ(p, y) == 2
    _stwr_check_all("(x+y)+y", _stwr_xyy, _STWR_I8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_xyy, Int8, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_xx, Tuple{Int8})
    @test any(a -> a.op1 == a.op2 && a.op1 isa SSAOperand, _stwr_adds(p))   # add %x, %x
    _stwr_check_all("x+x", _stwr_xx, _STWR_I8; parsed=p,
        compile=() -> reversible_compile(_stwr_xx, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_xxx, Tuple{Int8})
    @test length(_stwr_adds(p)) == 2
    @test any(a -> a.op1 == a.op2 && a.op1 isa SSAOperand, _stwr_adds(p))
    _stwr_check_all("x+x+x", _stwr_xxx, _STWR_I8; parsed=p,
        compile=() -> reversible_compile(_stwr_xxx, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_xxy, Tuple{Int8,Int8})
    @test any(a -> a.op1 == a.op2 && a.op1 isa SSAOperand, _stwr_adds(p))
    _stwr_check_all("(x+x)+y", _stwr_xxy, _STWR_I8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_xxy, Int8, Int8; add=:cuccaro, optimize=false))
end

@testset "h: y read BEFORE the add (ValueEager non-LIFO uncompute)" begin
    p = _stwr_p(_stwr_h, Tuple{Int8,Int8})
    y = _stwr_arg(p, 2)
    insts = _stwr_insts(p)
    iadd = findfirst(i -> i isa IRBinOp && i.op === :add, insts)
    iand = findfirst(i -> i isa IRBinOp && i.op === :and, insts)
    @test iadd !== nothing && iand !== nothing && iand < iadd
    @test y in Bennett._ssa_operands(insts[iand]) && y in Bennett._ssa_operands(insts[iadd])
    @test length(p.blocks) == 1                  # straight-line ⇒ ValueEager does NOT fall back
    _stwr_check_all("h", _stwr_h, _STWR_I8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_h, Int8, Int8; add=:cuccaro, optimize=false))
end

@testset "CFG: deferred / sibling readers" begin
    p = _stwr_p(_stwr_retmerge, Tuple{Bool,Int8,Int8})
    y = _stwr_arg(p, 3)
    @test count(b -> b.terminator isa IRRet, p.blocks) >= 2
    @test any(b -> b.terminator isa IRRet && _stwr_is(b.terminator.op, y), p.blocks)
    _stwr_check_all("c ? y : x+y", _stwr_retmerge, _STWR_BI8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_retmerge, Bool, Int8, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_diamond, Tuple{Bool,Int8,Int8})
    y = _stwr_arg(p, 3)
    phis = [i for i in _stwr_insts(p) if i isa IRPhi]
    @test length(phis) == 1
    @test any(a -> _stwr_is(a.op1, phis[1].dest) && _stwr_is(a.op2, y), _stwr_adds(p))
    _stwr_check_all("(c ? x+y : x-y)+y", _stwr_diamond, _STWR_BI8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_diamond, Bool, Int8, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_commute, Tuple{Bool,Int8,Int8})
    @test length(_stwr_adds(p)) == 2
    @test length(unique(_stwr_block_of(p, i -> i === a) for a in _stwr_adds(p))) == 2
    _stwr_check_all("c ? x+y : y+x", _stwr_commute, _STWR_BI8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_commute, Bool, Int8, Int8; add=:cuccaro, optimize=false))

    p = _stwr_p(_stwr_d2, Tuple{Int8,Int8})
    y = _stwr_arg(p, 2)
    phis = [i for i in _stwr_insts(p) if i isa IRPhi]
    @test length(phis) == 1 && any(inc -> _stwr_is(inc[1], y), phis[1].incoming)
    _stwr_check_all("d2", _stwr_d2, _STWR_I8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_d2, Int8, Int8; add=:cuccaro, optimize=false))

    # d3: the add's block is emitted BEFORE its sibling that reads y (topo
    # order [top, L_add, L_xor]) — pin it, else the case would go vacuous.
    p = _stwr_p(_stwr_d3, Tuple{Int8,Int8})
    y = _stwr_arg(p, 2)
    ladd = _stwr_block_of(p, i -> i isa IRBinOp && i.op === :add)
    lxor = _stwr_block_of(p, i -> i isa IRBinOp && i.op === :xor && _stwr_is(i.op1, y))
    order = _stwr_topo(p)
    @test ladd != lxor
    @test findfirst(==(ladd), order) < findfirst(==(lxor), order)
    _stwr_check_all("d3", _stwr_d3, _STWR_I8x2; parsed=p,
        compile=() -> reversible_compile(_stwr_d3, Int8, Int8; add=:cuccaro, optimize=false))
end

@testset "loops" begin
    p = _stwr_p(_stwr_lp, Tuple{Int8,Int8})
    y = _stwr_arg(p, 2)
    @test !isempty(Bennett.find_back_edges(p.blocks))
    @test count(a -> _stwr_is(a.op2, y) || _stwr_is(a.op1, y), _stwr_adds(p)) == 2
    _stwr_check_all("lp (post-loop adds)", _stwr_lp, _STWR_I8x2; parsed=p, K=4,
        compile=() -> reversible_compile(_stwr_lp, Int8, Int8; add=:cuccaro, optimize=false,
                                         max_loop_iterations=4))

    p = _stwr_p(_stwr_loopf, Tuple{Int8,Int8})
    @test !isempty(Bennett.find_back_edges(p.blocks))
    _stwr_check_all("loopf (pre-loop add, operand read by loop header)", _stwr_loopf,
        _STWR_I8x2; parsed=p, K=4,
        compile=() -> reversible_compile(_stwr_loopf, Int8, Int8; add=:cuccaro, optimize=false,
                                         max_loop_iterations=4))

    # t = x ⊻ y has exactly ONE static occurrence — an add INSIDE the loop body
    # (dynamically read K times). Loop contexts must never write it in place.
    p = _stwr_p(_stwr_preloop, Tuple{Int8,Int8})
    tx = only(i for i in _stwr_insts(p) if i isa IRBinOp && i.op === :xor && i.width == 8)
    @test _stwr_occ(p, tx.dest) == 1
    ltx = _stwr_block_of(p, i -> i === tx)
    luse = _stwr_block_of(p, i -> i isa IRBinOp && i.op === :add &&
                                  (_stwr_is(i.op1, tx.dest) || _stwr_is(i.op2, tx.dest)))
    @test ltx != luse
    lr = Bennett.lower(p; add=:cuccaro, fold_constants=false, max_loop_iterations=4)
    for S in _STWR_STRATEGIES
        c = Bennett.bennett(lr; strategy=S)
        nbad, nexc = _stwr_sweep(c, _stwr_preloop, _STWR_I8x2)
        @test nbad == 0
        @test nexc == 0
    end
end

@testset "hand-built phi-alias ParsedIR (single-incoming phi aliases y)" begin
    # entry: br L1 ; L1: %p = phi [%y, entry]; %t = add %x, %p; %u = add %t, %y; ret %u
    mk(tail) = ParsedIR(8, [(:x, 8), (:y, 8)],
        [IRBasicBlock(:entry, IRInst[], IRBranch(nothing, :L1, nothing)),
         IRBasicBlock(:L1, IRInst[IRPhi(:p, 8, [(ssa(:y), :entry)]),
                                  IRBinOp(:t, :add, ssa(:x), ssa(:p), 8), tail...],
                      IRRet(ssa(:u), 8))], [8])
    pB = mk([IRBinOp(:u, :add, ssa(:t), ssa(:y), 8)])          # proposal B: x + 2y
    _stwr_check_all("phi-alias B (x+p)+y", (x, y) -> x + y + y, _STWR_I8x2; parsed=pB)
    pA = mk([IRBinOp(:u, :xor, ssa(:t), ssa(:y), 8)])          # proposal A: (x+p) ⊻ y
    lr = Bennett.lower(pA; add=:cuccaro, fold_constants=false)
    for S in _STWR_STRATEGIES
        c = Bennett.bennett(lr; strategy=S)
        nbad, nexc = _stwr_sweep(c, (x, y) -> (x + y) ⊻ y, _STWR_I8x2)
        @test nbad == 0
        @test nexc == 0
    end
end

@testset "hand-written .ll: VarGEP index re-read by a later load" begin
    ll = """
    define i8 @julia_stwr_vargep(i8 %x, i8 %j) {
    top:
      %a = alloca [4 x i8], align 1
      %p1 = getelementptr inbounds i8, ptr %a, i64 1
      %p2 = getelementptr inbounds i8, ptr %a, i64 2
      %p3 = getelementptr inbounds i8, ptr %a, i64 3
      store i8 11, ptr %a, align 1
      store i8 22, ptr %p1, align 1
      store i8 44, ptr %p2, align 1
      store i8 88, ptr %p3, align 1
      %jm = and i8 %j, 3
      %g = getelementptr inbounds i8, ptr %a, i8 %jm
      %s = add i8 %x, %jm
      %v = load i8, ptr %g, align 1
      %r = xor i8 %s, %v
      ret i8 %r
    }
    """
    p = Bennett._parsed_ir_from_ir_string(ll)
    insts = _stwr_insts(p)
    gep = only(i for i in insts if i isa Bennett.IRVarGEP)
    add = only(_stwr_adds(p))
    @test _stwr_is(gep.index, :jm) && _stwr_is(add.op2, :jm)
    @test findfirst(i -> i isa Bennett.IRLoad, insts) > findfirst(i -> i === add, insts)
    _ref(x, j) = (jm = j & Int8(3); (x + jm) ⊻ Int8[11, 22, 44, 88][jm + 1])
    lr = Bennett.lower(p; add=:cuccaro, fold_constants=false)
    c = Bennett.bennett(lr)
    nbad, nexc = _stwr_sweep(c, _ref, _STWR_I8x2)
    @test nbad == 0
    @test nexc == 0
    @test verify_reversibility(c)
end

@testset "soft_fadd bit-exact under add=:cuccaro" begin
    c = reversible_compile(soft_fadd, UInt64, UInt64; add=:cuccaro)
    @test verify_reversibility(c)
    rng = Random.MersenneTwister(0x57a7)
    vals = Float64[0.0, -0.0, Inf, -Inf, NaN, 1.0, -1.0, 2.0, 0.5, 3.14, -2.72,
                   5.0e-324, -5.0e-324, 2.2250738585072014e-308, 1.0e-310, -1.0e-310,
                   floatmax(Float64), -floatmax(Float64), 1.0e308, 1.7976931348623157e308,
                   1.0e10, 1.0e-10]
    pairs = vec(Tuple{Float64,Float64}[(a, b) for a in vals, b in vals])
    for _ in 1:50
        push!(pairs, (randn(rng) * 10.0^rand(rng, -20:20), randn(rng) * 10.0^rand(rng, -20:20)))
        push!(pairs, (reinterpret(Float64, rand(rng, UInt64)), reinterpret(Float64, rand(rng, UInt64))))
    end
    nbad = 0; nnative = 0
    for (a, b) in pairs
        ab, bb = reinterpret(UInt64, a), reinterpret(UInt64, b)
        got = reinterpret(UInt64, simulate(c, (ab, bb)))
        got == soft_fadd(ab, bb) || (nbad += 1)
        want = a + b
        (isnan(want) ? isnan(reinterpret(Float64, got)) : got == reinterpret(UInt64, want)) ||
            (nnative += 1)
    end
    @test nbad == 0
    @test nnative == 0
end

@testset "lower_add_cuccaro! rejects aliased / malformed registers" begin
    wa = Bennett.WireAllocator()
    a = Bennett.allocate!(wa, 8); b = Bennett.allocate!(wa, 8)
    g = ReversibleGate[]
    @test_throws ArgumentError Bennett.lower_add_cuccaro!(g, wa, a, a, 8)
    @test_throws ArgumentError Bennett.lower_add_cuccaro!(g, wa, a, [b[1:7]; a[3]], 8)
    @test_throws ArgumentError Bennett.lower_add_cuccaro!(g, wa, a, [b[1:7]; b[1]], 8)
    @test_throws DimensionMismatch Bennett.lower_add_cuccaro!(g, wa, a, b[1:7], 8)
    @test isempty(g)                             # nothing emitted before the check
    # W = 1 still falls back to the (non-destructive) ripple adder.
    r = Bennett.lower_add_cuccaro!(g, wa, a[1:1], b[1:1], 1)
    @test isdisjoint(r, b[1:1])
end

@testset "eligibility: compute_ssa_use_counts / compute_inplace_targets" begin
    p = _stwr_p(_stwr_xx, Tuple{Int8})
    x = _stwr_arg(p, 1)
    @test Bennett.compute_ssa_use_counts(p)[x] == 2          # occurrences, not users
    @test !(x in Bennett.compute_inplace_targets(p))

    p = _stwr_p(_stwr_xy, Tuple{Int8,Int8})
    t = Bennett.compute_inplace_targets(p)
    @test _stwr_arg(p, 1) in t && _stwr_arg(p, 2) in t

    p = _stwr_p(_stwr_xyy, Tuple{Int8,Int8})
    t = Bennett.compute_inplace_targets(p)
    first_add = _stwr_adds(p)[1]
    @test !(_stwr_arg(p, 2) in t)                 # y read twice
    @test _stwr_arg(p, 1) in t                     # x read once
    @test first_add.dest in t                      # (x+y) read once, fresh BinOp def
    @test Bennett.compute_ssa_use_counts(p)[_stwr_adds(p)[2].dest] == 1   # ret operand counted

    # Terminator operands count as occurrences.
    p = _stwr_p(_stwr_retmerge, Tuple{Bool,Int8,Int8})
    @test Bennett.compute_ssa_use_counts(p)[_stwr_arg(p, 3)] == 2
    @test !(_stwr_arg(p, 3) in Bennett.compute_inplace_targets(p))

    # IRPhi dests are never targets, even when read exactly once.
    p = _stwr_p(_stwr_diamond, Tuple{Bool,Int8,Int8})
    phi = only(i for i in _stwr_insts(p) if i isa IRPhi)
    @test Bennett.compute_ssa_use_counts(p)[phi.dest] == 1
    @test !(phi.dest in Bennett.compute_inplace_targets(p))

    # Pointer-producing defs are never targets.
    ll = """
    define i8 @julia_stwr_ptrs(i8 %x, i8 %j) {
    top:
      %a = alloca [4 x i8], align 1
      %p1 = getelementptr inbounds i8, ptr %a, i64 1
      store i8 11, ptr %a, align 1
      store i8 22, ptr %p1, align 1
      %jm = and i8 %j, 1
      %g = getelementptr inbounds i8, ptr %a, i8 %jm
      %v = load i8, ptr %g, align 1
      %s = add i8 %x, %v
      ret i8 %s
    }
    """
    p = Bennett._parsed_ir_from_ir_string(ll)
    t = Bennett.compute_inplace_targets(p)
    for i in _stwr_insts(p)
        if i isa Union{Bennett.IRAlloca, Bennett.IRPtrOffset, Bennett.IRVarGEP}
            @test !(i.dest in t)
        end
    end
    @test :v in t                                  # IRLoad dest read once
end

@testset "lowering-time wire-exclusivity scan (defence in depth)" begin
    # Gate-level oracle: run the emitted gates on (x, y) and read registers.
    # (Cuccaro's MAJ ripple writes carries into `a` transiently and restores
    # it, so "no gate targets a" is the wrong check — check values.)
    function run(g, wa, xw, yw, x, y)
        bits = zeros(Bool, Bennett.wire_count(wa))
        for i in 1:8
            bits[xw[i]] = (x >> (i - 1)) & 1 == 1
            bits[yw[i]] = (y >> (i - 1)) & 1 == 1
        end
        for gt in g; Bennett.apply!(bits, gt); end
        return bits
    end
    val(bits, ws) = sum(Int(bits[w]) << (i - 1) for (i, w) in enumerate(ws))
    samples = [(x, y) for x in (0, 1, 77, 128, 255), y in (0, 3, 200, 255)]

    # A forged target set naming a phi-alias (:p shares y's wires) must still
    # copy-in: the scan sees vw[:y] overlapping, and y survives.
    wa = Bennett.WireAllocator()
    xw = Bennett.allocate!(wa, 8); yw = Bennett.allocate!(wa, 8)
    vw = Dict{Symbol,Vector{Int}}(:x => xw, :y => yw, :p => yw)
    g = ReversibleGate[]
    Bennett.lower_binop!(g, wa, vw, IRBinOp(:t, :add, ssa(:x), ssa(:p), 8);
                         add=:cuccaro, inplace_targets=Set([:p]))
    @test isdisjoint(vw[:t], yw) && isdisjoint(vw[:t], xw)
    @test haskey(vw, :p) && haskey(vw, :y)
    for (x, y) in samples
        bits = run(g, wa, xw, yw, x, y)
        @test val(bits, yw) == y && val(bits, xw) == x
        @test val(bits, vw[:t]) == (x + y) % 256
    end

    # Genuinely exclusive op2: written in place and its vw entry consumed.
    wa = Bennett.WireAllocator()
    xw = Bennett.allocate!(wa, 8); yw = Bennett.allocate!(wa, 8)
    vw = Dict{Symbol,Vector{Int}}(:x => xw, :y => yw)
    g = ReversibleGate[]
    Bennett.lower_binop!(g, wa, vw, IRBinOp(:t, :add, ssa(:x), ssa(:y), 8);
                         add=:cuccaro, inplace_targets=Set([:x, :y]))
    @test vw[:t] == yw
    @test !haskey(vw, :y) && haskey(vw, :x)
    @test_throws AssertionError Bennett.resolve!(g, wa, vw, ssa(:y), 8)   # consumed ⇒ loud
    @test Bennett.wire_count(wa) == 16 + 1
    for (x, y) in samples
        bits = run(g, wa, xw, yw, x, y)
        @test val(bits, xw) == x && val(bits, yw) == (x + y) % 256
    end

    # op2 not a target, op1 is: commutative swap writes into op1's wires.
    wa = Bennett.WireAllocator()
    xw = Bennett.allocate!(wa, 8); yw = Bennett.allocate!(wa, 8)
    vw = Dict{Symbol,Vector{Int}}(:x => xw, :y => yw)
    g = ReversibleGate[]
    Bennett.lower_binop!(g, wa, vw, IRBinOp(:t, :add, ssa(:x), ssa(:y), 8);
                         add=:cuccaro, inplace_targets=Set([:x]))
    @test vw[:t] == xw
    @test !haskey(vw, :x) && haskey(vw, :y)
    @test Bennett.wire_count(wa) == 16 + 1
    for (x, y) in samples
        bits = run(g, wa, xw, yw, x, y)
        @test val(bits, yw) == y && val(bits, xw) == (x + y) % 256
    end

    # x + x under a forged set: a ∩ b ≠ ∅ ⇒ copy-in, never an aliased Cuccaro.
    wa = Bennett.WireAllocator()
    xw = Bennett.allocate!(wa, 8); yw = Bennett.allocate!(wa, 8)
    vw = Dict{Symbol,Vector{Int}}(:x => xw, :y => yw)
    g = ReversibleGate[]
    Bennett.lower_binop!(g, wa, vw, IRBinOp(:t, :add, ssa(:x), ssa(:x), 8);
                         add=:cuccaro, inplace_targets=Set([:x]))
    @test haskey(vw, :x) && isdisjoint(vw[:t], xw)
    for (x, y) in samples
        bits = run(g, wa, xw, yw, x, y)
        @test val(bits, xw) == x && val(bits, vw[:t]) == (2x) % 256
    end

    # Neither: copy-in — +W wires, +W CNOTs, same Toffolis, both operands intact.
    wa = Bennett.WireAllocator()
    xw = Bennett.allocate!(wa, 8); yw = Bennett.allocate!(wa, 8)
    vw = Dict{Symbol,Vector{Int}}(:x => xw, :y => yw)
    g = ReversibleGate[]
    Bennett.lower_binop!(g, wa, vw, IRBinOp(:t, :add, ssa(:x), ssa(:y), 8);
                         add=:cuccaro, inplace_targets=Set{Symbol}())
    @test isdisjoint(vw[:t], xw) && isdisjoint(vw[:t], yw)
    @test haskey(vw, :x) && haskey(vw, :y)
    @test count(gt -> gt isa ToffoliGate, g) == 2 * 8 - 3
    @test length(g) == (6 * 8 - 5) + 8
    @test Bennett.wire_count(wa) == 16 + 8 + 1
    for (x, y) in samples
        bits = run(g, wa, xw, yw, x, y)
        @test val(bits, xw) == x && val(bits, yw) == y
        @test val(bits, vw[:t]) == (x + y) % 256
    end
end

@testset "GREEN guards: in-place still fires where sound" begin
    for (T, tot, tof, nw) in [(Int8, 96, 26, 26), (Int16, 200, 58, 50),
                              (Int32, 408, 122, 98), (Int64, 824, 250, 194)]
        c = reversible_compile((x, y) -> x + y, T, T; add=:cuccaro)
        gc = gate_count(c)
        @test gc.total == tot
        @test gc.Toffoli == tof
        @test c.n_wires == nw
        @test verify_reversibility(c)
    end
    c = reversible_compile(x -> x + Int8(1), Int8; add=:cuccaro)
    @test gate_count(c).total == 98
    @test gate_count(c).Toffoli == 26
    for x in _STWR_I8
        @test simulate(c, x) == x + Int8(1)
    end
    # x*y + x + y: the commutative swap keeps it copy-free (pinned 554).
    c = reversible_compile(_stwr_xyxy, Int8, Int8; add=:cuccaro)
    @test gate_count(c).total == 554
    # x + y in-place into an input register — every strategy.
    _stwr_check_all("x+y", _stwr_xy, _STWR_I8x2; parsed=_stwr_p(_stwr_xy, Tuple{Int8,Int8}))
    _stwr_check_all("x*y+x+y", _stwr_xyxy, _STWR_I8x2; parsed=_stwr_p(_stwr_xyxy, Tuple{Int8,Int8}))
end

@testset "policy pins: copy-in / swap counts for the formerly-unsound shapes" begin
    # Forward (lower, fold_constants=false) gates / wires under add=:cuccaro.
    # Pre-stwr counts were computed on clobbered operands (wrong circuits), so
    # they are not baselines. Every add is still MAJ/UMA; a copy-in costs
    # exactly +W CNOT and +W wires over the in-place form.
    for (nm, f, T, fwd, nw) in [("(x+y)+y", _stwr_xyy, Tuple{Int8,Int8}, 87, 19),   # 2 swaps, 0 copies
                                ("x+x",     _stwr_xx,  Tuple{Int8},      52, 18),   # 1 copy
                                ("x+x+x",   _stwr_xxx, Tuple{Int8},      95, 19),   # 1 copy + 1 in place
                                ("(x+x)+y", _stwr_xxy, Tuple{Int8,Int8}, 95, 27),
                                ("d2",      _stwr_d2,  Tuple{Int8,Int8}, 213, 106),
                                ("d3",      _stwr_d3,  Tuple{Int8,Int8}, 177, 112),
                                ("h",       _stwr_h,   Tuple{Int8,Int8}, 76, 42),
                                ("x+y",     _stwr_xy,  Tuple{Int8,Int8}, 44, 18)]
        lr = Bennett.lower(_stwr_p(f, T); add=:cuccaro, fold_constants=false)
        @test (nm, length(lr.gates), lr.n_wires) == (nm, fwd, nw)
    end
    c = reversible_compile(soft_fadd, UInt64, UInt64; add=:cuccaro)
    @test gate_count(c).total == 65758
    @test gate_count(c).Toffoli == 14330
end

@testset "use_inplace=false ⇒ copy-in for every SSA operand" begin
    p = extract_parsed_ir((x, y) -> x + y, Tuple{Int8,Int8})
    lr = Bennett.lower(p; add=:cuccaro, use_inplace=false)
    c = Bennett.bennett(lr)
    @test gate_count(c).total == 112
    @test gate_count(c).Toffoli == 26
    @test c.n_wires == 34
    nbad, nexc = _stwr_sweep(c, _stwr_xy, _STWR_I8x2)
    @test nbad == 0 && nexc == 0
    # constants are still consumed in place
    p = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
    @test gate_count(Bennett.bennett(Bennett.lower(p; add=:cuccaro, use_inplace=false))).total == 98
end

@testset ":auto stays byte-identical to :ripple (use_inplace irrelevant)" begin
    for (f, T) in [(_stwr_xy, Tuple{Int8,Int8}), (_stwr_xyy, Tuple{Int8,Int8}),
                   (_stwr_d2, Tuple{Int8,Int8}), (_stwr_xyxy, Tuple{Int8,Int8}),
                   (x -> x * x + Int8(3) * x + Int8(1), Tuple{Int8})]
        for opt in (true, false)
            p = extract_parsed_ir(f, T; optimize=opt)
            g_rip = Bennett.lower(p; add=:ripple).gates
            @test Bennett.lower(p; add=:auto).gates == g_rip
            @test Bennett.lower(p; add=:auto, use_inplace=false).gates == g_rip
            @test Bennett.lower(p; add=:ripple, use_inplace=false).gates == g_rip
        end
    end
end

end  # Bennett-stwr
