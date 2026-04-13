#!/usr/bin/env julia
"""
BC.3 — Full SHA-256 compression function benchmark (Bennett-xy75)

Measures Bennett.jl on the full 64-round SHA-256 compression of a 512-bit
block, including the message schedule expansion (W[0..15] → W[16..63]).
Verified against the standard SHA-256("abc") test vector.

PRS15 Table II (Parent/Roetteler/Svore 2015 / 2017 CAV) reports SHA-256
per-round costs:
  * Bennett:  704 wires,   683 Toffoli
  * EAGER:    353 wires,   683 Toffoli

This benchmark scales those per-round numbers linearly to 64 rounds to
form a projected PRS15 upper bound for the full compression, and compares
both `n_wires` (total wires allocated over time — the Bennett.jl scalar)
and `peak_live_wires` (transient qubit count — the quantum-relevant scalar).

Usage: julia --project=. benchmark/bc5_sha256_full.jl
"""

using Bennett
using Bennett: verify_reversibility, gate_count, ancilla_count, t_count,
               t_depth, peak_live_wires, reversible_compile, simulate,
               extract_parsed_ir, lower, bennett, value_eager_bennett,
               checkpoint_bennett, pebbled_group_bennett, min_pebbles

# ---- SHA-256 reference + metaprogrammed compilation-friendly form ----

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
Metaprogram a straight-line SHA-256 compression function body with
`n_rounds` unrolled. Message schedule extension lines for W16..W_{n_rounds-1+15}
(clamped to W63) + `n_rounds` round updates with K baked as literals.
"""
function _sha256_body(n_rounds::Int)
    body = Expr(:block)
    need_W = min(63, n_rounds + 14)
    get_W(j) = j < 16 ? Symbol("w", j) : Symbol("W", j)
    for i in 16:need_W
        wi = Symbol("W", i)
        push!(body.args, :($wi = _sigma1($(get_W(i-2))) + $(get_W(i-7)) +
                               _sigma0($(get_W(i-15))) + $(get_W(i-16))))
    end
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
        push!(body.args, :($an = $t1 + $t2))
        push!(body.args, :($bn = $ap))
        push!(body.args, :($cn = $bp))
        push!(body.args, :($dn = $cp))
        push!(body.args, :($en = $dp + $t1))
        push!(body.args, :($fn = $ep))
        push!(body.args, :($gn = $fp))
        push!(body.args, :($hn = $gp))
    end
    af, bf, cf, df = Symbol("_a", n_rounds), Symbol("_b", n_rounds), Symbol("_c", n_rounds), Symbol("_d", n_rounds)
    ef, ff, gf, hf = Symbol("_e", n_rounds), Symbol("_f", n_rounds), Symbol("_g", n_rounds), Symbol("_h", n_rounds)
    push!(body.args, :((h0 + $af, h1 + $bf, h2 + $cf, h3 + $df,
                       h4 + $ef, h5 + $ff, h6 + $gf, h7 + $hf)))
    return body
end

_sig = Expr(:tuple,
    (Expr(:(::), Symbol("h", i), :UInt32) for i in 0:7)...,
    (Expr(:(::), Symbol("w", i), :UInt32) for i in 0:15)...)

@eval function sha256_compress_full($(_sig.args...))
    $(_sha256_body(64))
end

# ---- the benchmark ----

println("=" ^ 72)
println("BC.3 — Full SHA-256 compression benchmark (Bennett-xy75)")
println("=" ^ 72)

println("\n[extract + lower]")
Bennett._reset_names!()
t0 = time()
parsed = extract_parsed_ir(sha256_compress_full, Tuple{ntuple(_->UInt32,24)...})
lr = lower(parsed)
t_extract = time() - t0
println("  blocks=$(length(parsed.blocks))  gate_groups=$(length(lr.gate_groups))  " *
        "extract+lower=$(round(t_extract, digits=2))s")

println("\n[Bennett construction variants]")

function measure(label::String, circuit_builder::Function)
    t0 = time()
    c = circuit_builder()
    t_bennett = time() - t0
    gc = gate_count(c)
    tc = t_count(c)
    ac = ancilla_count(c)
    pk = peak_live_wires(c)
    tw = c.n_wires
    println("  $label")
    println("    gates=$(gc.total) (NOT=$(gc.NOT) CNOT=$(gc.CNOT) Toff=$(gc.Toffoli))")
    println("    T-count=$tc  T-depth=$(t_depth(c))")
    println("    peak_live=$pk  n_wires=$tw  ancillae=$ac")
    println("    bennett=$(round(t_bennett, digits=2))s")
    return (name=label, gates=gc.total, toffoli=gc.Toffoli, peak=pk,
            wires=tw, ancillae=ac, t_count=tc, circuit=c)
end

results = []
push!(results, measure("Full Bennett (baseline)", () -> bennett(lr)))
push!(results, measure("value_eager_bennett",     () -> value_eager_bennett(lr)))
push!(results, measure("checkpoint_bennett",      () -> checkpoint_bennett(lr)))

# Pebbled: try a representative pebble count
ngrp = length(lr.gate_groups)
mp = min_pebbles(ngrp)
push!(results, measure("pebbled_group(s=$mp, min)", () -> pebbled_group_bennett(lr; max_pebbles=mp)))
push!(results, measure("pebbled_group(s=50)",       () -> pebbled_group_bennett(lr; max_pebbles=50)))

# ---- verification against SHA-256("abc") test vector ----

println("\n[correctness — SHA-256(\"abc\")]")
best = first(results)  # any variant works for correctness
H0 = (UInt32(0x6a09e667), UInt32(0xbb67ae85), UInt32(0x3c6ef372), UInt32(0xa54ff53a),
      UInt32(0x510e527f), UInt32(0x9b05688c), UInt32(0x1f83d9ab), UInt32(0x5be0cd19))
block_abc = (
    UInt32(0x61626380),  # 'a','b','c', 0x80
    UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
    UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
    UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
    UInt32(0x00000000), UInt32(0x00000000), UInt32(0x00000000),
    UInt32(0x00000018))  # bit length = 24
expected = (
    UInt32(0xba7816bf), UInt32(0x8f01cfea), UInt32(0x414140de), UInt32(0x5dae2223),
    UInt32(0xb00361a3), UInt32(0x96177a9c), UInt32(0xb410ff61), UInt32(0xf20015ad))

result = simulate(best.circuit, (H0..., block_abc...))
ok = all(UInt32(result[i] % UInt32) == expected[i] for i in 1:8)
println("  Test vector matches: ", ok ? "✓" : "✗  FAIL")
println("  Reversibility:       ", verify_reversibility(best.circuit) ? "✓" : "✗  FAIL")

# ---- comparison to PRS15 Table II ----

println("\n[comparison to PRS15 Table II]")
println("  PRS15 Table II reports per-round SHA-256 costs:")
println("    Bennett: 704 wires,  683 Toffoli")
println("    EAGER:   353 wires,  683 Toffoli")
println()
println("  Linear-scaled 64-round projections (upper bounds — actual")
println("  numbers likely lower due to in-place reuse across rounds):")
println("    PRS15 Bennett × 64: 45,056 wires, ~43,712 Toffoli")
println("    PRS15 EAGER   × 64: 22,592 wires, ~43,712 Toffoli")
println()
println("  Bennett.jl best variant (by peak_live_wires):")
best_peak = argmin(r -> r.peak, results)
println("    $(best_peak.name)")
println("    peak_live: $(best_peak.peak)")
println("    n_wires:   $(best_peak.wires)")
println("    Toffoli:   $(best_peak.toffoli)")
println()
println("  Ratios:")
println("    peak_live / PRS15 Bennett (proj): $(round(best_peak.peak / 45056, digits=2))×")
println("    peak_live / PRS15 EAGER (proj):   $(round(best_peak.peak / 22592, digits=2))×")
println("    n_wires   / PRS15 Bennett (proj): $(round(best_peak.wires / 45056, digits=2))×")
println("    Toffoli   / PRS15 (proj):         $(round(best_peak.toffoli / 43712, digits=2))×")
println()
println("=" ^ 72)
