# Bennett-g7d6 — `_narrow_ir` rebuilt the narrowed ParsedIR with the 4-argument
# back-compat constructor, so the three fields after `ret_elem_widths` —
# `globals` (compile-time constant tables), `memssa` (MemorySSA annotations)
# and `synth_ptr_provenance` — were silently reset to their defaults.
#
# Reachability today: NONE.  Under the Bennett-mrhg allowlist the narrowed IR
# holds only scalar nodes (binop / icmp / select / cast / phi / ret / br); the
# only readers of `globals` are the load / GEP lowerings (refused), and
# `memssa` / `synth_ptr_provenance` are read only inside extraction.  A
# constant-table function is refused before the constructor is reached
# (pinned below), and a function whose IR carries MemorySSA annotations but no
# memory node narrows correctly with them dropped (oracle-checked below).
#
# The fix makes the hole unable to reopen: every ParsedIR field is listed in
# `_NARROW_PARSEDIR_FIELDS` with a decision (re-typed, or dead metadata), the
# list is checked against `fieldnames(ParsedIR)`, and dead metadata may be
# reset only while the narrowed IR contains no node that could read it —
# otherwise `_narrow_rebuild` throws an ArgumentError naming Bennett-g7d6.

using Test
using Bennett
using Bennett: ParsedIR, IRBasicBlock, IRInst, IRBinOp, IRLoad, IRRet,
                MemSSAInfo, ssa, iconst

# ---- W-bit oracle toolkit (independent of src/) -----------------------------
g7d6_wmask(W::Int) = (1 << W) - 1
g7d6_wwrap(v::Integer, W::Int) = mod(v, 1 << W)
g7d6_wsign(p::Integer, W::Int) = p >= (1 << (W - 1)) ? p - (1 << W) : p
g7d6_in(p::Integer) = reinterpret(Int8, UInt8(p & 0xff))

const G7D6_WS = (2, 3, 4, 6, 8)

function g7d6_rejection(thunk)
    try
        thunk()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    return nothing
end

# ---- candidates -------------------------------------------------------------
const G7D6_TAB = (Int8(3), Int8(-5), Int8(7), Int8(1))
g7d6_tab(x::Int8) = G7D6_TAB[(x & Int8(3)) + 1]
g7d6_sw(x::Int8) = x == Int8(0) ? Int8(3) : x == Int8(1) ? Int8(-5) :
                   x == Int8(2) ? Int8(7) : x == Int8(3) ? Int8(1) : Int8(0)
g7d6_ptr(p::Ptr{Int8}) = unsafe_load(p)
function g7d6_ref(x::Int8)
    r = Ref(x)
    r[] += Int8(3)
    return r[] * Int8(2)
end
g7d6_inc(x::Int8) = x + Int8(1)
g7d6_mix(x::Int8) = x > Int8(0) ? x * Int8(3) : x - Int8(1)

oracle_ref(p, W) = g7d6_wwrap((g7d6_wsign(p, W) + 3) * 2, W)
oracle_inc(p, W) = g7d6_wwrap(g7d6_wsign(p, W) + 1, W)
# eq/ne are pattern compares: `x == Int8(k)` tests the W-bit pattern of k.
function oracle_sw(p, W)
    u = g7d6_wwrap(p, W)
    r = u == g7d6_wwrap(0, W) ? 3 : u == g7d6_wwrap(1, W) ? -5 :
        u == g7d6_wwrap(2, W) ? 7 : u == g7d6_wwrap(3, W) ? 1 : 0
    return g7d6_wwrap(r, W)
end
function oracle_mix(p, W)
    s = g7d6_wsign(p, W)
    return g7d6_wwrap(s > 0 ? 3s : s - 1, W)
end

@testset "Bennett-g7d6: narrowed ParsedIR field handling" begin

    @testset "every ParsedIR field has a narrowing decision" begin
        fields = Bennett._NARROW_PARSEDIR_FIELDS
        @test Tuple(first.(fields)) == fieldnames(ParsedIR)
        @test all(last.(fields) .∈ Ref((:retyped, :dead_metadata)))
        # The three fields the bead names are the dead-metadata ones.
        @test Set(first(f) for f in fields if last(f) === :dead_metadata) ==
              Set((:globals, :memssa, :synth_ptr_provenance))
    end

    @testset "constant-table function: refused before rebuild (opt=$opt)" for opt in (false, true)
        p = extract_parsed_ir(g7d6_tab, Tuple{Int8}; optimize=opt)
        @test !isempty(p.globals)   # precondition: the table IS a global
        # Unnarrowed compile reads the table correctly (the baseline).
        c = reversible_compile(g7d6_tab, Int8; optimize=opt)
        @test verify_reversibility(c)
        @test all(simulate(c, Int8, x) == g7d6_tab(x) for x in typemin(Int8):typemax(Int8))
        for W in G7D6_WS, strategy in (:expression, :auto)
            msg = g7d6_rejection(() -> reversible_compile(g7d6_tab, Int8;
                                     bit_width=W, optimize=opt, strategy))
            @test msg !== nothing
            @test msg !== nothing && occursin("Bennett-mrhg", msg)
            @test msg !== nothing && occursin("refusing to narrow", msg)
        end
    end

    # A small switch: optimize=false keeps an eq-compare chain (narrowable, so
    # it must be W-bit exact); optimize=true has LLVM fold it into a lookup
    # (a bit-packed constant shifted by a widened index), which is refused.
    # Either way: never a wrong answer.
    @testset "switch-table function: exact or refused (opt=$opt)" for opt in (false, true)
        for W in G7D6_WS
            local c
            msg = g7d6_rejection(() -> (c = reversible_compile(g7d6_sw, Int8;
                                     bit_width=W, optimize=opt, strategy=:expression)))
            if msg === nothing
                @test verify_reversibility(c)
                bad = [pp for pp in 0:g7d6_wmask(W)
                       if (simulate(c, Int8, g7d6_in(pp)) & g7d6_wmask(W)) != oracle_sw(pp, W)]
                isempty(bad) || @info "g7d6 sw mismatches" opt W first(bad, 5)
                @test isempty(bad)
            else
                @test occursin("Bennett-mrhg", msg)
            end
        end
    end
    # The optimised IR's lookup table is refused ...
    @test g7d6_rejection(() -> Bennett._narrow_ir(extract_parsed_ir(g7d6_sw,
                             Tuple{Int8}; optimize=true), 4; optimized=true)) !== nothing
    # ... and since Bennett-sl4h optimize=true narrows the unoptimised compare
    # chain instead (was: refused at W = 4): accepted and right
    let c = reversible_compile(g7d6_sw, Int8; bit_width=4, optimize=true,
                               strategy=:expression)
        @test verify_reversibility(c)
        @test all((simulate(c, Int8, g7d6_in(pp)) & g7d6_wmask(4)) == oracle_sw(pp, 4)
                  for pp in 0:g7d6_wmask(4))
    end

    @testset "pointer argument: refused (opt=$opt)" for opt in (false, true)
        p = extract_parsed_ir(g7d6_ptr, Tuple{Ptr{Int8}}; optimize=opt)
        for W in G7D6_WS
            msg = g7d6_rejection(() -> Bennett._narrow_ir(p, W))
            @test msg !== nothing && occursin("Bennett-mrhg", msg)
            @test msg !== nothing && occursin("return width", msg)
        end
    end

    # MemorySSA annotations are non-default on these accepted IRs (the
    # annotations describe the Julia frame's own memory traffic, which the
    # preprocessing passes remove from the IR).  Narrowing must drop them —
    # nothing in the narrowed IR reads them — and the circuit must be the W-bit
    # function for every input.
    @testset "memssa-annotated IR: narrowed exactly ($nm, opt=$opt)" for
            (nm, f, oracle) in (("inc", g7d6_inc, oracle_inc),
                                ("mix", g7d6_mix, oracle_mix),
                                ("ref", g7d6_ref, oracle_ref)),
            opt in (false, true)
        p = extract_parsed_ir(f, Tuple{Int8}; optimize=opt, use_memory_ssa=true)
        @test p.memssa !== nothing   # precondition: a non-default field
        for W in G7D6_WS
            # Bennett-koi8: `mix` compares `x > 0`, a SIGNED ordering, which
            # narrowing refuses in optimised IR (the optimizer can write an
            # unsigned source ordering that way); unoptimised IR narrows it.
            if nm == "mix" && opt && W < 8
                @test_throws ArgumentError Bennett._narrow_ir(p, W; optimized=opt)
                continue
            end
            q = Bennett._narrow_ir(p, W; optimized=opt)
            @test q.memssa === nothing
            @test isempty(q.globals) && isempty(q.synth_ptr_provenance)
            @test q.ret_width == W && q.ret_elem_widths == [W]
            @test all(w == W for (_, w) in q.args)
            c = reversible_compile(q)
            @test verify_reversibility(c)
            bad = [pp for pp in 0:g7d6_wmask(W)
                   if (simulate(c, Int8, g7d6_in(pp)) & g7d6_wmask(W)) != oracle(pp, W)]
            isempty(bad) || @info "g7d6 mismatches" nm opt W first(bad, 5)
            @test isempty(bad)
        end
    end

    # A scalar-only IR carrying unread globals / provenance: the metadata is
    # dead (no node can read it), so narrowing drops it and stays exact.
    @testset "unread globals / provenance on a scalar IR: dropped, exact" begin
        p0 = extract_parsed_ir(g7d6_inc, Tuple{Int8}; optimize=true)
        p = ParsedIR(p0.ret_width, p0.args, p0.blocks, p0.ret_elem_widths,
                     Dict(Symbol("_j_const#1") => (UInt64[3, 5, 7], 8)),
                     MemSSAInfo(),
                     Set([(Symbol("_j_const#1"), 0, 8)]))
        for W in G7D6_WS
            q = Bennett._narrow_ir(p, W)
            @test isempty(q.globals) && q.memssa === nothing &&
                  isempty(q.synth_ptr_provenance)
            c = reversible_compile(q)
            @test verify_reversibility(c)
            @test all((simulate(c, Int8, g7d6_in(pp)) & g7d6_wmask(W)) == oracle_inc(pp, W)
                      for pp in 0:g7d6_wmask(W))
        end
    end

    # The guard that keeps the hole closed if the allowlist ever admits a node
    # that reads the metadata: rebuilding with such a node and non-default
    # metadata throws, naming this bead.
    @testset "rebuild guard: metadata with a possible reader is refused" begin
        p0 = extract_parsed_ir(g7d6_inc, Tuple{Int8}; optimize=true)
        args = [(n, 4) for (n, _) in p0.args]
        reader = [IRBasicBlock(:top,
                               IRInst[IRLoad(:v, ssa(:g), 4)],
                               IRRet(ssa(:v), 4))]
        G = Dict(Symbol("_j_const#1") => (UInt64[3, 5, 7], 8))
        P = Set([(Symbol("_j_const#1"), 0, 8)])
        withf(; g=Dict{Symbol, Tuple{Vector{UInt64}, Int}}(), m=nothing,
              s=Set{Tuple{Symbol, Int, Int}}()) =
            ParsedIR(p0.ret_width, p0.args, p0.blocks, p0.ret_elem_widths, g, m, s)
        for (field, p) in (("globals", withf(g=G)),
                           ("memssa", withf(m=MemSSAInfo())),
                           ("synth_ptr_provenance", withf(s=P)))
            msg = g7d6_rejection(() -> Bennett._narrow_rebuild(p, 4, args, reader))
            @test msg !== nothing && occursin("Bennett-g7d6", msg)
            @test msg !== nothing && occursin(field, msg)
        end
        # All-default metadata: nothing to lose, the rebuild goes through.
        q = Bennett._narrow_rebuild(withf(), 4, args, reader)
        @test q isa ParsedIR && q.ret_width == 4 && q.ret_elem_widths == [4]
        @test q.blocks === reader && q.args == args
    end
end
