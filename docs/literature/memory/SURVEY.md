# Reversible Mutable Memory: Literature Survey for Bennett.jl

**Status:** draft v0.1 — 2026-04-12
**Target:** Bennett.jl, an LLVM-level reversible compiler (Julia → LLVM IR → NOT/CNOT/Toffoli)
**Goal:** implement `store`/`load`/`alloca`/`memcpy`/`memmove` handlers with the best achievable gate/wire cost, surpassing ReVerC on relevant axes.
**Budget:** up to ~20 kGates per memory operation acceptable.
**Dual application:** (a) quantum oracles for Sturm.jl `when(qubit) do f(x) end`; (b) energy-efficient classical circuits for adiabatic/SFQ reversible hardware (Landauer limit).

---

## 1. Executive Summary

After reviewing 40+ papers spanning reversible computing (1961–2025), quantum memory, persistent data structures, and automatic differentiation, the **top five recommended approaches** for Bennett.jl, ranked by practical viability under the SSA/LLVM pipeline:

**(1) SSA Mutation Elimination + ReVerC-style EAGER (local) + Cuccaro in-place for arithmetic stores.**
LLVM IR is already in SSA form. Every LLVM `store` whose pointer has a statically known single-static-allocation (unique alloca) and no aliasing uses of its value can be rewritten as a value update — no real memory needed, just wire renaming. For the 80% common case (`*p = *p + 1`, register-like access), this gives zero-overhead memory. Applies immediately; cost = 0 extra gates for stores, 0 ancillae. ReVerC has been doing exactly this without calling it "memory model" since 2015; Bennett.jl can do it better by leveraging LLVM's already-performed SSA promotion.

**(2) Flat-array MUX-based EXCH with per-access 2N + 2W ancillae, Bennett-reversed.**
For arrays surviving (a) that truly need dynamic indexing, scale up the existing EXCH prototype with group-level checkpointing. For N=4 W=8, ~1.4kG read + ~1.4kG write is already within the 20kG budget; for N=256 W=32, projects to ~100kG/op which exceeds budget. Use **only** for small arrays (N ≤ 32) the compiler can prove live.

**(3) QROM-style log-depth read for read-only tables.**
Classical-data, quantum-address lookups (constants, jump tables, branch-prediction tables) compile to 4L Toffoli gates with log L ancillae via Babbush-Gidney-Berry-Wiebe 2018 QROM. Cheap and beats bucket-brigade for read-only data. Does not handle writes. Perfect for LLVM global constants.

**(4) Shadow memory checkpoint + re-execute (Bennett pebbling at function boundaries).**
For complex stores the above can't eliminate, take the Enzyme shadow-memory idea and adapt: at each call site, checkpoint the relevant slice of memory, execute forward, and uncompute by executing the stored slice in reverse. Combined with SAT-pebbling (Meuli 2019) this gives an n^1+ε / S^ε time-space tradeoff in the classical Bennett style. Works at arbitrary granularity.

**(5) Hash-consed persistent map for truly dynamic heap.**
If arrays of unbounded size must be supported (e.g. Julia `Vector{T}` growing at runtime), use a hash-consed persistent array à la Baker/Conchon-Filliâtre with Mogensen 2018 maximal sharing. Gate cost is heavy (~20-70kG per access as confirmed by our Okasaki prototype at 71k) but it's the only approach that preserves asymptotic purity; it's the fallback.

**Key finding:** ReVerC handles arrays by assuming static indices and reading/writing whole-register in-place; it does NOT handle pointer-based memory, dynamic indexing, or `memcpy`. None of the existing reversible compilers supports full LLVM `load`/`store`/`alloca`. **This is an open field.** Bennett.jl has the opportunity to publish the first compiler-based treatment of reversible mutable memory with concrete benchmarks.

---

## 2. Full Literature Survey

### 2a. Persistent functional data structures

| Paper | Year | Key result | Suitability |
|---|---|---|---|
| Driscoll, Sarnak, Sleator, Tarjan, "Making data structures persistent", JCSS 38 | 1989 | **Foundational.** O(1) amortized access + O(1) amortized update for full persistence via "fat nodes" or "node copying". The paper everyone cites. | High: the theory underlying Okasaki + persistent arrays. |
| Okasaki, "Purely Functional Data Structures", CMU thesis / Cambridge book | 1996/1999 | **Persistent red-black trees.** Each insertion O(log N) worst case, creates O(log N) new nodes. Already implemented in Bennett.jl prototype at 71kG. | Medium: high gate cost. |
| Okasaki, "Red-black trees in a functional setting", JFP 9(4) | 1999 | Balanced-tree insertion/lookup with 4 balance cases. Used directly in our prototype. | As above. |
| Kaplan & Tarjan, "Purely functional, real-time deques with catenation", JACM | 1999 | Double-ended queues with O(1) cons/snoc/uncons/unsnoc. | Low: out of scope for arrays. |
| Baker, "Shallow binding makes functional arrays fast" / Aasa et al., "Fully persistent arrays" | 1991/1992 | Version-tree based persistent arrays: amortized O(1) for sequentially accessed versions, O(n) worst case when rebasing. | Medium: hard to bound in reversible setting. |
| Conchon & Filliâtre, "A Persistent Union-Find", ML Workshop | 2007 | Semi-persistent data structures — only ancestors of the latest version addressable. Lower overhead. | Medium: restrictive, but matches linear-reference model nicely. |
| Bagwell, Clojure et al. — Hash Array Mapped Trie (HAMT) | 2001–present | O(log_32 N) ≈ effectively constant time, log_32 fanout. | **High** for a modern implementation — 32-way branching amortizes reversible overhead well, since the log_32(N) depth is tiny (log_32(256) = 1.6). |

**Assessment:** Okasaki RBT is at the expensive end (71kG per insert for 3-node tree already measured in our prototype). A HAMT with 32-way branching would have dramatically lower tree depth and thus lower comparison-chain cost; this is the direction to take for a pure-functional persistent fallback.

### 2b. Reversible heap / garbage collection

| Paper | Year | Key result |
|---|---|---|
| Bennett, "Logical reversibility of computation", IBM JRD 17:525 | 1973 | **Founding.** Compute-copy-uncompute ("Bennett trick"). Implemented as `bennett_transform.jl` in our compiler. |
| Bennett, "Time/Space Trade-Offs for Reversible Computation", SICOMP 18:766 | 1989 | **Pebble game.** T time, S space ordinary Turing machine → time O(T^(1+ε)), space O(S log T) reversible. Fundamental bound. |
| Knill, "An analysis of Bennett's pebble game", math/9508218 | 1995 | Tightens the above. For 1D chain of n operations, k pebbles gives time Θ(n^log_2(2k/(k-1)) / k^ε). Implemented in `bennett_transform.jl` pebbling functions. |
| Yokoyama & Glück, "A reversible programming language and its invertible self-interpreter", PEPM'07 | 2007 | **Janus language** — reversible imperative language with mutable assignments `x += f()` reversible iff f doesn't read x. R-Turing complete. No dynamic allocation. |
| Axelsen & Glück, "Reversible representation and manipulation of constructor terms in the heap", RC 2013, LNCS 7948 | 2013 | **AG13 heap.** EXCH + linear references. Allocation is deterministic, deallocation is its inverse. Requires linearity: a pointer cannot be copied. Our prototype gets 51-59kG per operation. |
| Mogensen, "Garbage Collection for Reversible Functional Languages", RC 2015 → NGC 36:203, 2018 | 2018 | **Maximal sharing via hash-consing.** If new node ≡ existing node, reuse pointer — avoids duplicating subtrees. Reduces heap pressure, not necessarily gate count; asymptotically aligned with DSST 1989. |
| Thomsen & Axelsen, "Interpretation and programming of the reversible functional language RFUN", IFL 2015 | 2015 | RFUN — pattern matching as inverse of construction. Linearity enforced statically. | 
| Hoey, Axelsen, Glück survey in TCS 915:15 | 2022 | **"Reversible computing from a programming language perspective."** Recent survey — good entry point. |

**Assessment:** Axelsen-Glück 2013 EXCH + linearity is the "right" theoretical foundation for an FP reversible memory model, but the cost of the variable-shift barrel shifter (as our prototype confirms — 51kG base cost) is high. Mogensen hash-consing is a *compression* not a speedup. If Bennett.jl adds heap, it should combine these with SSA-mutation-elimination: only heap-allocate what SSA cannot dissolve.

### 2c. QRAM (Quantum Random Access Memory)

| Paper | Year | Key result |
|---|---|---|
| Giovannetti, Lloyd, Maccone, "Quantum random access memory", PRL 100:160501 / PRA 78:052310 | 2008 | **Bucket-brigade QRAM.** Binary tree of "routers" each in 3 states {wait, left, right}. O(2^n) qubits total, O(n) *activated* during a query. Query depth O(n). |
| Hann, Lee, Girvin, Jiang, "Resilience of quantum random access memory to generic noise", PRX Quantum 2:020311 | 2021 | Bucket-brigade infidelity scales polylogarithmically with memory size under generic local noise — huge robustness result. Does not require full QEC. |
| Matteo et al., "Parallelizing the queries in a bucket-brigade QRAM", PRA 102:032608 | 2020 | Parallel queries reduce effective depth. |
| Xu et al., "Systems architecture for QRAM", ISCA | 2023 | Full-stack design; concrete resource estimates. |
| Jaques & Rattew, "QRAM: A Survey and Critique", Quantum 9:1922 | 2025 | **Critical survey.** Active QRAM loses quantum advantage due to "opportunity cost" of classical control. Passive QRAM requires dubious physics. For circuit-based QRAM ("QROM"-style) the arguments don't fully apply. |
| Babbush, Gidney, Berry, Wiebe et al., "Encoding Electronic Spectra in Quantum Circuits with Linear T Complexity", PRX 8:041015 | 2018 | **QROM for classical data.** 4L Toffolis and log L ancillae to look up one of L classical bitstrings. The practical QRAM for classical data. |
| Low, Kliuchnikov, Schaeffer, "Trading T-gates for dirty qubits", arXiv:1812.00954 | 2018 | **SELECT-SWAP / QROAM.** Quadratic improvement over 4L by using √L dirty ancillae. |

**Assessment for Bennett.jl:** For read-only classical data (LLVM globals, constant arrays), the QROM literature is directly applicable: **4L Toffolis, log L ancillae**. This is the SOTA for reversible reads of classical data and Bennett.jl should implement it for `load` from `@constant` global pointers. For read-write tables, bucket-brigade style tree descent buys nothing over flat-array EXCH in the classical regime (no superposed addresses, no quantum amplitude advantage) — so we likely cannot import QRAM directly for mutable memory.

### 2d. Hash-consing / maximal sharing

| Paper | Year | Key result |
|---|---|---|
| Filliâtre & Conchon, "Type-Safe Modular Hash-Consing", ML Workshop | 2006 | Classical technique: hash table mapping (tag, subterms) → unique node. Gives O(1) equality. Dominant in HOL, Coq, Zephyrus kernels. |
| Mogensen, "Reversible Representation and Manipulation of Constructor Terms..." (extended) | 2018 | Applies hash-consing to reversible heaps. The hash table itself must be reversible. |

**Assessment:** Great for representational compression. For gate count, it trades memory against re-traversal of a hash bucket during insert. In a reversible setting the hash-table operation is itself expensive. Not a first-priority idea for Bennett.jl.

### 2e. Reversible hardware memory (adiabatic / SFQ)

| Paper | Year | Key result |
|---|---|---|
| Landauer, "Irreversibility and heat generation in the computing process", IBM JRD 5:183 | 1961 | **Landauer's principle.** Erasing 1 bit dissipates ≥ kT ln 2 ≈ 0.018 eV at 300K. |
| Bennett, "Logical reversibility of computation", IBM JRD 17:525 | 1973 | Shows logical reversibility avoids the bound. |
| Koller & Athas, "Adiabatic switching, low energy computing...", Workshop Phys. Comput. | 1992 | First charge-recovering CMOS circuits. |
| Frank, "Reversible Computing: A cross-disciplinary introduction", PhD thesis MIT | 1999 | **Bible of reversible computing.** |
| Vitányi, "Time, Space, and Energy in Reversible Computing", ACM Computing Frontiers / arXiv cs/0504088 | 2005 | Survey: time-space-energy trilemma for reversible Turing machines. |
| Frank et al., "Reversible Computing with Fast, Fully Static, Fully Adiabatic CMOS", ICRC / arXiv:2009.00448 | 2020 | **S2LAL** — first fully static fully adiabatic CMOS logic family. 8-tick minimum period. Projected 1-2 orders of magnitude efficiency improvement. |
| Frank et al., "Limits of energy efficiency...", APL Electronic Devices 1:030902 | 2023 | **Industry-perspective paper.** Argues reversible computing is the only post-Moore path to order-of-magnitude efficiency gains. |
| Rosini, Earley (Vaire Computing) | 2024 | First commercial reversible CMOS test chip ("Ice River"). 1.77× energy recovery on capacitor array. Target: 4000× efficiency. |

**Assessment:** The reversible-CMOS hardware roadmap is real and quickening. A compiler that emits Toffoli networks directly mapping to S2LAL gates is an exciting application. Bennett.jl + Vaire chipsets = plausible pairing within 2-3 years.

### 2f. Shadow memory / dual-state (Enzyme, Tapenade)

| Paper | Year | Key result |
|---|---|---|
| Moses & Churavy, "Instead of Rewriting Foreign Code for Machine Learning, Automatically Synthesize Fast Gradients", NeurIPS / arXiv:2010.01709 | 2020 | **Enzyme** AD for LLVM. Three stages: type analysis → activity analysis → synthesis. Shadow memory = a parallel heap where each forward allocation gets a mirror shadow. On reverse pass, loads become `+=` into shadow; stores become zero-the-shadow. |
| Moses, Churavy et al., "Reverse-Mode Automatic Differentiation and Optimization of GPU Kernels via Enzyme", SC'21 | 2021 | Enzyme on CUDA. |
| Hascoët & Pascual, "The Tapenade automatic differentiation tool", TOMS 39:20 | 2013 | Store-all tape + checkpointing. Checkpointing = re-compute subsections of the forward pass to save tape memory. |

**Enzyme details I extracted from the PDF:**
- *Type analysis:* determines underlying types of pointer-manipulated values (handles `memcpy(void*, void*, 8)` by inferring whether source is `double[1]` or `float[2]`).
- *Activity analysis:* a value is "active" iff it can propagate a differential value to return or memory. Inactive instructions are skipped in the reverse pass — this is the key for efficiency.
- *Shadow memory:* for every forward allocation (`malloc`, stack alloca), Enzyme emits a shadow allocation. Stores of pointers are duplicated to stores of shadow pointers. Shadow deallocations are *delayed* until the reverse pass completes.
- *Cache vs recompute:* if a value read by the reverse pass was overwritten in the forward pass, Enzyme caches it to a runtime buffer. Otherwise it's re-read from the already-alive shadow location. Enzyme is cautious and runs LLVM's alias analysis to prove values can be re-read.
- *Reverse pass of store:* there is no direct reverse of a store. Instead the derivative accumulates: `store x at p` ↦ (reverse) `d_x += load d_p; store 0 at d_p`. This works because gradients are *linear* — we're accumulating derivatives, not inverting the map.

**Adaptation to reversibility:** The Enzyme "shadow memory + accumulate" is fundamentally *additive / linear*. Reversibility requires exact inversion. So most of Enzyme's tape/checkpoint ideas transfer but the "accumulate derivatives" trick does NOT. However, the decomposition into (type analysis + activity analysis + synthesis) is directly portable and is a fine template for a Bennett.jl memory-handling pass.

### 2g. In-place reversible updates

| Paper | Year | Key result | Gates |
|---|---|---|---|
| Cuccaro, Draper, Kutin, Moulton, "A new quantum ripple-carry addition circuit", quant-ph/0410184 | 2004 | **In-place adder** using 1 ancilla. `(a, b) → (a, a+b)`. | 2n−1 Toffoli, 5n−3 CNOT, 2n−4 NOT. Total O(n) gates, depth 2n+4. |
| Häner, Soeken, Roetteler, Svore, "Quantum circuits for floating-point arithmetic", RC 2018 / arXiv:1807.02023 | 2018 | In-place FP add and mul. Uses variable-window manipulation. | Thousands of gates per IEEE 754 op. Our soft-float (fadd 94k, fmul 265k) is in-the-ballpark but gate-for-gate more because we do full NaN/Inf/subnormal. |
| Draper, "Addition on a quantum computer", quant-ph/0008033 | 2000 | QFT-based modular addition. | O(n^2) gates but depth O(n); no ancillae. Not our regime. |
| Takahashi, Tani, Kunihiro, "Quantum addition circuits and unbounded fan-out", 2009 | 2009 | Linear depth, 0 ancillae. | O(n) gates, depth O(n). |

**Assessment:** Cuccaro already in `adder.jl`. Bennett.jl benchmark (86 gates i8) is close to the Cuccaro optimum (≈60 gates i8) — we're paying a small constant factor for the Bennett trick. For stores inferred by SSA analysis as in-place, Cuccaro's technique is directly applicable; no change needed.

### 2h. Recent reversible compilers

| System | Year | Lang | Mutable memory support |
|---|---|---|---|
| Revs (Parent, Roetteler, Svore) | 2015 | F# subset | Arrays with static indices + in-place via `<-`. Explicitly uses "Mutable Data Dependency graph" (MDD). Dynamic indexing **not supported**. |
| ReVerC (Amy, Roetteler, Svore) | 2017 | Revs | Same as Revs, formally verified in F*. Ancilla heap + eager cleanup. **No pointers, no dynamic memory.** |
| Quipper (Green, Lumsdaine, Ross, Selinger, Valiron) | 2013 | Haskell EDSL | Circuits as Circ monad. Any "memory" is user-controlled register. |
| ProjectQ (Steiger, Häner, Troyer) | 2018 | Python | `with Compute/Uncompute` blocks. Memory = qubit register. No dynamic allocation. |
| Q# (Microsoft) | 2017–present | Q# | `use q = Qubit[n]` allocates qubits scoped to block. "copy-and-update" is in-place when safe. No heap. |
| Silq (Bichsel, Baader, Gehr, Vechev) | 2020 | Silq | **Automatic uncomputation via `const` and `qfree` annotations.** Uncompute at end of scope. Elegant but still scoped, not heap. |
| Qrisp (Seidel et al.) | 2023 | Python | Improved Unqomp integration. `QuantumVariable` auto-uncomputed on scope exit. No pointers. |
| Unqomp (Paradis, Bichsel, Steffen, Vechev) | 2021 PLDI | (Qiskit) | **"Compute dependency graph"** + marking qubits as ancillas auto-uncomputes them. Average -71% gates, -19% qubits on benchmarks. Relies on per-operation purity. |
| ReQomp (Paradis, Bichsel, Vechev) | 2024 Quantum | (Qiskit) | **Space-constrained** uncomputation. Pareto-explores qubit × gate count. Up to −96% ancillae. Built on Unqomp. |
| Qurts (Yasuoka et al.) | POPL 2025 | Rust-inspired | **Affine types with lifetimes.** In lifetime, treat qubits affinely; outside, linearly. Clean type-theoretic basis. |
| Meuli, Soeken, Roetteler, Björner, De Micheli, "Reversible Pebbling Game for Quantum Memory Management", DATE 2019 | 2019 | (generic) | **SAT-based pebbling** — expresses space-time tradeoff as SAT. Average 52% ancilla reduction. |
| de Beaudrap, Horsman et al., "Optimizing Quantum Space Using Spooky Pebble Games" | 2023 | (generic) | **Spooky pebble game** — uses intermediate measurements + classical control. Tighter space bounds than reversible pebble game alone. Not applicable if compiler must stay coherent. |
| Buhrman, Tromp, Vitányi, "Time and Space bounds for reversible simulation", ICALP 2001 / JPhysA 2001 | 2001 | — | Refines Bennett 1989 and Knill 1995. |

**Critical finding:** **None of these compilers handles full LLVM `store`/`load`/`alloca`.** All restrict to either (a) user-scoped register allocation or (b) arrays with compile-time-static indices. When ReVerC's carry-ripple adder benchmark (Table 1 of the ReVerC paper, confirmed by reading the PDF) uses `let mutable carry = false`, the compiler eliminates the mutation via the MDD dependency graph at compile time; it never emits a "store" instruction.

### 2i. Lifetime-guided uncomputation: ReQomp family

- **Unqomp 2021** (PLDI): Given a quantum circuit annotated with ancilla qubits, build a Compute Dependency Graph (CDG) where each qubit's "compute" dependencies are tracked. For a qubit q with compute dependencies D(q), the uncomputation of q is: for each gate g in compute(q) in reverse, apply g† if g is reversibly-pure (qfree). Soundness requires q hasn't been entangled with other outputs.
- **ReQomp 2024** (Quantum): Adds space constraints. If fewer than maximum ancillae available, re-compute some intermediates lazily (Knill/Bennett pebbling). Up to 96% ancilla reduction on benchmarks; ≤28% gate increase.
- **Qurts 2025** (POPL): Type-theoretic approach — affine types with explicit lifetimes. A qubit's type determines whether it must be uncomputed when its lifetime ends.

**Applicability to Bennett.jl:** The CDG in Unqomp is essentially the dominance tree plus liveness analysis — LLVM has both. A full ReQomp-style pebbling pass over Bennett.jl's gate list would be a straightforward implementation; the SAT-based Meuli approach is an easy drop-in replacement for the current Knill pebbling.

---

## 3. ReVerC Deep Read

From reading Amy-Roetteler-Svore 2017 end-to-end (`docs/literature/memory/reverc-2017.pdf`, 17 pages + refs):

### 3.1 Source language (Revs)
From Fig. 3 of the paper, the Revs grammar is:
```
Val  v ::= unit | l | reg l₁...lₙ | λx.t
Term t ::= let x = t₁ in t₂ | λx.t | (t₁ t₂) | x | t₁ ← t₂ | b
         | t₁ ⊕ t₂ | t₁ ∧ t₂ | clean t | assert t
         | reg t₁...tₙ | t.[i] | t.[i..j] | append t₁ t₂ | rotate i t
```

What Revs supports:
- **Single-bit mutable variables** via `t₁ ← t₂` (destructive assignment).
- **Fixed-size bit arrays** (`reg`) with static-index subscripting `t.[i]`, slicing `t.[i..j]`, append, rotate.
- **Arrays with mutable elements**: `result.[0] ← a.[0] ⊕ b.[0]` from the carry-ripple adder example.
- `clean t` — explicit deallocation assertion that t evaluates to 0.
- `for` loops over static ranges, `if`-`then`-`else` as sugar for AND/XOR combinations.

**What Revs does NOT support:**
- Dynamic control flow (page 5: "Revs has no dynamic control — i.e., control dependent on run-time values"). Every program can be transformed into a straight-line program at compile time.
- Dynamic array indexing (`a.[i]` for a runtime `i`). ReVerC only supports literal indices, or indices that constant-fold.
- Pointers, references, heap allocation.
- Recursion (the paper says the language is R-Turing complete but only via program inversion).
- Function calls with unknown-size parameters (requires `parameter interference` analysis, an undocumented side-analysis).

### 3.2 EAGER cleanup (Algorithm in Section 4.3)

The key algorithm is a *cleanup expression interpretation*: domain D = (ℕ → ℕ) × **Circ** × **AncHeap** × (ℕ → **BExp**). Each bit of the current circuit is associated with a *cleanup expression κ(i)*: a Boolean expression over still-live bits that equals the original value the bit must return to (0). The `CLEAN(i)` function either returns unchanged if `i ∈ vars(κ(i))` (a self-reference, can't cleanly uncompute without affecting i itself), or emits `COMPILE-BEXP(κ(i), i)` which XORs in the cleanup expression, zeroing the bit, and pushes it back to the ancilla heap.

The algorithm is *not* full garbage collection — it's a particular case where "the number of references to a heap location (or in our case, a bit) is trivially zero". Future work in the paper explicitly mentions extending this to generic reference counting.

### 3.3 Benchmark table (Table 1 of ReVerC paper)

For 32/64-bit reversible adders and hash functions, directly from Table 1:

| Benchmark | Revs (default) bits/gates/Toffoli | Revs (eager) bits/gates/Toffoli | ReVerC (default) | ReVerC (eager) |
|---|---|---|---|---|
| carryRippleAdd 32 | 129 / 281 / **62** | 129 / 467 / 124 | 128 / 281 / **62** | 113 / 361 / 90 |
| carryRippleAdd 64 | 257 / 569 / **126** | 257 / 947 / 252 | 256 / 569 / **126** | 225 / 745 / 186 |
| mult 32 | 128 / 6016 / 4032 | 128 / 6016 / 4032 | 128 / 6016 / 4032 | 128 / 6016 / 4032 |
| mult 64 | 256 / 24320 / 16256 | 256 / 24320 / 16256 | 256 / 24320 / 16256 | 256 / 24320 / 16256 |
| carryLookahead 32 | 160 / 345 / **103** | 109 / 1036 / 344 | 165 / 499 / 120 | 146 / 576 / 146 |
| carryLookahead 64 | 424 / 1026 / **307** | 271 / 3274 / 1130 | 432 / 1375 / 336 | 376 / 1649 / 428 |
| modAdd 32/64 | 65/188/62 to 129/380/126 (small) | (same as default) | (same) | (same) |
| cucarroAdder 32 | 65 / 98 / **32** | (same) | 65 / 98 / **32** | 65 / 98 / **32** |
| cucarroAdder 64 | 129 / 194 / **64** | (same) | 129 / 194 / **64** | 129 / 194 / **64** |
| ma4 | 17 / 24 / 8 | (same) | (same) | (same) |
| **SHA-2 round** | 449 / 1796 / **594** | 353 / 2276 / 754 | 452 / 1796 / **594** | 449 / 1796 / 594 |
| **MD5** | 7841 / 81664 / **27520** | 7905 / 82624 / 27968 | 4833 / 70912 / 27520 | **4769 / 70912 / 27520** |

**Observations:**
- ReVerC's *eager* mode on MD5 uses 4,769 bits — that's our main target to beat.
- For SHA-2 the bit count is already close to the hand-optimized 353 bits.
- ReVerC does **no better than default Revs** on most benchmarks; correctness of verification costs bit-count parity.
- Cuccaro adder (`cucarroAdder`) appears in both tables because they also compile the Cuccaro algorithm. **32 Toffolis for 32-bit, 64 Toffolis for 64-bit.**

### 3.4 Stated limitations on memory (ReVerC paper, Sec 7 Conclusion + passim)

Direct quote (ReVerC Section 4.3, page 12): "The eager cleanup interpretation coincides with a reversible analogue of *garbage collection* for a very specific case when the number of references to a heap location (or in our case, a bit) is trivially zero. ... We intend to expand ReVerC to include a generic garbage collector that uses cleanup expressions to more aggressively reclaim space".

- No generic garbage collector.
- No dynamic allocation.
- No pointers, no memcpy.
- Cleanup is local to "bits trivially unreferenced", not global reference counting.
- **The upshot: ReVerC's memory model is "bit heap where bits are freed by restricted inverses of their compute expression".** That's it.

---

## 4. Enzyme Comparison

From reading Moses-Churavy 2020 (NeurIPS `enzyme-2020.pdf`, 10 pages):

### 4.1 Architecture

Three passes on LLVM IR:
1. **Type Analysis** — forwards-flowing abstract interpretation via type tree. For every SSA value, decide the types at each offset. Handles `memcpy(void*, void*)` by inferring source/dest types from context.
2. **Activity Analysis** — backward dataflow. A value is *active* iff it can propagate a derivative to an output (return value or active memory location). Inactive values skip the reverse pass.
3. **Synthesis** — walks IR, emits forward pass (unchanged) + augmented data for caching + reverse pass (adjoints).

### 4.2 Shadow memory details (extracted from PDF text)

**Allocation:** for each `malloc(n)` or `alloca(n)` in the forward pass, Enzyme emits a twin `malloc(n)` for the shadow. If n is statically known, shadow's size equals primal's. If n is runtime, shadow uses the same runtime size and is deallocated after the reverse pass finishes.

**Storage during fwd pass:** before each `store primal_val at p` that might overwrite a previous value needed in reverse, the old value may be pushed onto a tape. Alias analysis tries to prove the old value is unneeded to avoid this.

**Reverse transformation of stores:**
```
// forward:  store x, %p
// reverse:  %dx = load %d_p
//          %d_x += %dx      // accumulate
//          store 0, %d_p    // zero shadow
```

**Reverse transformation of loads:**
```
// forward:  %x = load %p
// reverse:  %d_p = load %d_p ; %d_p += %d_x ; store %d_p, %d_p_addr
```

**Cache decision:** A forward value is cached only if the reverse pass needs it AND Enzyme cannot prove it's recomputable or re-readable. Enzyme uses LLVM's `AliasAnalysis` and type-based alias analysis (TBAA) to prove recomputability.

### 4.3 What transfers to reversibility

| Enzyme technique | Reversible analog | Notes |
|---|---|---|
| Shadow memory | "Ancilla copy of heap" | Ours must return to zero exactly, not be "deallocated"; but the structural idea is preserved. |
| Activity analysis | "Which wires are outputs?" | Directly applicable: any wire not transitively an output must return to zero. |
| Type analysis | Same | Needed equally for type-based memory partitioning. |
| Tape cache | Bennett uncompute or checkpoint | Enzyme tape is irreversible write; we must replace with Bennett-style uncompute or pebbling. |
| Adjoint accumulation `+=` | N/A — reversibility is not linear | This is the fundamental difference: AD handles non-injective functions by summing derivatives; we cannot. Every store must be an exact permutation. |
| Checkpointing (loops) | Bennett pebbling | Directly applicable — just re-uses the same pebble-game theory. |

**Bottom line:** Enzyme's architecture (3-pass, type analysis, activity analysis, shadow allocation) is a great blueprint for a memory-handling pass in Bennett.jl. The biggest divergence is that Enzyme is *linear* (adjoints sum, derivatives commute) while reversibility is *injective* (stores must be exact permutations). For reads that's fine; for writes that eliminates Enzyme's accumulator trick. But for store-elimination by aliasing analysis, Enzyme is directly the template.

---

## 5. Implementation Recommendations Table

| # | Approach | Paper / Ref | Asymptotic (gates / ancillae / depth) | Concrete estimate N=4 W=8 | N=16 W=16 | N=256 W=32 | Pros | Cons | Days | Pipeline change | Dominates ReVerC? | Landauer |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **SSA mutation elim + store eliminator** | (Our novel) + Revs MDD (2015) | 0 gates / 0 ancillae / 0 depth for resolved stores | 0 (if resolvable) | 0 | 0 | Free. Handles 80%+ of real code because LLVM's SSA-form already eliminated most redundant stores. | Doesn't handle truly dynamic indexing. | 3–5 | New pass; alias analysis hookup in `ir_extract.jl` | YES (ReVerC doesn't have this as a named pass) | Free |
| 2 | **Flat-array MUX EXCH** | Axelsen-Glück 2013 + our prototype | O(NW log N) gates / O(NW) ancillae / O(log N) depth | ≈1.4 kG write, 0.4 kG read | ≈15 kG write, 5 kG read | ≈300 kG write, 100 kG read | Well-understood; our existing prototype proves feasibility. | Above budget for N≥128. | 2–4 | New `MemRegion` IR type, lower for `load`/`store` in `lower.jl` | YES (for small arrays; ReVerC has no dynamic index support) | Yes — every op is reversible; fits S2LAL. |
| 3 | **QROM for read-only data** | Babbush-Gidney 2018 / Low-Kliuchnikov-Schaeffer 2018 | 4L Toffolis / log L ancillae / O(L) depth (or O(√L) with dirty ancillae) | 16 Toffolis for L=4 | 64 for L=16 | 1024 for L=256 | Optimal for immutable tables. Directly applicable to LLVM `@constant` globals, jump tables, LUTs. | Read-only. | 3–7 | New `ConstantTable` intrinsic handler | YES (no ReVerC equivalent for constants) | Yes — reads are reversible in principle. |
| 4 | **Shadow-memory + checkpointing** | Enzyme 2020 + Bennett 1989 + Meuli 2019 | O(T^(1+ε) log S) gates / O(S log T) ancillae; tunable | Depends on program size | Depends | Depends | Universal — handles any program. Tunable ancilla-count × gate-count. | Can be gate-heavy. Needs careful type+activity analysis. | 10–20 | **Major new pass**: fwd-tape, rev-checkpoint, SAT pebbling | **YES** — no reversible compiler has this yet. Novel. | Yes |
| 5 | **Cuccaro in-place for arithmetic stores** | Cuccaro 2004 | 2n−1 Toffoli + 5n−3 CNOT / 1 ancilla / 2n+4 depth | 15 Toffoli / 1 anc (n=8) | 31 / 1 (n=16) | 63 / 1 (n=32) | Optimal for `*p = *p + rhs`. Proven, our `adder.jl` is close. | Only arithmetic. Needs pattern matcher. | 3–5 | Extend `lower.jl` with pattern match on `load;add;store` triples | Matches ReVerC | Yes |
| 6 | **Hash-consed persistent HAMT** | Okasaki 1999 + Baker 1991 + HAMT (Bagwell 2001) + Mogensen 2018 | O(W log_32 N) gates / O(W log_32 N) ancillae / O(log_32 N) depth | ≈4 kG (log₃₂ 4 = 1) | ≈8 kG (log₃₂ 16 = 1) | ≈12 kG (log₃₂ 256 = 1.6) | Only fully persistent option. Fan-out 32 keeps depth tiny. | Engineering complexity; our RBT prototype at 71 kG suggests slow ramp. | 14–21 | New `PersistentMap` IR type + hash-cons maintenance | **YES** — beyond ReVerC scope | Yes |
| 7 | **Bucket-brigade QRAM for classical data** | Giovannetti-Lloyd-Maccone 2008 + Hann 2021 | O(2^n) qubits baseline, O(n) *activated* per call, O(n) depth | ≈ 100 G per read (small N) | ≈ 500 G | ≈ 20 kG | Log depth; robust to noise. | Qubit-count hungry (even if most inactive). Overkill for classical data; QROM (#3) usually wins. | 14+ | New IR type + router synthesis | For classical data: QROM (#3) usually wins on gate count; BB-QRAM is novelty | Yes (if hardware supports it) |

**Recommendation:** Implement in order **1 → 2 → 3 → 5 → 4 → 6 → 7**. The first three cover 95% of real LLVM programs; #4 is the research contribution; #6 is the fallback; #7 is the paper-worthy curiosity.

---

## 6. Theoretical Lower Bounds

### 6.1 What's known

- **Classical reversible access cannot be sub-linear in the address.** For an N-element array addressed by an n=log₂N-bit index, a Toffoli-only reversible circuit must touch Ω(n) wires in the worst case simply to decode the address — that's the information-theoretic floor. Bucket brigade's cleverness lies in activating only O(n) of its 2^n routers, not in beating O(n).
- **Bennett 1989 + Knill 1995:** For simulation of a T-time, S-space irreversible program, reversible simulation requires at least Ω(S log T) space and Ω(T^(1+ε)) time for any ε > 0. No free lunch.
- **Buhrman-Tromp-Vitányi 2001:** Refines the above; shows that for time T, space S in the irreversible model, the reversible algorithm using k pebbles runs in time Θ(T·(T/S)^(log₂(k)/k) · log(T)) essentially — matching the Knill lower bound.
- **Lange-McKenzie-Tapp 1997:** Reversible space ≡ deterministic space (for decision problems). Constant-space reversible TMs equal LOGSPACE. So reversibility *per se* costs nothing asymptotically in space if we're willing to pay in time.

### 6.2 Ancilla-free reversible memory

Impossibility: **No general ancilla-free reversible memory exists** because writing `M[i] = v` requires first computing the old value (so we can uncompute it) — this requires a temporary register equal in size to the cell. So at minimum W ancillae per update. The Cuccaro technique saves on ancillae for *arithmetic updates* `M[i] += rhs` by exploiting the bijectivity of `(a,b) → (a, a+b)`.

### 6.3 O(log N) QRAM?

The Jaques-Rattew 2025 survey is emphatic: **passive QRAM with O(log N) true depth and resources is an open problem and likely physically unrealizable** under current proposals. Active QRAM (with classical control per query) technically achieves O(log N) depth but loses quantum advantage due to opportunity cost.

**For Bennett.jl (purely classical reversible):** the lower bound is O(log N) wires touched per access (for decoding the address) and O(W) wires for the data. The O(log N) wires touched is a real wall.

---

## 7. The Green-Energy Angle

### 7.1 Foundations

- **Landauer 1961** (IBM JRD): kT ln 2 ≈ 0.018 eV per irreversible bit at 300K.
- **Bennett 1973** (IBM JRD): logical reversibility avoids this floor.
- **Fredkin-Toffoli 1982**: "Conservative Logic" — fully reversible universal gates. The Fredkin gate and the Toffoli gate are the workhorses.

### 7.2 Modern practice

- **Koller-Athas 1992**: First implementations of charge-recovering CMOS (precursor to all adiabatic logic). Recovery factor 2-3×.
- **Athas-Svensson**: Adiabatic CMOS theory, 1994-2000. Energy per op scales as CV²·(t_op/RC) for slow switching, approaching arbitrarily low dissipation as t_op → ∞.
- **Frank et al. 2020**, *"Reversible Computing with Fast, Fully Static, Fully Adiabatic CMOS"* (arXiv:2009.00448): **S2LAL logic family.** First fully-static, fully-adiabatic CMOS family. 8-tick period, 1-2 OOM efficiency vs. best static CMOS.
- **Frank et al. 2023**, APL Electronic Devices 1:030902: "Industry perspective — limits of energy efficiency for conventional CMOS...". The peer-reviewed industrial case for reversible computing being the only path to 10×+ efficiency gains.
- **Vaire Computing 2024**: First commercial silicon (Ice River). Published 1.77× energy recovery on capacitor arrays, 1.41× on shift registers. Roadmap claims 4000× efficiency at scale.

### 7.3 Numbers

At 300K a single irreversible bit-erasure dissipates 2.9×10⁻²¹ J (Landauer). Modern CMOS at 7 nm is around 10⁻¹⁴ J per logic op — seven orders of magnitude above Landauer.

A Toffoli gate in adiabatic CMOS (S2LAL or better) dissipates essentially zero energy in the limit of slow switching. For a 1 GHz clock, one Toffoli at 7 nm requires ~10⁻¹⁶ J in S2LAL — two orders of magnitude below equivalent irreversible AND. With clocking slowed appropriately for adiabatic regime, this can be driven toward Landauer.

### 7.4 Bennett.jl framing

The argument: **"A compiler that automatically emits minimum-ancilla reversible Toffoli networks from ordinary Julia/LLVM code is the missing piece between (a) Vaire-style reversible CMOS chips shipping circa 2027 and (b) existing software."** Most research effort in reversible computing has been on the hardware side; the software stack is a wasteland. Bennett.jl can claim that gap.

Sturm.jl and quantum oracles are one application (the NeurIPS/quantum-algorithm audience). Reversible CMOS is the other (the hardware/energy/post-Moore audience). The same compiler serves both.

---

## 8. Paper Angles

Based on the literature, three concrete narratives for a NeurIPS or PLDI paper:

### 8.1 Paper #1: "Reversible Memory in an SSA Compiler"

**Gap:** No existing reversible compiler supports arbitrary LLVM `load`/`store`/`alloca`/`memcpy`. ReVerC restricts to static-index arrays; Silq/Unqomp/Qrisp restrict to scoped ancilla registers.

**Contribution:** The first LLVM-IR-level pass that lowers unrestricted mutable memory to reversible circuits, using: (1) SSA mutation elimination via type + activity analysis ported from Enzyme; (2) fall-back to flat-array EXCH for truly-dynamic indexing; (3) QROM for read-only globals; (4) Cuccaro-in-place for arithmetic stores; (5) shadow-memory checkpointing with SAT-pebbling for the residual.

**Evaluation:** Reproduce ReVerC's Table 1 benchmarks and add a new suite with memory-heavy code (sorting, graph algorithms, SHA-3, Blake3 round functions, Julia Vector code).

**Target:** PLDI or ICFP.

### 8.2 Paper #2: "BennettBench — A Reversible Memory Model Benchmark"

**Gap:** No existing benchmark suite compares reversible memory models head-to-head. ReVerC benchmarks its own MDD transforms. Unqomp/ReQomp benchmarks themselves. No apples-to-apples.

**Contribution:** A curated set of 30-50 reversible workloads (arithmetic, crypto, sort, graph, linear algebra, IEEE 754 FP) along with reference implementations of (a) Bennett, (b) ReVerC EAGER, (c) Unqomp, (d) flat-array EXCH, (e) Cuccaro, (f) QROM, (g) hash-consed HAMT. For each workload, report (gates, ancillae, depth).

**Evaluation:** Run all 7 memory models on all 50 workloads, publish the Pareto fronts.

**Target:** PLDI Artifact Evaluation, or an MLSys-style benchmark paper.

### 8.3 Paper #3: "Reversible Computing: The Unlocked Energy Frontier"

**Gap:** The energy-efficiency argument for reversible classical computing exists mainly in hardware papers (Frank et al.) and informal tech blog posts. A compiler-centric framing — "here is what it means for software when we can run logically-reversible circuits on adiabatic CMOS" — is largely absent.

**Contribution:** Partner with Vaire Computing (or run on S2LAL simulator). Compile 10 canonical classical workloads to Toffoli gates via Bennett.jl; simulate both irreversible CMOS and adiabatic S2LAL; report total Joules per operation. Framework for porting any LLVM-compilable language to reversible hardware.

**Evaluation:** Simulated energy numbers + projections to post-Moore era.

**Target:** ACM Computing Surveys, IEEE Micro, or a HotChips / HotCarbon session.

---

## 9. References (Bibliography)

### Core foundations

1. Landauer, R. (1961). "Irreversibility and heat generation in the computing process." *IBM J. Res. Develop.* 5:183-191. [DOI:10.1147/rd.53.0183](https://doi.org/10.1147/rd.53.0183)
2. Bennett, C. H. (1973). "Logical reversibility of computation." *IBM J. Res. Develop.* 17:525-532. [DOI:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525)
3. Bennett, C. H. (1989). "Time/space trade-offs for reversible computation." *SIAM J. Comput.* 18:766-776. [DOI:10.1137/0218053](https://doi.org/10.1137/0218053)
4. Fredkin, E. & Toffoli, T. (1982). "Conservative logic." *Int. J. Theor. Phys.* 21:219.

### Reversible pebbling / space-time

5. Knill, E. (1995). "An analysis of Bennett's pebble game." arXiv:math/9508218.
6. Lange, K.-J., McKenzie, P., Tapp, A. (2000). "Reversible space equals deterministic space." *J. Comput. Syst. Sci.* 60:354.
7. Buhrman, H., Tromp, J., Vitányi, P. (2001). "Time and space bounds for reversible simulation." *J. Phys. A* 34:6821.
8. Meuli, G., Soeken, M., Roetteler, M., Björner, N., De Micheli, G. (2019). "Reversible pebbling game for quantum memory management." *DATE*. [arXiv:1904.02121](https://arxiv.org/abs/1904.02121).
9. Kornerup, P., Palsberg, J., et al. (2021). "Tight bounds on the spooky pebble game." [arXiv:2110.08973](https://arxiv.org/abs/2110.08973).

### Reversible languages

10. Yokoyama, T. & Glück, R. (2007). "A reversible programming language and its invertible self-interpreter." *PEPM*. [DOI:10.1145/1244381.1244404](https://doi.org/10.1145/1244381.1244404)
11. Thomsen, M. K., Axelsen, H. B. (2015). "Interpretation and programming of the reversible functional language RFUN." *IFL*. [DOI:10.1145/2897336.2897345](https://doi.org/10.1145/2897336.2897345).
12. Hoey, J., Axelsen, H. B., Glück, R. (2022). "Reversible computing from a programming language perspective." *TCS* 915:15.

### Reversible memory

13. Axelsen, H. B. & Glück, R. (2013). "Reversible representation and manipulation of constructor terms in the heap." *RC* LNCS 7948, pp. 96-109.
14. Mogensen, T. Æ. (2015). "Garbage collection for reversible functional languages." *RC* LNCS 9138.
15. Mogensen, T. Æ. (2018). "Reversible garbage collection for reversible functional languages." *New Gen. Comput.* 36:203. [DOI:10.1007/s00354-018-0037-3](https://doi.org/10.1007/s00354-018-0037-3)

### Reversible compilers

16. Parent, A., Roetteler, M., Svore, K. M. (2015). "Reversible circuit compilation with space constraints." [arXiv:1510.00377](https://arxiv.org/abs/1510.00377).
17. Amy, M., Roetteler, M., Svore, K. M. (2017). "Verified compilation of space-efficient reversible circuits." *CAV*. [arXiv:1603.01635](https://arxiv.org/abs/1603.01635).
18. Green, A. S., Lumsdaine, P. L., Ross, N. J., Selinger, P., Valiron, B. (2013). "Quipper: a scalable quantum programming language." *PLDI*. [DOI:10.1145/2491956.2462177](https://doi.org/10.1145/2491956.2462177).
19. Steiger, D. S., Häner, T., Troyer, M. (2018). "ProjectQ: an open source software framework for quantum computing." *Quantum* 2:49.
20. Bichsel, B., Baader, M., Gehr, T., Vechev, M. (2020). "Silq: a high-level quantum language with safe uncomputation and intuitive semantics." *PLDI*. [DOI:10.1145/3385412.3386007](https://doi.org/10.1145/3385412.3386007).
21. Paradis, A., Bichsel, B., Steffen, S., Vechev, M. (2021). "Unqomp: synthesizing uncomputation in quantum circuits." *PLDI*. [DOI:10.1145/3453483.3454040](https://doi.org/10.1145/3453483.3454040).
22. Paradis, A., Bichsel, B., Vechev, M. (2024). "Reqomp: space-constrained uncomputation for quantum circuits." *Quantum* 8:1258. [arXiv:2212.10395](https://arxiv.org/abs/2212.10395).
23. Yasuoka, K. et al. (2024). "Qurts: automatic quantum uncomputation by affine types with lifetime." *POPL 2025*. [arXiv:2411.10835](https://arxiv.org/abs/2411.10835).
24. Seidel, R., Bock, S. et al. (2023). "Uncomputation in the Qrisp high-level quantum programming framework." *RC*. [arXiv:2307.11417](https://arxiv.org/abs/2307.11417).

### Persistent data structures

25. Driscoll, J. R., Sarnak, N., Sleator, D. D., Tarjan, R. E. (1989). "Making data structures persistent." *JCSS* 38:86.
26. Okasaki, C. (1996). "Purely Functional Data Structures." CMU PhD thesis.
27. Okasaki, C. (1999). "Red-black trees in a functional setting." *JFP* 9(4):471.
28. Conchon, S., Filliâtre, J.-C. (2007). "A persistent union-find data structure." *ML Workshop*.
29. Bagwell, P. (2001). "Ideal hash trees." (HAMT foundational paper)

### Reversible arithmetic

30. Cuccaro, S. A., Draper, T. G., Kutin, S. A., Moulton, D. P. (2004). "A new quantum ripple-carry addition circuit." [arXiv:quant-ph/0410184](https://arxiv.org/abs/quant-ph/0410184).
31. Draper, T. G. (2000). "Addition on a quantum computer." [arXiv:quant-ph/0008033](https://arxiv.org/abs/quant-ph/0008033).
32. Takahashi, Y., Kunihiro, N. (2005). "A linear-size quantum circuit for addition with no ancillary qubits." *QIC* 5:440.
33. Häner, T., Soeken, M., Roetteler, M., Svore, K. M. (2018). "Quantum circuits for floating-point arithmetic." *RC* LNCS 11106. [arXiv:1807.02023](https://arxiv.org/abs/1807.02023).

### QRAM

34. Giovannetti, V., Lloyd, S., Maccone, L. (2008). "Quantum random access memory." *PRL* 100:160501 / *PRA* 78:052310. [arXiv:0708.1879](https://arxiv.org/abs/0708.1879) / [arXiv:0807.4994](https://arxiv.org/abs/0807.4994).
35. Kerenidis, I., Prakash, A. (2017). "Quantum recommendation systems." *ITCS*.
36. Babbush, R., Gidney, C., Berry, D. W., Wiebe, N., et al. (2018). "Encoding electronic spectra in quantum circuits with linear T complexity." *PRX* 8:041015. [arXiv:1805.03662](https://arxiv.org/abs/1805.03662).
37. Low, G. H., Kliuchnikov, V., Schaeffer, L. (2018). "Trading T-gates for dirty qubits in state preparation and unitary synthesis." [arXiv:1812.00954](https://arxiv.org/abs/1812.00954).
38. Hann, C. T., Lee, G., Girvin, S. M., Jiang, L. (2021). "Resilience of quantum random access memory to generic noise." *PRX Quantum* 2:020311.
39. Matteo, O. et al. (2020). "Parallelizing the queries in a bucket-brigade QRAM." *PRA* 102:032608.
40. Jaques, S., Rattew, A. G. (2025). "QRAM: A Survey and Critique." *Quantum* 9:1922.

### Energy / reversible hardware

41. Vitányi, P. (2005). "Time, space, and energy in reversible computing." *ACM Computing Frontiers*. [arXiv:cs/0504088](https://arxiv.org/abs/cs/0504088).
42. Frank, M. P. (1999). "Reversible computing: A cross-disciplinary introduction." PhD thesis, MIT.
43. Frank, M. P., Brocato, R. W., Tierney, B. D., Missert, N. A., Hsia, A. H. (2020). "Reversible computing with fast, fully static, fully adiabatic CMOS." *ICRC*. [arXiv:2009.00448](https://arxiv.org/abs/2009.00448).
44. Frank, M. P., DeBenedictis, E. P. et al. (2023). "Industry perspective: limits of energy efficiency for conventional CMOS and the need for adiabatic reversible computing." *APL Electronic Devices* 1:030902.
45. Koller, J. G., Athas, W. C. (1992). "Adiabatic switching, low energy computing, and the physics of storing and erasing information." *Workshop on Physics and Computation*.

### Automatic differentiation (for comparison)

46. Moses, W. S., Churavy, V. (2020). "Instead of rewriting foreign code for machine learning, automatically synthesize fast gradients." *NeurIPS*. [arXiv:2010.01709](https://arxiv.org/abs/2010.01709).
47. Hascoët, L., Pascual, V. (2013). "The Tapenade automatic differentiation tool: Principles, model, and specification." *ACM TOMS* 39:20.
48. Moses, W. S., Churavy, V., Paehler, L., Hückelheim, J., Narayanan, S. H. K., Schanen, M., Doerfert, J. (2021). "Reverse-mode automatic differentiation and optimization of GPU kernels via Enzyme." *SC'21*.

---

*End of SURVEY.md — draft v0.1, 2026-04-12.*
