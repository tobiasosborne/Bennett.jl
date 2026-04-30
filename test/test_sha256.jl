using Random

@testset "SHA-256 round function benchmark" begin
    # SHA-256 helper functions (all pure UInt32 operations)
    ch(e::UInt32, f::UInt32, g::UInt32) = (e & f) ⊻ (~e & g)
    maj(a::UInt32, b::UInt32, c::UInt32) = (a & b) ⊻ (a & c) ⊻ (b & c)
    rotr(x::UInt32, n::Int) = (x >> n) | (x << (32 - n))
    sigma0(a::UInt32) = rotr(a, 2) ⊻ rotr(a, 13) ⊻ rotr(a, 22)
    sigma1(e::UInt32) = rotr(e, 6) ⊻ rotr(e, 11) ⊻ rotr(e, 25)

    @testset "SHA-256 sub-functions" begin
        c_ch = reversible_compile(ch, UInt32, UInt32, UInt32)
        @test verify_reversibility(c_ch)
        gc_ch = gate_count(c_ch)
        println("  ch: $(gc_ch.total) gates, T=$(t_count(c_ch)), Td=$(t_depth(c_ch))")

        c_maj = reversible_compile(maj, UInt32, UInt32, UInt32)
        @test verify_reversibility(c_maj)
        gc_maj = gate_count(c_maj)
        println("  maj: $(gc_maj.total) gates, T=$(t_count(c_maj))")

        c_s0 = reversible_compile(sigma0, UInt32)
        @test verify_reversibility(c_s0)
        println("  sigma0: $(gate_count(c_s0).total) gates, T=$(t_count(c_s0))")

        c_s1 = reversible_compile(sigma1, UInt32)
        @test verify_reversibility(c_s1)
        println("  sigma1: $(gate_count(c_s1).total) gates, T=$(t_count(c_s1))")
    end

    @testset "SHA-256 full round" begin
        function sha256_round(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
                              e::UInt32, f::UInt32, g::UInt32, h::UInt32,
                              k::UInt32, w::UInt32)
            t1 = h + sigma1(e) + ch(e, f, g) + k + w
            t2 = sigma0(a) + maj(a, b, c)
            new_e = d + t1
            new_a = t1 + t2
            return (new_a, new_e)
        end

        circuit = reversible_compile(sha256_round, ntuple(_ -> UInt32, 10)...)
        gc = gate_count(circuit)
        tc = t_count(circuit)
        td = t_depth(circuit)
        ac = ancilla_count(circuit)

        println("  SHA-256 round:")
        println("    Gates:    $(gc.total) (NOT=$(gc.NOT), CNOT=$(gc.CNOT), Toffoli=$(gc.Toffoli))")
        println("    T-count:  $tc")
        println("    T-depth:  $td")
        println("    Wires:    $(circuit.n_wires)")
        println("    Ancillae: $ac")

        @test verify_reversibility(circuit)

        # Verify correctness with SHA-256 initial hash values
        a,b,c_,d = UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a)
        e,f,g,h = UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19)
        k, w = UInt32(0x428a2f98), UInt32(0x61626380)

        expected = sha256_round(a, b, c_, d, e, f, g, h, k, w)
        result = simulate(circuit, (a, b, c_, d, e, f, g, h, k, w))
        @test UInt32(result[1]) == expected[1]
        @test UInt32(result[2] % UInt32) == expected[2]

        # Second round
        k2, w2 = UInt32(0x71374491), UInt32(0x00000000)
        expected2 = sha256_round(UInt32(result[1]), a, b, c_, UInt32(result[2] % UInt32), e, f, g, k2, w2)
        result2 = simulate(circuit, (UInt32(result[1]), a, b, c_, UInt32(result[2] % UInt32), e, f, g, k2, w2))
        @test UInt32(result2[1]) == expected2[1]
        @test UInt32(result2[2] % UInt32) == expected2[2]

        # Bennett-kv7b / U65 (#03 F8, #05 F15) — was 2 inputs (well-known
        # SHA-256 initial values + derived round 2). Add a fixed-seed random
        # sweep over 64 random 320-bit input vectors plus 8 corner cases
        # (all-zero, all-ones, alternating bit patterns, single-bit-set
        # at each byte-boundary). At ~1670 gates per SHA-256 round and
        # post-fehu simulate! at ~ms per call, 72 sims add <100ms to
        # pkg test wall time but exercise the full 10-input × UInt32
        # input space mass effectively.
        rng = Random.MersenneTwister(0x5a256cd5)
        corner_vectors = [
            ntuple(_ -> UInt32(0), 10),
            ntuple(_ -> typemax(UInt32), 10),
            ntuple(i -> i % 2 == 1 ? UInt32(0xaaaaaaaa) : UInt32(0x55555555), 10),
            ntuple(i -> i % 2 == 1 ? UInt32(0x55555555) : UInt32(0xaaaaaaaa), 10),
            ntuple(i -> UInt32(1) << ((i*3) % 32), 10),
            ntuple(i -> UInt32(0xdeadbeef) ⊻ UInt32(i), 10),
            ntuple(i -> i == 1 ? UInt32(0) : UInt32(rand(rng, UInt32)), 10),  # a=0
            ntuple(i -> i == 9 || i == 10 ? UInt32(0) : UInt32(rand(rng, UInt32)), 10),  # k=w=0
        ]
        for v in corner_vectors
            exp = sha256_round(v...)
            got = simulate(circuit, v)
            @test UInt32(got[1]) == exp[1]
            @test UInt32(got[2] % UInt32) == exp[2]
        end
        for _ in 1:64
            v = ntuple(_ -> rand(rng, UInt32), 10)
            exp = sha256_round(v...)
            got = simulate(circuit, v)
            @test UInt32(got[1]) == exp[1]
            @test UInt32(got[2] % UInt32) == exp[2]
        end
    end
end
