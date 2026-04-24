@testset "Pebbled Bennett with wire reuse" begin
    # U28 / Bennett-epwy: `fold_constants` is on by default. The fold
    # rewrites the gate list and invalidates `lr.gate_groups`, which the
    # pebbled_group_bennett / checkpoint_bennett strategies consume. Every
    # `lower()` call below opts out so the pebble/checkpoint paths stay
    # exercised rather than silently falling back to full Bennett.

    # ================================================================
    # Test 1: pebbled_group_bennett correctness — increment
    # ================================================================
    @testset "pebbled_group_bennett: increment correctness" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}); fold_constants=false)
        c_full = Bennett.bennett(lr)
        s = max(Bennett.min_pebbles(length(lr.gate_groups)), 2)
        c_peb = pebbled_group_bennett(lr; max_pebbles=s)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_peb, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_peb)
    end

    # ================================================================
    # Test 2: pebbled_group_bennett correctness — polynomial
    # ================================================================
    @testset "pebbled_group_bennett: polynomial correctness" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}); fold_constants=false)
        c_full = Bennett.bennett(lr)
        s = Bennett.min_pebbles(length(lr.gate_groups))
        c_peb = pebbled_group_bennett(lr; max_pebbles=s)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_peb, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_peb)
    end

    # ================================================================
    # Test 3: SHA-256 — correctness + wire reduction
    # ================================================================
    @testset "pebbled_group_bennett: SHA-256 wire reduction" begin
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
        c_full = Bennett.bennett(lr)

        s = Bennett.min_pebbles(length(lr.gate_groups))
        c_peb = pebbled_group_bennett(lr; max_pebbles=s)

        # Correctness
        a,b,c_,d = UInt32(0x6a09e667), UInt32(0xbb67ae85),
                    UInt32(0x3c6ef372), UInt32(0xa54ff53a)
        e,f,g,h = UInt32(0x510e527f), UInt32(0x9b05688c),
                   UInt32(0x1f83d9ab), UInt32(0x5be0cd19)
        k, w = UInt32(0x428a2f98), UInt32(0x61626380)
        @test simulate(c_peb, (a,b,c_,d,e,f,g,h,k,w)) ==
              simulate(c_full, (a,b,c_,d,e,f,g,h,k,w))
        @test verify_reversibility(c_peb)

        # Wire reduction
        println("  SHA-256: full=$(c_full.n_wires) wires, pebbled(s=$s)=$(c_peb.n_wires) wires")
        @test c_peb.n_wires <= c_full.n_wires
    end

    # ================================================================
    # Test 3b: checkpoint_bennett — SHA-256 wire reduction
    # ================================================================
    @testset "checkpoint_bennett: SHA-256 wire reduction" begin
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

        # Use use_inplace=false for checkpoint_bennett (Cuccaro in-place is
        # incompatible with per-group checkpointing — result wires from deps)
        Bennett._reset_names!()
        parsed = Bennett.extract_parsed_ir(sha256_round,
                     Tuple{ntuple(_ -> UInt32, 10)...})
        lr = Bennett.lower(parsed; use_inplace=false, fold_constants=false)
        c_full = Bennett.bennett(lr)
        c_ckpt = Bennett.checkpoint_bennett(lr)

        # Correctness
        a,b,c_,d = UInt32(0x6a09e667), UInt32(0xbb67ae85),
                    UInt32(0x3c6ef372), UInt32(0xa54ff53a)
        e,f,g,h = UInt32(0x510e527f), UInt32(0x9b05688c),
                   UInt32(0x1f83d9ab), UInt32(0x5be0cd19)
        k, w = UInt32(0x428a2f98), UInt32(0x61626380)
        @test simulate(c_ckpt, (a,b,c_,d,e,f,g,h,k,w)) ==
              simulate(c_full, (a,b,c_,d,e,f,g,h,k,w))
        @test verify_reversibility(c_ckpt)

        # Wire reduction: checkpoint should be meaningfully less than full Bennett
        println("  SHA-256: full=$(c_full.n_wires), checkpoint=$(c_ckpt.n_wires)")
        @test c_ckpt.n_wires < c_full.n_wires
    end

    # ================================================================
    # Test 4: GateGroup wire_start/wire_end tracking
    # ================================================================
    @testset "GateGroup wire range tracking" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}); fold_constants=false)
        for g in lr.gate_groups
            # Every group must have wire_start and wire_end
            @test g.wire_start >= 1
            @test g.wire_end >= g.wire_start
            # Result wires must be within the wire range
            for w in g.result_wires
                @test g.wire_start <= w <= g.wire_end
            end
        end
    end

    # ================================================================
    # Test 5: checkpoint_bennett correctness — increment (small, no reduction expected)
    # ================================================================
    @testset "checkpoint_bennett: increment correctness" begin
        f(x::Int8) = x + Int8(3)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(f, Tuple{Int8}); fold_constants=false)
        c_full = Bennett.bennett(lr)
        c_ckpt = Bennett.checkpoint_bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_ckpt, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_ckpt)
        println("  increment: full=$(c_full.n_wires), checkpoint=$(c_ckpt.n_wires)")
    end

    # ================================================================
    # Test 6: checkpoint_bennett correctness — polynomial (wire reduction expected)
    # ================================================================
    @testset "checkpoint_bennett: polynomial correctness + wire reduction" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        Bennett._reset_names!()
        lr = Bennett.lower(Bennett.extract_parsed_ir(g, Tuple{Int8}); fold_constants=false)
        c_full = Bennett.bennett(lr)
        c_ckpt = Bennett.checkpoint_bennett(lr)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c_ckpt, x) == simulate(c_full, x)
        end
        @test verify_reversibility(c_ckpt)
        println("  polynomial: full=$(c_full.n_wires), checkpoint=$(c_ckpt.n_wires)")
        @test c_ckpt.n_wires < c_full.n_wires
    end
end
