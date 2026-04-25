using Test
using Bennett
using Bennett: reversible_compile, simulate, verify_reversibility,
               gate_count, ancilla_count, t_count

# ---- SHA-256 reference (pure Julia, UInt32) ----

_ch(e::UInt32, f::UInt32, g::UInt32) = (e & f) ⊻ (~e & g)
_maj(a::UInt32, b::UInt32, c::UInt32) = (a & b) ⊻ (a & c) ⊻ (b & c)
_rotr(x::UInt32, n::Int) = (x >> n) | (x << (32 - n))
_Sigma0(a::UInt32) = _rotr(a, 2)  ⊻ _rotr(a, 13) ⊻ _rotr(a, 22)
_Sigma1(e::UInt32) = _rotr(e, 6)  ⊻ _rotr(e, 11) ⊻ _rotr(e, 25)
_sigma0(x::UInt32) = _rotr(x, 7)  ⊻ _rotr(x, 18) ⊻ (x >> 3)
_sigma1(x::UInt32) = _rotr(x, 17) ⊻ _rotr(x, 19) ⊻ (x >> 10)

const _SHA256_K = (
    UInt32(0x428a2f98), UInt32(0x71374491), UInt32(0xb5c0fbcf), UInt32(0xe9b5dba5),
    UInt32(0x3956c25b), UInt32(0x59f111f1), UInt32(0x923f82a4), UInt32(0xab1c5ed5),
    UInt32(0xd807aa98), UInt32(0x12835b01), UInt32(0x243185be), UInt32(0x550c7dc3),
    UInt32(0x72be5d74), UInt32(0x80deb1fe), UInt32(0x9bdc06a7), UInt32(0xc19bf174),
    UInt32(0xe49b69c1), UInt32(0xefbe4786), UInt32(0x0fc19dc6), UInt32(0x240ca1cc),
    UInt32(0x2de92c6f), UInt32(0x4a7484aa), UInt32(0x5cb0a9dc), UInt32(0x76f988da),
    UInt32(0x983e5152), UInt32(0xa831c66d), UInt32(0xb00327c8), UInt32(0xbf597fc7),
    UInt32(0xc6e00bf3), UInt32(0xd5a79147), UInt32(0x06ca6351), UInt32(0x14292967),
    UInt32(0x27b70a85), UInt32(0x2e1b2138), UInt32(0x4d2c6dfc), UInt32(0x53380d13),
    UInt32(0x650a7354), UInt32(0x766a0abb), UInt32(0x81c2c92e), UInt32(0x92722c85),
    UInt32(0xa2bfe8a1), UInt32(0xa81a664b), UInt32(0xc24b8b70), UInt32(0xc76c51a3),
    UInt32(0xd192e819), UInt32(0xd6990624), UInt32(0xf40e3585), UInt32(0x106aa070),
    UInt32(0x19a4c116), UInt32(0x1e376c08), UInt32(0x2748774c), UInt32(0x34b0bcb5),
    UInt32(0x391c0cb3), UInt32(0x4ed8aa4a), UInt32(0x5b9cca4f), UInt32(0x682e6ff3),
    UInt32(0x748f82ee), UInt32(0x78a5636f), UInt32(0x84c87814), UInt32(0x8cc70208),
    UInt32(0x90befffa), UInt32(0xa4506ceb), UInt32(0xbef9a3f7), UInt32(0xc67178f2))

"""
Reference Julia implementation — compresses one 512-bit block `w0..w15` with
hash state `h0..h7`. Returns the updated 8-word state (new H[0..7]).
"""
function sha256_compress_ref(
    h0::UInt32, h1::UInt32, h2::UInt32, h3::UInt32,
    h4::UInt32, h5::UInt32, h6::UInt32, h7::UInt32,
    w0::UInt32, w1::UInt32, w2::UInt32, w3::UInt32,
    w4::UInt32, w5::UInt32, w6::UInt32, w7::UInt32,
    w8::UInt32, w9::UInt32, w10::UInt32, w11::UInt32,
    w12::UInt32, w13::UInt32, w14::UInt32, w15::UInt32)
    W = UInt32[w0,w1,w2,w3,w4,w5,w6,w7,w8,w9,w10,w11,w12,w13,w14,w15]
    for i in 17:64
        W_i = _sigma1(W[i-2]) + W[i-7] + _sigma0(W[i-15]) + W[i-16]
        push!(W, W_i)
    end
    a, b, c, d = h0, h1, h2, h3
    e, f, g, h = h4, h5, h6, h7
    for i in 1:64
        t1 = h + _Sigma1(e) + _ch(e, f, g) + _SHA256_K[i] + W[i]
        t2 = _Sigma0(a) + _maj(a, b, c)
        h = g;  g = f;  f = e;  e = d + t1
        d = c;  c = b;  b = a;  a = t1 + t2
    end
    return (h0+a, h1+b, h2+c, h3+d, h4+e, h5+f, h6+g, h7+h)
end

# ---- Metaprogrammed unrolled SHA-256 compression ----
#
# We cannot use a Vector + push! (no dynamic resize in Bennett); we cannot use
# a dynamic loop with array indexing at W=32, N=64 (only MUX-EXCH 4×8 / 8×8
# shapes are currently supported by the memory dispatcher). Strategy: generate
# straight-line SSA code covering all 48 schedule extensions + `n_rounds` main
# rounds, with K constants baked in as literals.

"""
Generate a SHA-256 compression function expression with `n_rounds` rounds
(n_rounds ∈ 1..64). When n_rounds == 64 this is the full compression.
"""
function _sha256_body(n_rounds::Int)
    @assert 1 <= n_rounds <= 64
    body = Expr(:block)
    # Message schedule extension: W16..W_{n_rounds+15} (but clamp to ≤63)
    need_W = min(63, n_rounds + 14)   # last W-slot needed is W_{n_rounds-1}
    for i in 16:need_W
        wi     = Symbol("W", i)
        get_W(j) = j < 16 ? Symbol("w", j) : Symbol("W", j)
        push!(body.args, :($wi = _sigma1($(get_W(i-2))) + $(get_W(i-7)) +
                               _sigma0($(get_W(i-15))) + $(get_W(i-16))))
    end
    # Initial state: a0..h0 = h0..h7
    push!(body.args, :(_a0 = h0; _b0 = h1; _c0 = h2; _d0 = h3;
                       _e0 = h4; _f0 = h5; _g0 = h6; _h0 = h7))
    for i in 1:n_rounds
        ap, bp, cp, dp = Symbol("_a", i-1), Symbol("_b", i-1), Symbol("_c", i-1), Symbol("_d", i-1)
        ep, fp, gp, hp = Symbol("_e", i-1), Symbol("_f", i-1), Symbol("_g", i-1), Symbol("_h", i-1)
        an, bn, cn, dn = Symbol("_a", i),   Symbol("_b", i),   Symbol("_c", i),   Symbol("_d", i)
        en, fn, gn, hn = Symbol("_e", i),   Symbol("_f", i),   Symbol("_g", i),   Symbol("_h", i)
        t1, t2 = Symbol("_t1_", i), Symbol("_t2_", i)
        w_sym = i - 1 < 16 ? Symbol("w", i-1) : Symbol("W", i-1)
        k_lit = UInt32(_SHA256_K[i])
        push!(body.args, :($t1 = $hp + _Sigma1($ep) + _ch($ep, $fp, $gp) +
                               UInt32($k_lit) + $w_sym))
        push!(body.args, :($t2 = _Sigma0($ap) + _maj($ap, $bp, $cp)))
        # State shift: new(a,b,c,d,e,f,g,h) = (t1+t2, a, b, c, d+t1, e, f, g)
        push!(body.args, :($an = $t1 + $t2))
        push!(body.args, :($bn = $ap))
        push!(body.args, :($cn = $bp))
        push!(body.args, :($dn = $cp))
        push!(body.args, :($en = $dp + $t1))
        push!(body.args, :($fn = $ep))
        push!(body.args, :($gn = $fp))
        push!(body.args, :($hn = $gp))
    end
    # Final output: add working state to H
    af, bf, cf, df = Symbol("_a", n_rounds), Symbol("_b", n_rounds), Symbol("_c", n_rounds), Symbol("_d", n_rounds)
    ef, ff, gf, hf = Symbol("_e", n_rounds), Symbol("_f", n_rounds), Symbol("_g", n_rounds), Symbol("_h", n_rounds)
    push!(body.args, :((h0 + $af, h1 + $bf, h2 + $cf, h3 + $df,
                       h4 + $ef, h5 + $ff, h6 + $gf, h7 + $hf)))
    return body
end

# Generate the 24-arg signature (h0..h7, w0..w15)
_sha256_sig = Expr(:tuple,
    (Expr(:(::), Symbol("h", i), :UInt32) for i in 0:7)...,
    (Expr(:(::), Symbol("w", i), :UInt32) for i in 0:15)...)

# Build functions for a handful of N: 2 (smoke), 8 (mid), 64 (full)
for N in (2, 8, 64)
    fname = Symbol("sha256_compress_", N)
    @eval function $fname($(_sha256_sig.args...))
        $(_sha256_body(N))
    end
end

@testset "SHA-256 full compression — reference implementation" begin
    # Test vector: "abc" — standard SHA-256 test vector
    H0 = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
          UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19))
    block_abc = (
        UInt32(0x61626380),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000018))
    expected = (
        UInt32(0xba7816bf), UInt32(0x8f01cfea), UInt32(0x414140de), UInt32(0x5dae2223),
        UInt32(0xb00361a3), UInt32(0x96177a9c), UInt32(0xb410ff61), UInt32(0xf20015ad))
    @test sha256_compress_ref(H0..., block_abc...) == expected
    # Metaprogrammed unrolled version must match reference on same vector
    @test sha256_compress_64(H0..., block_abc...) == expected
end

@testset "SHA-256 compression — 2-round smoke compile" begin
    # Smallest unit: verify Bennett compiles a 2-round compression and
    # the simulated output matches the metaprogrammed reference.
    circuit = reversible_compile(sha256_compress_2, ntuple(_ -> UInt32, 24)...)
    @test verify_reversibility(circuit)
    # Input: arbitrary but fixed
    inp = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
           UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19),
           UInt32(0x61626380), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000018))
    expected_2 = sha256_compress_2(inp...)
    result = simulate(circuit, inp)
    for i in 1:8
        @test UInt32(result[i] % UInt32) == expected_2[i]
    end
    gc = gate_count(circuit)
    println("  [2-round] total=$(gc.total)  Toffoli=$(gc.Toffoli)  wires=$(circuit.n_wires)")
end

@testset "SHA-256 compression — 8-round scaling check" begin
    t0 = time()
    circuit = reversible_compile(sha256_compress_8, ntuple(_ -> UInt32, 24)...)
    t_compile = time() - t0
    @test verify_reversibility(circuit)
    # Correctness: sha256_compress_8 reference must match simulator
    inp = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
           UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19),
           UInt32(0x61626380), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
           UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000018))
    expected_8 = sha256_compress_8(inp...)
    result = simulate(circuit, inp)
    for i in 1:8
        @test UInt32(result[i] % UInt32) == expected_8[i]
    end
    gc = gate_count(circuit)
    println("  [8-round] total=$(gc.total)  Toffoli=$(gc.Toffoli)  " *
            "wires=$(circuit.n_wires)  compile=$(round(t_compile, digits=1))s")
end

@testset "SHA-256 compression — full 64-round (BC.3)" begin
    # Full SHA-256 compression function on a 512-bit block. Uses the
    # standard "abc" test vector.
    t0 = time()
    circuit = reversible_compile(sha256_compress_64, ntuple(_ -> UInt32, 24)...)
    t_compile = time() - t0
    @test verify_reversibility(circuit)

    H0 = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
          UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19))
    block_abc = (
        UInt32(0x61626380),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
        UInt32(0x00000018))
    expected_hash = (
        UInt32(0xba7816bf), UInt32(0x8f01cfea), UInt32(0x414140de), UInt32(0x5dae2223),
        UInt32(0xb00361a3), UInt32(0x96177a9c), UInt32(0xb410ff61), UInt32(0xf20015ad))

    t0 = time()
    result = simulate(circuit, (H0..., block_abc...))
    t_sim = time() - t0
    for i in 1:8
        @test UInt32(result[i] % UInt32) == expected_hash[i]
    end

    gc = gate_count(circuit)
    t_cnt = t_count(circuit)
    acc = ancilla_count(circuit)

    println()
    println("  ===== BC.3 — Full SHA-256 compression (64 rounds, 512-bit block) =====")
    println("  Total gates:  $(gc.total)")
    println("    NOT:        $(gc.NOT)")
    println("    CNOT:       $(gc.CNOT)")
    println("    Toffoli:    $(gc.Toffoli)")
    println("  T-count:      $t_cnt")
    println("  Wires:        $(circuit.n_wires)")
    println("  Ancillae:     $acc")
    println("  Compile time: $(round(t_compile, digits=1))s")
    println("  Simulate:     $(round(t_sim, digits=2))s")
    println("  ======================================================================")
    println()
    println("  Test vector: SHA-256(\"abc\") = ba7816bf8f01cfea...  MATCHES ✓")
end
