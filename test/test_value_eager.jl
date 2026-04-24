@testset "Value-level EAGER cleanup (PRS15 Algorithm 2)" begin
    # U28 / Bennett-epwy: `fold_constants` is on by default. The fold rewrites
    # the gate list and invalidates `lr.gate_groups`, which `value_eager_bennett`
    # and friends consume. Every `lower()` call in this file opts out so the
    # tests actually exercise the eager / gate-group machinery rather than
    # silently falling back to full Bennett.

    # ================================================================
    # Test 1: GateGroup annotation exists in LoweringResult
    # ================================================================
    @testset "gate groups: basic annotation" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(f, Tuple{Int8})
        lr = Bennett.lower(parsed; fold_constants=false)

        @test isdefined(lr, :gate_groups)
        @test length(lr.gate_groups) > 0

        for g in lr.gate_groups
            @test g.gate_start >= 1
            @test g.gate_end >= g.gate_start
            @test g.gate_end <= length(lr.gates)
            @test !isempty(g.result_wires)
        end

        covered = Set{Int}()
        for g in lr.gate_groups
            for i in g.gate_start:g.gate_end
                @test i ∉ covered
                push!(covered, i)
            end
        end
        @test covered == Set(1:length(lr.gates))
    end

    # ================================================================
    # Test 2: GateGroup annotation for polynomial (multi-instruction)
    # ================================================================
    @testset "gate groups: polynomial structure" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(g, Tuple{Int8})
        lr = Bennett.lower(parsed; fold_constants=false)

        @test length(lr.gate_groups) >= 4

        all_results = Set{Int}()
        for gg in lr.gate_groups
            for w in gg.result_wires
                @test w ∉ all_results
                push!(all_results, w)
            end
        end

        ssa_defined = Set{Symbol}()
        for (name, _) in parsed.args
            push!(ssa_defined, name)
        end
        for gg in lr.gate_groups
            for dep in gg.input_ssa_vars
                @test dep in ssa_defined
            end
            push!(ssa_defined, gg.ssa_name)
        end
    end

    # ================================================================
    # Test 3: value_eager_bennett correctness — increment
    # ================================================================
    @testset "value_eager_bennett: increment correctness" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}); fold_constants=false)
        c_eager = Bennett.value_eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_eager)
    end

    # ================================================================
    # Test 4: value_eager_bennett correctness — polynomial
    # ================================================================
    @testset "value_eager_bennett: polynomial correctness" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}); fold_constants=false)
        c_eager = Bennett.value_eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_eager)
    end

    # ================================================================
    # Test 5: value_eager_bennett correctness — two-argument
    # ================================================================
    @testset "value_eager_bennett: two-arg correctness" begin
        h(x::Int8, y::Int8) = x + y
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(h, Tuple{Int8, Int8}); fold_constants=false)
        c_eager = Bennett.value_eager_bennett(lr)
        c_full  = Bennett.bennett(lr)
        for x in Int8(-10):Int8(10), y in Int8(-10):Int8(10)
            @test simulate(c_eager, (x, y)) == simulate(c_full, (x, y))
        end
        @test verify_reversibility(c_eager)
    end

    # ================================================================
    # Test 6: peak liveness — at least as good as full Bennett
    # ================================================================
    @testset "value_eager_bennett: peak liveness" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}); fold_constants=false)
        c_full  = Bennett.bennett(lr)
        c_eager = Bennett.value_eager_bennett(lr)
        p_full  = peak_live_wires(c_full)
        p_eager = peak_live_wires(c_eager)
        println("  polynomial: full peak=$p_full, value_eager peak=$p_eager")
        @test p_eager <= p_full
    end

    # ================================================================
    # Test 7: SHA-256 round — correctness + peak liveness
    # ================================================================
    @testset "value_eager_bennett: SHA-256 round" begin
        ch(e::UInt32, f::UInt32, g::UInt32) = (e & f) ⊻ (~e & g)
        maj(a::UInt32, b::UInt32, c::UInt32) = (a & b) ⊻ (a & c) ⊻ (b & c)
        rotr(x::UInt32, n::Int) = (x >> n) | (x << (32 - n))
        sigma0(a::UInt32) = rotr(a, 2) ⊻ rotr(a, 13) ⊻ rotr(a, 22)
        sigma1(e::UInt32) = rotr(e, 6) ⊻ rotr(e, 11) ⊻ rotr(e, 25)

        function sha256_round(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
                              e::UInt32, f::UInt32, g::UInt32, h::UInt32,
                              k::UInt32, w::UInt32)
            t1 = h + sigma1(e) + ch(e, f, g) + k + w
            t2 = sigma0(a) + maj(a, b, c)
            new_e = d + t1
            new_a = t1 + t2
            return (new_a, new_e)
        end

        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(sha256_round,
                     Tuple{ntuple(_ -> UInt32, 10)...})
        lr = Bennett.lower(parsed; fold_constants=false)
        c_full  = Bennett.bennett(lr)
        c_eager = Bennett.value_eager_bennett(lr)

        # Correctness
        a,b,c_,d = UInt32(0x6a09e667), UInt32(0xbb67ae85),
                    UInt32(0x3c6ef372), UInt32(0xa54ff53a)
        e,f,g,h = UInt32(0x510e527f), UInt32(0x9b05688c),
                   UInt32(0x1f83d9ab), UInt32(0x5be0cd19)
        k, w = UInt32(0x428a2f98), UInt32(0x61626380)
        @test simulate(c_eager, (a,b,c_,d,e,f,g,h,k,w)) ==
              simulate(c_full, (a,b,c_,d,e,f,g,h,k,w))
        # Bennett-rggq / U02 fix landed the branching-CFG fallback. SHA-256
        # round is straight-line arithmetic (sigma/ch/maj are bitwise — no
        # `if`), so it has only one `__pred_*` group (entry) and does NOT
        # trigger the `_has_branching` fallback. Yet value_eager still fails
        # Bennett's input-preservation invariant here — Kahn's reverse-topo
        # is broken by a second, distinct pattern (likely Cuccaro-adder
        # in-place writes on shared wires). Filed as a follow-up bead
        # pending investigation; stays @test_broken until that lands.
        @test_broken verify_reversibility(c_eager)

        p_full  = peak_live_wires(c_full)
        p_eager = peak_live_wires(c_eager)
        println("  SHA-256: full peak=$p_full, value_eager peak=$p_eager")
        @test p_eager <= p_full
    end

    # ================================================================
    # Test 8: Combination with Cuccaro in-place adder
    # ================================================================
    @testset "value_eager + Cuccaro in-place" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}); use_inplace=true, fold_constants=false)
        c_full  = Bennett.bennett(lr)
        c_eager = Bennett.value_eager_bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager, x) == f(x)
        end
        @test verify_reversibility(c_eager)

        p_full  = peak_live_wires(c_full)
        p_eager = peak_live_wires(c_eager)
        println("  x+3 inplace: full peak=$p_full, eager peak=$p_eager")
        @test p_eager <= p_full

        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        lr2 = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}); use_inplace=true, fold_constants=false)
        c_full2  = Bennett.bennett(lr2)
        c_eager2 = Bennett.value_eager_bennett(lr2)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_eager2, x) == g(x)
        end
        @test verify_reversibility(c_eager2)

        p_full2  = peak_live_wires(c_full2)
        p_eager2 = peak_live_wires(c_eager2)
        println("  poly inplace: full peak=$p_full2, eager peak=$p_eager2")
        @test p_eager2 <= p_full2
    end
end
