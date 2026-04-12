#!/usr/bin/env julia
"""
BC.1 — Cuccaro 32-bit adder benchmark vs ReVerC Table 1

ReVerC (Parent/Roetteler/Svore 2017 CAV, Table 1) reports:
  Cuccaro 32-bit adder: 32 Toffoli gates, 65 qubits

This benchmark measures what Bennett.jl produces for the equivalent Julia
program `f(a::UInt32, b::UInt32) = a + b`, under several lowering strategies:

  * Ripple-carry (default) — straightforward O(W) Toffoli, more ancillae
  * Cuccaro in-place (use_inplace=true) — activates when one operand is dead

The goal is to identify the best we currently achieve and document the gap
to ReVerC's claim.
"""

using Bennett
using Bennett: verify_reversibility, gate_count, ancilla_count, t_count

function measure(label::String, lr_builder::Function)
    lr = lr_builder()
    c = Bennett.bennett(lr)
    gc = gate_count(c)
    tc = t_count(c)
    ac = ancilla_count(c)
    ok = verify_reversibility(c)
    println("[$label] total=$(gc.total)  NOT=$(gc.NOT)  CNOT=$(gc.CNOT)  " *
            "Toffoli=$(gc.Toffoli)  T-count=$(tc)  wires=$(c.n_wires)  " *
            "ancillae=$(ac)  reversible=$(ok)")
    return (total=gc.total, toffoli=gc.Toffoli, wires=c.n_wires, ancillae=ac, reversible=ok)
end

println("=" ^ 72)
println("BC.1 — Cuccaro 32-bit adder benchmark vs ReVerC")
println("=" ^ 72)

println("\nBaseline: f(a::UInt32, b::UInt32) = a + b")

f_twoarg(a::UInt32, b::UInt32) = a + b
parsed_twoarg = Bennett.extract_parsed_ir(f_twoarg, Tuple{UInt32, UInt32})

r_rc_2arg = measure("i32 a+b ripple-carry", () ->
    Bennett.lower(parsed_twoarg; use_inplace=false))

r_cuc_2arg = measure("i32 a+b default (use_inplace=true)", () ->
    Bennett.lower(parsed_twoarg))

println("\nSingle-operand: f(x::UInt32) = x + UInt32(1)")

f_oneop(x::UInt32) = x + UInt32(1)
parsed_oneop = Bennett.extract_parsed_ir(f_oneop, Tuple{UInt32})

r_rc_1arg = measure("i32 x+1 ripple-carry", () ->
    Bennett.lower(parsed_oneop; use_inplace=false))

r_cuc_1arg = measure("i32 x+1 default (use_inplace=true)", () ->
    Bennett.lower(parsed_oneop))

println("\n", "=" ^ 72)
println("Comparison vs ReVerC Table 1 (Cuccaro 32-bit: 32 Toffoli / 65 qubits)")
println("=" ^ 72)

println("\nBest Bennett.jl result (Toffoli):")
println("  a+b  ripple-carry: $(r_rc_2arg.toffoli) Toffoli  / $(r_rc_2arg.wires) wires")
println("  a+b  default:      $(r_cuc_2arg.toffoli) Toffoli  / $(r_cuc_2arg.wires) wires")
println("  x+1  ripple-carry: $(r_rc_1arg.toffoli) Toffoli  / $(r_rc_1arg.wires) wires")
println("  x+1  default:      $(r_cuc_1arg.toffoli) Toffoli  / $(r_cuc_1arg.wires) wires")
println("  ReVerC reported:   32 Toffoli  / 65 wires")

println("""

Notes:
  * Our ripple-carry uses 2W carry wires; Cuccaro uses 1 ancilla but needs
    one operand to be dead (live analysis). For f(a,b)=a+b the liveness is
    unclear to the current dispatcher — both operands remain reachable as
    function arguments until ret.
  * ReVerC's claimed 32 Toffoli for a 32-bit Cuccaro is well below the
    published formula (2n = 64). The discrepancy may be a paper typo or
    different gate counting convention; left as a methodology-comparison
    note for the head-to-head paper.
""")
