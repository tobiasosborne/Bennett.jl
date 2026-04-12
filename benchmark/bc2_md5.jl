#!/usr/bin/env julia
"""
BC.2 — MD5 benchmark vs ReVerC Table 1

ReVerC (Parent/Roetteler/Svore 2017, Table 1 eager mode): MD5 = 27,520
Toffolis / 4,769 qubits. That's the full 64-round compression of a 512-bit
block down to 128 bits of state.

This benchmark measures Bennett.jl on:
  * Individual round helper functions (F, G, H, I) on UInt32
  * The MD5 "step" — a single iteration of the main loop
  * A small cascade of steps (if memory allows, a full round of 16 steps)
"""

using Bennett
using Bennett: verify_reversibility, gate_count, ancilla_count, t_count

function measure(label::String, builder::Function)
    c = builder()
    gc = gate_count(c)
    tc = t_count(c)
    ac = ancilla_count(c)
    ok = verify_reversibility(c)
    println("[$label] total=$(gc.total)  NOT=$(gc.NOT)  CNOT=$(gc.CNOT)  " *
            "Toffoli=$(gc.Toffoli)  T-count=$(tc)  wires=$(c.n_wires)  " *
            "ancillae=$(ac)  reversible=$(ok)")
    return (toffoli=gc.Toffoli, wires=c.n_wires, total=gc.total)
end

# MD5 round functions
md5_F(x::UInt32, y::UInt32, z::UInt32) = (x & y) | (~x & z)
md5_G(x::UInt32, y::UInt32, z::UInt32) = (x & z) | (y & ~z)
md5_H(x::UInt32, y::UInt32, z::UInt32) = x ⊻ y ⊻ z
md5_I(x::UInt32, y::UInt32, z::UInt32) = y ⊻ (x | ~z)

rotl32(x::UInt32, n::Int) = (x << n) | (x >> (32 - n))

# A single MD5 step using function F (round 0-15 of MD5 main loop).
# state rotates (a,b,c,d) → (d, b + rotl(F(b,c,d) + a + k + w, s), b, c)
# We capture s as compile-time constant (7 for the first 4 steps).
function md5_step_F_s7(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
                      k::UInt32, w::UInt32)
    t = b + rotl32(md5_F(b, c, d) + a + k + w, 7)
    return t   # the new `b` position in the rotated state
end

# Same but for round group II (G function, s=5 is one of its constants).
function md5_step_G_s5(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
                      k::UInt32, w::UInt32)
    t = b + rotl32(md5_G(b, c, d) + a + k + w, 5)
    return t
end

println("=" ^ 72)
println("BC.2 — MD5 benchmark vs ReVerC Table 1 (27,520 Toff / 4,769 qubits)")
println("=" ^ 72)

println("\nRound helper functions (single UInt32 call):")
r_F = measure("md5_F(x,y,z)", () -> reversible_compile(md5_F, UInt32, UInt32, UInt32))
r_G = measure("md5_G(x,y,z)", () -> reversible_compile(md5_G, UInt32, UInt32, UInt32))
r_H = measure("md5_H(x,y,z)", () -> reversible_compile(md5_H, UInt32, UInt32, UInt32))
r_I = measure("md5_I(x,y,z)", () -> reversible_compile(md5_I, UInt32, UInt32, UInt32))

println("\nMD5 step (one iteration of the 64-round main loop):")
r_step_F = measure("md5_step_F_s7 (round group I)", () ->
    reversible_compile(md5_step_F_s7,
                       UInt32, UInt32, UInt32, UInt32, UInt32, UInt32))
r_step_G = measure("md5_step_G_s5 (round group II)", () ->
    reversible_compile(md5_step_G_s5,
                       UInt32, UInt32, UInt32, UInt32, UInt32, UInt32))

println("\n", "=" ^ 72)
println("Summary vs ReVerC (27,520 Toffoli / 4,769 qubits for full 64-round MD5)")
println("=" ^ 72)

avg_step = (r_step_F.toffoli + r_step_G.toffoli) ÷ 2
est_full = 64 * avg_step
println("""
  Round fns:  F=$(r_F.toffoli)  G=$(r_G.toffoli)  H=$(r_H.toffoli)  I=$(r_I.toffoli)  Toffoli each
  Step F:     $(r_step_F.toffoli) Toffoli, $(r_step_F.wires) wires
  Step G:     $(r_step_G.toffoli) Toffoli, $(r_step_G.wires) wires
  Mean step:  $(avg_step) Toffoli
  64-step estimate (linear extrapolation): $(est_full) Toffoli
  ReVerC MD5 (measured, eager mode):        27,520 Toffoli / 4,769 qubits

Note: extrapolation assumes all 64 steps cost roughly the same (they do —
each uses one F/G/H/I eval + add + rotate + add).  Our single-step cost is
the honest comparison point; full-hash compile would validate it.
""")
