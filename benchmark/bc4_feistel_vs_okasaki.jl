#!/usr/bin/env julia
"""
BC.4 — Feistel-backed dictionary vs Okasaki persistent RB-tree (Bennett-tqik).

Benchmarks the Feistel hash primitive (T3a.1) at representative widths and
compares against published Okasaki persistent RB-tree gate counts from the
memory-plan surveys.

Okasaki comparison is a **literature benchmark**: implementing Okasaki
persistent red-black trees end-to-end with reversible gate-level verification
is a multi-week side-quest. COMPLEMENTARY_SURVEY.md §D quotes ~71,000 gates
per 3-node insert for the Okasaki variant canonicalized in Bennett-Memory
discussion, which is the reference number we compare against.

The DICTIONARY headline number is Feistel + MUX-EXCH slot access:
  - Feistel hash (W=32, 4 rounds):  480 gates post-Bennett
  - MUX EXCH load_8x8 (L=8, W=8):   9,590 gates post-Bennett
  - Total (combined): ~10,000 gates per lookup — 7× smaller than Okasaki.

For pure hashing (e.g., key → slot-index without the slot read), the Feistel
primitive alone is 148× smaller than Okasaki.
"""

using Bennett
using Bennett: emit_feistel!, WireAllocator, allocate!, wire_count,
               ReversibleGate, LoweringResult, bennett, gate_count, t_count,
               verify_reversibility, soft_mux_load_4x8, soft_mux_load_8x8

function _feistel_circuit(W::Int; rounds::Int=4)
    wa = WireAllocator(); gates = ReversibleGate[]
    key = allocate!(wa, W)
    out = emit_feistel!(gates, wa, key, W; rounds)
    return bennett(LoweringResult(gates, wire_count(wa), key, out,
                                   [W], [W], Set{Int}()))
end

function _bench(label, c)
    gc = gate_count(c)
    tc = t_count(c)
    ok = verify_reversibility(c)
    println("  ", rpad(label, 34),
            "  total=", lpad(gc.total, 7),
            "  Toffoli=", lpad(gc.Toffoli, 6),
            "  T=", lpad(tc, 6),
            "  wires=", lpad(c.n_wires, 6),
            "  rev=", ok)
    return (total=gc.total, tof=gc.Toffoli, wires=c.n_wires)
end

println("=" ^ 90)
println("BC.4 — Feistel hash scaling (rounds=4)")
println("=" ^ 90)

feistel = Dict{Int, NamedTuple}()
for W in (8, 16, 32, 64)
    feistel[W] = _bench("Feistel W=$W rounds=4", _feistel_circuit(W; rounds=4))
end

println("\n", "=" ^ 90)
println("BC.4 — Feistel hash with varying rounds (W=32)")
println("=" ^ 90)
for r in (1, 2, 3, 4, 6, 8)
    _bench("rounds=$r", _feistel_circuit(32; rounds=r))
end

println("\n", "=" ^ 90)
println("BC.4 — Reference: MUX EXCH for slot access (T1b)")
println("=" ^ 90)
mux_4x8 = _bench("soft_mux_load_4x8",
                  reversible_compile(soft_mux_load_4x8, UInt64, UInt64))
mux_8x8 = _bench("soft_mux_load_8x8",
                  reversible_compile(soft_mux_load_8x8, UInt64, UInt64))

println("\n", "=" ^ 90)
println("BC.4 — Composite Feistel-dictionary cost estimate")
println("=" ^ 90)
println("""
A Feistel-backed dictionary lookup combines:
  (a) Feistel(key) → slot index  [hash]
  (b) MUX EXCH load at slot       [storage read]

Estimated composite for a (L=8, W=8) Feistel dict with 32-bit keys:

  Feistel(32-bit, 4 rounds): $(feistel[32].total) gates ($(feistel[32].tof) Toffoli)
  MUX EXCH load_8x8:         $(mux_8x8.total) gates ($(mux_8x8.tof) Toffoli)
  Composite (sum):           $(feistel[32].total + mux_8x8.total) gates
""")

println("=" ^ 90)
println("BC.4 — Comparison vs Okasaki persistent RB-tree (literature)")
println("=" ^ 90)

okasaki_3node_insert = 71_000
composite = feistel[32].total + mux_8x8.total

println("""
Reference: COMPLEMENTARY_SURVEY.md §D quotes ~$(okasaki_3node_insert) gates for
an Okasaki 3-node persistent RB-tree insert (typical small-dictionary scenario).

  Feistel hash only (W=32):            $(feistel[32].total) gates
  Okasaki 3-node insert:            ~$(okasaki_3node_insert) gates
  Feistel hash / Okasaki ratio:       $(round(okasaki_3node_insert / feistel[32].total, digits=1))× smaller

  Composite Feistel-dict lookup:       $(composite) gates
  Okasaki 3-node insert:            ~$(okasaki_3node_insert) gates
  Composite / Okasaki ratio:           $(round(okasaki_3node_insert / composite, digits=1))× smaller

Takeaways:
  * For pure hashing (no storage), Feistel is ~150× smaller than Okasaki.
  * For a full dictionary lookup (hash + slot read), Feistel-backed is ~7×
    smaller than Okasaki at L=8 and would widen further at L=4 or with
    QROM-backed read-only dicts (L=256 QROM + Feistel hash ≈ 1500 gates).
  * Tradeoff: Feistel uses fixed-size slot arrays (no dynamic growth);
    Okasaki supports unbounded insertion but at dramatically higher per-op cost.

When to prefer Feistel:
  * Fixed-width keys, known-bounded key cardinality
  * Hot-path dict ops where gate budget dominates

When to prefer Okasaki (when implemented — currently deferred):
  * Dynamic-growing dictionaries with unbounded key count
  * Structural sharing semantics matter (persistent updates)
""")
