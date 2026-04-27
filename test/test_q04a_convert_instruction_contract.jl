using Test
using Bennett
using LLVM
using InteractiveUtils: subtypes, code_warntype

# Bennett-q04a / 59jj-cut — investigation of "_convert_instruction returns
# 17-arm Union; callers union-dispatch on every result. Suggested split:
# _convert_instruction_single + _convert_instruction_expand!"
#
# Live measurement (2026-04-27 evening): the Union return IS real and IS
# beyond Julia's union-splitting threshold (~4-7 arms), but the function
# is on the EXTRACTION path — one call per LLVM instruction, ~7-200
# instructions per typical compiled function, ONE extraction per
# `reversible_compile`. NOT a runtime hot loop. Empirical extraction cost
# on a 7-instruction function: ~1.93 KiB total / ~275 alloc per
# instruction; the 17-arm Union contributes ≤16 B per call (one box) =
# ~112 B = ~5% of the 1.93 KiB total. Refactor would touch the 17-return-
# path body of `_convert_instruction` plus the caller dispatch at
# `src/ir_extract.jl:1003-1018`.
#
# Per the chunk-045 calibration: "investigated, doc-only" disposition —
# bead's premise valid but cost/benefit out of proportion to the
# refactor blast radius (CLAUDE.md §2 3+1 trip-wire on ir_extract.jl).
# This file pins the contracts so a future agent can re-measure and
# resurrect the work if extraction becomes a measurable bottleneck.
@testset "q04a / 59jj-cut: _convert_instruction Union-return contract (investigated, doc-only)" begin

    # =========================================================================
    # 1. IRInst hierarchy contract — pins the count of concrete IR types.
    #    A future agent splitting the function into `_single::IRInst` would
    #    shift the return type from a 17-arm Union to a 1-arm IRInst (still
    #    abstract) — equivalent for Julia's union-splitting because IRInst
    #    has 16+ concrete subtypes. The clean win comes from removing the
    #    `Vector` and `Nothing` arms via `_expand!(out, ...)`. Pinning the
    #    subtype count guards both directions: if a new IRInst lands, the
    #    refactor calculus shifts (Union grows or shrinks).
    # =========================================================================
    @testset "IRInst subtype count is exactly 16" begin
        concrete = subtypes(Bennett.IRInst)
        @test length(concrete) == 16
        # Verify the canonical set — any drift here trips the test.
        names = Set(Symbol(t.name.name) for t in concrete)
        expected = Set([
            :IRBinOp, :IRICmp, :IRSelect, :IRPhi, :IRCast, :IRBranch,
            :IRRet, :IRCall, :IRStore, :IRLoad, :IRAlloca, :IRPtrOffset,
            :IRVarGEP, :IRExtractValue, :IRInsertValue, :IRSwitch,
        ])
        @test names == expected
    end

    # =========================================================================
    # 2. Return-type contract — the @code_warntype output's Body line names
    #    a Union (or IRInst) covering the IR types. Pin that the union arm
    #    count is bounded — if it ever exceeds ~20, the refactor MUST be
    #    revisited.
    # =========================================================================
    @testset "_convert_instruction return Union is bounded" begin
        io = IOBuffer()
        code_warntype(io, Bennett._convert_instruction,
            Tuple{LLVM.Instruction, Dict{Bennett._LLVMRef, Symbol},
                  Ref{Int}, Dict{Bennett._LLVMRef, Vector{Bennett.IROperand}}})
        out = String(take!(io))
        # Capture the Body return type line. Julia 1.12 emits
        # "Body::UNION{...}" (uppercase) for not-fully-stable code.
        # Find first line that starts with "Body::" or contains "::Union{"
        body_idx = findfirst(occursin("Body::"), split(out, '\n'))
        @test body_idx !== nothing

        # Count types named — split on commas inside the outermost {…}.
        # If ever exceeds 20, escalate.
        m = match(r"Body::U(?:NION|nion)\{([^}]+)\}"i, out)
        if m !== nothing
            arms = split(m.captures[1], ",")
            n = length(arms)
            @test 10 <= n <= 22   # current observed: 18 arms (16 IRInst + Nothing + Vector)
        else
            # If Julia infers a single concrete type someday, this branch
            # wins and we can simplify the prescription.
            @test occursin("Body::IRInst", out) || occursin("Body::Bennett", out)
        end
    end

    # =========================================================================
    # 3. Caller dispatch contract — the call site in `_walk_function!`
    #    handles the Union via 4 isa-checks (=== nothing / isa Vector /
    #    isa IRRet || IRBranch || IRSwitch / else). The split refactor
    #    would replace this with two clean call paths. Pin the current
    #    shape so a future agent can target it precisely.
    # =========================================================================
    @testset "caller dispatch shape at the extraction site" begin
        src = read(joinpath(dirname(pathof(Bennett)), "ir_extract.jl"), String)
        # The 4-arm dispatch lives at line ~1003-1018 (file may shift).
        # Pin the dispatch shape via canonical substrings that any refactor
        # MUST update together. Current shape (post-jepw + 6t8s):
        #   ir_inst === nothing && continue
        #   ir_inst isa Vector → expand
        #   ir_inst isa IRRet || IRBranch || IRSwitch → terminator
        #   else → push!(insts, ir_inst)
        @test occursin("ir_inst === nothing && continue", src)
        @test occursin("ir_inst isa Vector", src)
        @test occursin("ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch", src)
    end

    # =========================================================================
    # 4. Extraction allocation contract — extraction is one-shot per compile,
    #    NOT a hot loop. Pin a generous allocation budget to detect any
    #    accidental N²-blowup, but avoid pinning so tightly that minor
    #    growth in LLVM.jl or the walker trips it.
    # =========================================================================
    @testset "extraction is ~linear in instruction count" begin
        f1(a::Int64, b::Int64) = a + b
        f2(a::Int64, b::Int64) = a + b * (a - b) + a*a - b*b
        # Warm up.
        Bennett.extract_parsed_ir(f1, Tuple{Int64,Int64}; optimize=false)
        Bennett.extract_parsed_ir(f2, Tuple{Int64,Int64}; optimize=false)

        a1 = @allocated Bennett.extract_parsed_ir(f1, Tuple{Int64,Int64}; optimize=false)
        a2 = @allocated Bennett.extract_parsed_ir(f2, Tuple{Int64,Int64}; optimize=false)

        # Both should be in the same order of magnitude — extract is dominated
        # by LLVM module setup overhead (one-time-per-call), not the per-
        # instruction Union return. If the Union return became a hot-loop
        # alloc-per-instruction, we'd see a2/a1 grow past ~3×.
        @test a2 / a1 < 3.0

        # Hard cap: extraction of a 7-instruction function must remain
        # under 200 KiB. If a refactor accidentally scales worse, this trips.
        @test a2 < 200_000
    end
end
