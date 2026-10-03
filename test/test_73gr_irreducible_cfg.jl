# test_73gr_irreducible_cfg.jl — Bennett-73gr (Astra B-lowering F18).
#
# THE BUG. `find_back_edges` (src/lowering/cfg.jl) classified an edge as a back
# edge by DFS colouring alone. In an irreducible region — a cycle with two
# entries, e.g. entry → H or L; L → H; H → exit or L — DFS marks L→H a back edge
# although H does not dominate L. The driver then lowers H as a natural-loop
# header, removes L from the ordinary walk, and predicates L only as an
# H-successor: the real entry→L edge vanishes. Witness: 128/256 Int8 inputs
# returned 11 instead of 42 at K=1 and K=3, and `verify_reversibility` passed.
#
# THE INVARIANT. A CFG with loops is lowered only if every DFS back edge t→h
# is a natural-loop back edge (h dominates t) and every block of each loop's
# body has all its (reachable) predecessors inside the loop, the header being
# the sole entry. Otherwise lowering fails loud, naming the blocks. (A CFG is
# reducible iff every DFS retreating edge is a dominance back edge, so this
# rejects exactly the irreducible CFGs, for every DFS order — exercised here by
# permuting block order and branch polarity.) Reducible loops lower exactly as
# before.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll

function _r73_ll(ir::AbstractString, fname::AbstractString)
    mktempdir() do dir
        path = joinpath(dir, "$fname.ll")
        write(path, ir)
        extract_parsed_ir_from_ll(path; entry_function=fname)
    end
end

# Assemble a function from (label, body) blocks; the first block is the entry.
_r73_fn(name, blocks) = "define i8 @$name(i8 %x) {\n" *
    join(["$l:\n$b" for (l, b) in blocks], "") * "}\n"

# Every ordering of the non-entry blocks (the entry must stay first).
function _r73_perms(v)
    length(v) <= 1 && return [v]
    out = Vector{eltype(v)}[]
    for i in eachindex(v)
        rest = [v[j] for j in eachindex(v) if j != i]
        for p in _r73_perms(rest)
            push!(out, vcat([v[i]], p))
        end
    end
    out
end
_r73_orders(blocks) = [vcat([blocks[1]], p) for p in _r73_perms(blocks[2:end])]

# ---------------------------------------------------------------- irreducible --

# I1: the bead's witness verbatim (Astra B-lowering F18), with the entry
# branch polarity as a parameter so both DFS visiting orders are exercised.
_r73_I1(swap) = [
    ("entry", """
     %a = alloca i8
     store i8 11, ptr %a
     %m = and i8 %x, 1
     %c = icmp ne i8 %m, 0
     br i1 %c, label $(swap ? "%L, label %H" : "%H, label %L")
    """),
    ("H", "  br i1 true, label %exit, label %L\n"),
    ("L", "  store i8 42, ptr %a\n  br label %H\n"),
    ("exit", "  %r = load i8, ptr %a\n  ret i8 %r\n"),
]

# I2: a genuinely cyclic two-entry region with a nonconstant H exit and
# value-carrying phis at both entries.
_r73_I2(swap) = [
    ("entry", """
     %c = icmp slt i8 %x, 0
     br i1 %c, label $(swap ? "%L, label %H" : "%H, label %L")
    """),
    ("H", """
     %h = phi i8 [ %x, %entry ], [ %l2, %L ]
     %d = icmp ugt i8 %h, 100
     br i1 %d, label %exit, label %L
    """),
    ("L", """
     %l = phi i8 [ 7, %entry ], [ %h, %H ]
     %l2 = add i8 %l, 50
     br label %H
    """),
    ("exit", "  ret i8 %h\n"),
]

# I3: side entry into a multi-block body (entry → H or B; H → A or exit;
# A → B; B → H). B is a body block with a predecessor outside the loop.
_r73_I3(swap) = [
    ("entry", """
     %c = icmp eq i8 %x, 3
     br i1 %c, label $(swap ? "%B, label %H" : "%H, label %B")
    """),
    ("H", """
     %h = phi i8 [ %x, %entry ], [ %b2, %B ]
     %d = icmp sgt i8 %h, 64
     br i1 %d, label %exit, label %A
    """),
    ("A", "  %a = add i8 %h, 1\n  br label %B\n"),
    ("B", """
     %b = phi i8 [ 9, %entry ], [ %a, %A ]
     %b2 = add i8 %b, 30
     br label %H
    """),
    ("exit", "  ret i8 %h\n"),
]

@testset "Bennett-73gr: irreducible CFGs are refused loud" begin
    # The bead's witness, verbatim, at the review's K=1 and K=3, folding on/off.
    p = _r73_ll(_r73_fn("probe", _r73_I1(false)), "probe")
    for K in (1, 3), fold in (false, true)
        @test_throws r"irreducible" reversible_compile(p; max_loop_iterations=K,
                                                        fold_constants=fold)
    end
    # The message names the offending blocks.
    err = try
        reversible_compile(p; max_loop_iterations=1); nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("side entry", err.msg)
    @test occursin("H", err.msg) && occursin("L", err.msg)

    # Generated: every fixture × entry-branch polarity × every block order.
    n = 0
    for (tag, mk) in (("i1", _r73_I1), ("i2", _r73_I2), ("i3", _r73_I3)),
            swap in (false, true), blocks in _r73_orders(mk(swap))
        name = "$(tag)_$(swap)_$(n += 1)"
        pir = _r73_ll(_r73_fn(name, blocks), name)
        @test_throws r"irreducible" reversible_compile(pir; max_loop_iterations=4)
    end
    @test n == 2 * (6 + 6 + 24)
end

# ------------------------------------------------------------------ reducible --

const _R73_I8 = typemin(Int8):typemax(Int8)

# R1: single latch, data-dependent trip count (exits before K for most x).
const _R73_R1 = [
    ("top", "  %n = and i8 %x, 3\n  br label %H\n"),
    ("H", """
     %acc = phi i8 [ %x, %top ], [ %acc2, %L ]
     %i = phi i8 [ 0, %top ], [ %i2, %L ]
     %done = icmp uge i8 %i, %n
     br i1 %done, label %E, label %L
    """),
    ("L", "  %acc2 = add i8 %acc, 5\n  %i2 = add i8 %i, 1\n  br label %H\n"),
    ("E", "  ret i8 %acc\n"),
]
_r73_r1(x::Int8) = x + Int8(5) * (x & Int8(3))

# R2: two latches to one header (a diamond in the body, both arms latching).
const _R73_R2 = [
    ("top", "  %n = and i8 %x, 3\n  br label %H\n"),
    ("H", """
     %acc = phi i8 [ %x, %top ], [ %acc2, %L1 ], [ %acc2, %L2 ]
     %i = phi i8 [ 0, %top ], [ %i2, %L1 ], [ %i2, %L2 ]
     %done = icmp uge i8 %i, %n
     br i1 %done, label %E, label %B
    """),
    ("B", """
     %acc2 = add i8 %acc, 7
     %i2 = add i8 %i, 1
     %q = icmp slt i8 %acc2, 0
     br i1 %q, label %L1, label %L2
    """),
    ("L1", "  br label %H\n"),
    ("L2", "  br label %H\n"),
    ("E", "  ret i8 %acc\n"),
]
_r73_r2(x::Int8) = x + Int8(7) * (x & Int8(3))

# R3: the loop sits inside one arm of a branch; the arms merge after it.
const _R73_R3 = [
    ("top", """
     %c = icmp slt i8 %x, 0
     %n = and i8 %x, 3
     br i1 %c, label %P, label %Q
    """),
    ("P", "  br label %H\n"),
    ("H", """
     %acc = phi i8 [ %x, %P ], [ %acc2, %L ]
     %i = phi i8 [ 0, %P ], [ %i2, %L ]
     %done = icmp uge i8 %i, %n
     br i1 %done, label %J, label %L
    """),
    ("L", "  %acc2 = add i8 %acc, 3\n  %i2 = add i8 %i, 1\n  br label %H\n"),
    ("Q", "  %y = xor i8 %x, 85\n  br label %J\n"),
    ("J", "  %r = phi i8 [ %acc, %H ], [ %y, %Q ]\n  ret i8 %r\n"),
]
_r73_r3(x::Int8) = x < 0 ? x + Int8(3) * (x & Int8(3)) : xor(x, Int8(85))

# R4: early exits — an early return before the loop, and a loop whose exit
# test fires early (trip count x & 3 < K).
const _R73_R4 = [
    ("top", "  %z = icmp eq i8 %x, 0\n  br i1 %z, label %Z, label %P\n"),
    ("Z", "  ret i8 -1\n"),
    ("P", "  %n = and i8 %x, 3\n  br label %H\n"),
    ("H", """
     %acc = phi i8 [ %x, %P ], [ %acc2, %L ]
     %i = phi i8 [ 0, %P ], [ %i2, %L ]
     %done = icmp uge i8 %i, %n
     br i1 %done, label %E, label %L
    """),
    ("L", "  %acc2 = mul i8 %acc, 3\n  %i2 = add i8 %i, 1\n  br label %H\n"),
    ("E", "  ret i8 %acc\n"),
]
_r73_r4(x::Int8) = x == 0 ? Int8(-1) : x * Int8(3)^(x & Int8(3))

@testset "Bennett-73gr: reducible loops still lower correctly" begin
    for (tag, blocks, ref) in (("r1", _R73_R1, _r73_r1), ("r2", _R73_R2, _r73_r2),
                               ("r3", _R73_R3, _r73_r3), ("r4", _R73_R4, _r73_r4))
        for K in (3, 5)
            # The natural-loop analysis must not depend on DFS order:
            # source block order and reversed non-entry block order.
            for (j, bl) in enumerate((blocks, vcat(blocks[1:1], reverse(blocks[2:end]))))
                name = "$(tag)_$(K)_$(j)"
                c = reversible_compile(_r73_ll(_r73_fn(name, bl), name);
                                       max_loop_iterations=K)
                @test all(x -> simulate(c, x) == ref(x), _R73_I8)
                @test verify_reversibility(c)
            end
        end
    end

    # A reducible loop with a second exit (`break`) is still refused by the
    # pre-existing c6ex check, not misreported as irreducible.
    brk = [
        ("top", "  br label %H\n"),
        ("H", """
         %i = phi i8 [ 0, %top ], [ %i2, %B ]
         %done = icmp uge i8 %i, 3
         br i1 %done, label %E, label %B
        """),
        ("B", """
         %i2 = add i8 %i, 1
         %q = icmp eq i8 %i2, %x
         br i1 %q, label %E, label %H
        """),
        ("E", "  %r = phi i8 [ %i, %H ], [ %i2, %B ]\n  ret i8 %r\n"),
    ]
    @test_throws r"second loop exit" reversible_compile(
        _r73_ll(_r73_fn("brk", brk), "brk"); max_loop_iterations=4)
end
