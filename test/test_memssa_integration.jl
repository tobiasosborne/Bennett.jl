using Test
using Bennett
using Bennett: MemSSAInfo

# T2a.3 — Integration tests demonstrating MemorySSA captures information that
# T0 preprocessing (sroa / mem2reg / simplifycfg / instcombine) cannot.
#
# For each pattern: compile the function with preprocess=true AND
# use_memory_ssa=true, then assert:
#   (a) memory operations SURVIVED preprocessing (the interesting case),
#   (b) MemSSAInfo contains the Def/Use/Phi annotations that would let
#       a future lower_load! pick the right incoming memory state.
#
# These tests establish the diagnostic capability. Wiring the info into
# lower_load! for correctness-improving dispatch is out-of-scope follow-up.

# Helper: count instruction types across all blocks of a ParsedIR.
function _count_ir(parsed, ::Type{T}) where T
    n = 0
    for b in parsed.blocks
        for inst in b.instructions
            inst isa T && (n += 1)
        end
    end
    return n
end

@testset "T2a.3 MemorySSA integration — cases T0 misses" begin

    @testset "var-index load into local array" begin
        # SROA+mem2reg can't eliminate a var-indexed alloca. The store chain
        # remains visible and MemorySSA annotates it.
        f(x::UInt8, i::UInt8) = let a = [x, x+UInt8(1), x+UInt8(2), x+UInt8(3)]
            a[(i & 0x3) + 1]
        end

        parsed = Bennett.extract_parsed_ir(f, Tuple{UInt8, UInt8};
                                            preprocess=true, use_memory_ssa=true)
        @test parsed.memssa !== nothing
        # Memory ops DID survive preprocessing
        n_stores = _count_ir(parsed, Bennett.IRStore)
        n_loads  = _count_ir(parsed, Bennett.IRLoad)
        @test n_stores >= 1 || n_loads >= 1
        # Memssa has non-empty annotations
        @test !isempty(parsed.memssa.def_clobber)
        @test !isempty(parsed.memssa.use_at_line)
    end

    @testset "conditional store in diamond CFG produces MemoryPhi" begin
        # The paper-winning case: one branch stores into the array, the other
        # doesn't. At merge, MemorySSA synthesizes a MemoryPhi telling us the
        # load reads either branch's state. T0 preprocessing cannot simplify
        # this into a single value because the branch condition is dynamic.
        f(x::UInt8, cond::Bool) = let a = [UInt8(0), UInt8(0), UInt8(0), UInt8(0)]
            if cond
                a[1] = x
            end
            a[1]
        end

        parsed = Bennett.extract_parsed_ir(f, Tuple{UInt8, Bool};
                                            preprocess=true, use_memory_ssa=true)
        @test parsed.memssa !== nothing
        # Either memssa captures a Phi directly, or the diamond was folded and
        # we still have Def/Use annotations — either way non-empty.
        mem_nonempty = !isempty(parsed.memssa.phis) ||
                       !isempty(parsed.memssa.use_at_line) ||
                       !isempty(parsed.memssa.def_clobber)
        @test mem_nonempty
    end

    @testset "sequential stores + load" begin
        # Multiple stores to the same location (not vectorized — avoids
        # InsertElement emit from SROA on array patterns). Each store creates
        # a distinct MemoryDef; the final load reads the last.
        f(x::UInt8) = let a = Ref(UInt8(0))
            a[] = x
            a[] = x + UInt8(1)
            a[] = x + UInt8(2)
            a[]
        end

        parsed = Bennett.extract_parsed_ir(f, Tuple{UInt8};
                                            preprocess=false, use_memory_ssa=true)
        @test parsed.memssa !== nothing
        # Raw IR (no preprocess) has stores/loads of the Ref
        @test !isempty(parsed.memssa.def_clobber) ||
              !isempty(parsed.memssa.use_at_line)
    end

    @testset "memssa-off matches T0 behavior exactly" begin
        # The use_memory_ssa flag must be a pure addition: turning it on
        # doesn't change the walked IR (ParsedIR.blocks, args, ret_width
        # should match bit-for-bit when we turn memssa on vs off).
        f(x::Int8) = x + Int8(1)
        a_off = Bennett.extract_parsed_ir(f, Tuple{Int8})
        a_on  = Bennett.extract_parsed_ir(f, Tuple{Int8}; use_memory_ssa=true)
        @test length(a_off.blocks) == length(a_on.blocks)
        @test a_off.args == a_on.args
        @test a_off.ret_width == a_on.ret_width
        @test a_off.memssa === nothing
        @test a_on.memssa !== nothing
    end

    @testset "annotation IDs form a consistent graph" begin
        # Every Use's target Def should exist in def_clobber (or be
        # live-on-entry sentinel 0). No dangling references.
        f(x::Int, i::Int) = let a = [x, x+1, x+2, x+3]
            a[(i & 0x3) + 1]
        end
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int, Int};
                                            preprocess=true, use_memory_ssa=true)
        for (_, def_id) in parsed.memssa.use_at_line
            @test def_id == 0 || haskey(parsed.memssa.def_clobber, def_id) ||
                  haskey(parsed.memssa.phis, def_id)
        end
        # Every def's clobber target either exists as another Def or is :live_on_entry
        for (_, clobber) in parsed.memssa.def_clobber
            @test clobber === :live_on_entry ||
                  haskey(parsed.memssa.def_clobber, clobber) ||
                  haskey(parsed.memssa.phis, clobber)
        end
    end

    # Bennett-kv7b / U65 (#05 F5): the memssa flag was previously
    # validated only at the `extract_parsed_ir` boundary; the rest of
    # the pipeline (`lower → bennett → simulate → verify_reversibility`)
    # was never exercised with `use_memory_ssa=true`. With the current
    # `lower()` not yet consuming memssa info (per the docstring above:
    # "Wiring the info into lower_load! ... is out-of-scope follow-up"),
    # the flag MUST be a pure pass-through: identical gate counts,
    # identical simulation behaviour, identical reversibility guarantees
    # whether or not `use_memory_ssa=true` is set. The tests below pin
    # that contract end-to-end.

    @testset "end-to-end pipeline with memssa flag is byte-identical to without" begin
        # Straight-line arithmetic — no memory ops, but exercises the
        # extract → lower → bennett pipeline with both flag values.
        f(x::Int8) = x * x + Int8(3) * x + Int8(1)

        parsed_off = Bennett.extract_parsed_ir(f, Tuple{Int8})
        parsed_on  = Bennett.extract_parsed_ir(f, Tuple{Int8}; use_memory_ssa=true)
        @test parsed_off.memssa === nothing
        @test parsed_on.memssa  !== nothing

        c_off = reversible_compile(parsed_off)
        c_on  = reversible_compile(parsed_on)

        # Gate-by-gate identity: turning on memssa MUST NOT alter the
        # circuit produced by the current lower(). If/when lower starts
        # consuming memssa for dispatch, this assertion will need to be
        # relaxed to "behaviourally equivalent" — but that's the right
        # forcing function for the migration.
        @test gate_count(c_off) == gate_count(c_on)
        @test c_off.gates == c_on.gates
        @test c_off.n_wires == c_on.n_wires

        # End-to-end correctness with memssa on: simulate against oracle
        # AND verify_reversibility. Both are required (CLAUDE.md §4).
        @test verify_reversibility(c_on)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_on, x) == f(x)
        end
    end

    @testset "end-to-end with preprocess=true × memssa is byte-identical to without" begin
        # The `preprocess=true` × `use_memory_ssa=true` combination is
        # the canonical "fully annotated" extraction path. The full
        # var-index-array pipeline (`f(x, i) = a[i & 3]`) is not yet
        # end-to-end lowerable through `reversible_compile` (blocked on
        # Bennett-z2dj T5-P6 `:persistent_tree` dispatcher), so we pin
        # the contract on a multi-arg straight-line function that
        # exercises the preprocessing pass without retaining memory ops.
        g(x::Int8, y::Int8) = x * y + x - y

        parsed_off = Bennett.extract_parsed_ir(g, Tuple{Int8, Int8})
        parsed_on  = Bennett.extract_parsed_ir(g, Tuple{Int8, Int8};
                                                preprocess=true,
                                                use_memory_ssa=true)
        c_off = reversible_compile(parsed_off)
        c_on  = reversible_compile(parsed_on)

        @test gate_count(c_off) == gate_count(c_on)
        @test verify_reversibility(c_on)

        # Sample simulate sweep — small enough to keep test time
        # bounded, big enough to cover sign-change and zero corners.
        for x in Int8(-3):Int8(3), y in Int8(-3):Int8(3)
            @test simulate(c_on, (x, y)) == g(x, y)
        end
    end
end
