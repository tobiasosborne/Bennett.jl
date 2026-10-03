# Bennett-okcg — `transitive_callees` must never return its own ROOT.
#
# Bug: the walker seeded `visited` EMPTY and pushed the root's direct edges on
# the worklist. A self-recursive root `f -> f` (or a cycle back to the root,
# `f -> g -> f`) therefore re-discovered the root as a "callee", and
# `extract_parsed_ir_set_from_julia` extracted it twice — once as a callee, once
# as the PREPENDED root — tripping its duplicate-canonical-key assert.
#
# Invariant (callgraph.jl `transitive_callees` docstring): the returned order is
# duplicate-free and NEVER contains the root signature, whatever the call-graph
# shape (self-loop, cycle through the root, diamond, plain chain). Set
# extraction's root body therefore comes ONLY from `include_root=true`; with
# `include_root=false` a recursive root's body is not extracted at all.

using Test
using Bennett

# ---- fixtures (uniquely named: runtests.jl shares one module) ----
okcg_fact(n::Int64) = n <= 1 ? Int64(1) : n * okcg_fact(n - 1)

# @noinline on BOTH: without it Julia inlines one into the other and the
# "mutual" pair degenerates to a self-loop (probe-verified, Julia 1.12).
@noinline okcg_even(n::Int64) = n == 0 ? true  : okcg_odd(n - 1)
@noinline okcg_odd(n::Int64)  = n == 0 ? false : okcg_even(n - 1)

@noinline okcg_bot(x::Int64) = x * Int64(3) + Int64(1)
@noinline okcg_l(x::Int64)   = okcg_bot(x) + Int64(1)
@noinline okcg_r(x::Int64)   = okcg_bot(x) - Int64(1)
okcg_top(x::Int64)           = okcg_l(x) ⊻ okcg_r(x)

@noinline okcg_c3(x::Int64) = x + Int64(7)
@noinline okcg_c2(x::Int64) = okcg_c3(x) * Int64(2)
okcg_c1(x::Int64)           = okcg_c2(x) - Int64(5)

const _OKCG_CASES = [
    # (name, root, argtypes, MUST-contain callee keys, recursive?)
    ("self-recursive",          okcg_fact, Tuple{Int64}, Any[],                                   true),
    ("mutual, rooted at even",  okcg_even, Tuple{Int64}, Any[typeof(okcg_odd)],                   true),
    ("mutual, rooted at odd",   okcg_odd,  Tuple{Int64}, Any[typeof(okcg_even)],                  true),
    ("diamond",                 okcg_top,  Tuple{Int64}, Any[typeof(okcg_l), typeof(okcg_r), typeof(okcg_bot)], false),
    ("chain",                   okcg_c1,   Tuple{Int64}, Any[typeof(okcg_c2), typeof(okcg_c3)],    false),
]

@testset "Bennett-okcg: transitive_callees excludes a recursive root" begin
    for (name, f, T, must, _rec) in _OKCG_CASES
        @testset "$name" begin
            got  = Bennett.transitive_callees(f, T)
            root = Base.signature_type(f, T)
            sts  = [Tuple{k, at.parameters...} for (k, at) in got]
            @test allunique(got)                       # no duplicate callee
            @test !(root in sts)                       # root EXCLUDED
            @test !(typeof(f) in first.(got))          # not even under another argtype
            for k in must
                @test count(==(k), first.(got)) == 1   # every real callee exactly once
            end
            # the specTypes helper agrees with the walker on every non-root node
            @test Set(sts) == setdiff(Bennett._transitive_callee_specTypes(f, T), Set([root]))
        end
    end

    # The diamond's shared leaf is reached twice but returned once.
    @test count(==(typeof(okcg_bot)), first.(Bennett.transitive_callees(okcg_top, Tuple{Int64}))) == 1

    # Mutual recursion: the two roots' callee sets are each other's root.
    @test first.(Bennett.transitive_callees(okcg_even, Tuple{Int64})) == Any[typeof(okcg_odd)]
    @test first.(Bennett.transitive_callees(okcg_odd,  Tuple{Int64})) == Any[typeof(okcg_even)]
    @test isempty(Bennett.transitive_callees(okcg_fact, Tuple{Int64}))

    # The internal walk reports recursion iff the root is reachable from itself.
    for (name, f, T, _must, rec) in _OKCG_CASES
        pairs, r = Bennett._transitive_callees_walk(f, T)
        @test r === rec
        @test pairs == Bennett.transitive_callees(f, T)
    end
end

@testset "Bennett-okcg: set extraction of a recursive root — no duplicate key" begin
    for (name, f, T, must, rec) in _OKCG_CASES
        @testset "$name" begin
            set  = Bennett.extract_parsed_ir_set_from_julia(f, T)
            keys = first.(set)
            @test allunique(keys)
            # root body present exactly once, and first (entry-first ordering)
            rootbare = string(nameof(f))
            @test count(k -> rsplit(String(k), "#"; limit=2)[1] == rootbare, keys) == 1
            @test rsplit(String(keys[1]), "#"; limit=2)[1] == rootbare
            @test length(set) == 1 + length(must)

            # include_root=false: the root body is NEVER extracted, even when
            # reachable through recursion. A helper that calls back to the root
            # then escapes the closed world -> the loud closed-world error.
            if !rec || isempty(must)
                s0 = Bennett.extract_parsed_ir_set_from_julia(f, T; include_root=false)
                @test !any(k -> rsplit(String(k), "#"; limit=2)[1] == rootbare, first.(s0))
                @test length(s0) == length(must)
            else
                err = try
                    Bennett.extract_parsed_ir_set_from_julia(f, T; include_root=false); nothing
                catch e
                    sprint(showerror, e)
                end
                @test err !== nothing
                @test occursin("closed-world violation", err)
                @test occursin("Function callee `$rootbare` is NOT in the set", err)
                @test !occursin("duplicate", err)
            end

            # The temporary root registration (recursive roots) is scoped:
            # nothing leaks into the process-global registry.
            @test !haskey(Bennett._known_callees, rootbare)
        end
    end
end
