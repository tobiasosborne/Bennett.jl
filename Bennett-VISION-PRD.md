# Bennett.jl — Vision PRD: The Enzyme of Reversible Computation

## One-line summary

Bennett.jl is an LLVM-level reversible compiler that transforms arbitrary
programs into space-optimized reversible circuits, analogous to how Enzyme
transforms arbitrary programs into optimized gradients.

---

## 1. Vision

**Enzyme showed that automatic differentiation belongs at the LLVM level.**
By operating below the source language — where every program is a sequence of
primitive instructions — Enzyme differentiates C, C++, Fortran, Julia, Rust,
and Swift with a single tool, inheriting LLVM's entire optimization pipeline.

**Bennett.jl makes the same argument for reversible computation.** Every
deterministic computation can be made reversible via Bennett's 1973
construction. By operating at the LLVM IR level, Bennett.jl reversibilises
any language that compiles to LLVM — without special types, without operator
overloading, without rewriting foreign code.

The result: given any pure function `f`, produce a reversible circuit
`(x, 0) → (x, f(x))` using NOT, CNOT, and Toffoli gates, with all ancillae
verified zero. The circuit is correct by construction and can be used for:

- **Quantum control**: `when(qubit) do f(x) end` in Sturm.jl — any classical
  computation becomes a quantum-controlled operation
- **Reversible hardware synthesis**: direct compilation to Toffoli networks
  for adiabatic/reversible CMOS
- **Space-optimized quantum oracles**: Grover, phase estimation, QSVT all
  need reversible implementations of classical functions

---

## 2. The Enzyme Analogy

| Enzyme (AD) | Bennett.jl (Reversible) |
|---|---|
| Input: LLVM IR of f | Input: LLVM IR of f |
| Output: gradient df/dx | Output: reversible circuit for f |
| Forward pass | Forward gate computation |
| Reverse pass (adjoint) | Bennett uncomputation |
| Tape (cached forward values) | Ancilla wires |
| Activity analysis | Constant-wire elimination |
| Shadow memory | Reversible memory model |
| Function augmentation | Gate-level call inlining (IRCall) |
| Post-optimization AD | Post-optimization reversibilisation |
| Works for any LLVM language | Works for any LLVM language |

**Key difference**: Enzyme computes *derivatives* (a linear approximation).
Bennett.jl computes *exact reversals* (the complete inverse). Enzyme's output
is approximate; Bennett.jl's output is bit-exact. This is both harder (no
approximation allowed) and simpler (no chain rule, no adjoints — just run the
gates backwards).

---

## 3. Architecture

```
                    Bennett.jl Pipeline
                    ═══════════════════

  Julia function          LLVM IR              Parsed IR
  ──────────────         ─────────            ──────────
  f(x::Int8)     ──►  code_llvm()  ──►  extract_parsed_ir()
  f(x::Float64)       (LLVM.jl C API)    (two-pass walker,
                                           intrinsic expansion,
                                           IRCall recognition)
                              │
                              ▼
                    ┌─────────────────────┐
                    │  Instruction Lowering │
                    │  (lower.jl)           │
                    │                       │
                    │  • Integer arithmetic  │
                    │  • Bitwise + shifts    │
                    │  • Comparisons         │
                    │  • Control flow (phi)  │
                    │  • Type conversion     │
                    │  • Memory (GEP/load)   │
                    │  • Function calls      │
                    │  • Division (soft)     │
                    │  • Float (soft-float)  │
                    │  • Path predicates     │
                    └─────────┬─────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  Pebbling Strategy   │
                    │  (pebbling.jl)       │
                    │                       │
                    │  • Full Bennett       │
                    │  • Knill recursion    │
                    │  • [future] SAT       │
                    │  • [future] EAGER     │
                    └─────────┬─────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  Bennett Construction │
                    │  bennett_transform.jl │
                    │                       │
                    │  forward + copy + rev │
                    │  ancilla verification │
                    └─────────┬─────────────┘
                              │
                              ▼
                    ReversibleCircuit
                    ┌───────────────┐
                    │ n_wires       │──► simulate()
                    │ gates[]       │──► gate_count()
                    │ input_wires   │──► verify_reversibility()
                    │ output_wires  │──► controlled()
                    │ ancillae      │──► extract_dep_dag()
                    └───────────────┘
```

---

## 4. LLVM IR Coverage Target

Bennett.jl aims to handle every LLVM IR instruction that a pure, deterministic
function can produce. "Pure" means: no I/O, no system calls, no concurrency.
"Deterministic" means: same input always produces same output.

### Tier 1: Complete (v0.1–v0.6)

These are done and tested:

| Category | Instructions | Gate primitives |
|----------|-------------|-----------------|
| Integer arithmetic | add, sub, mul, udiv, sdiv, urem, srem | Ripple-carry, shift-and-add, restoring division |
| Bitwise | and, or, xor, shl, lshr, ashr | Toffoli per bit, barrel shifter |
| Comparison | icmp (10 predicates) | Modified adder for ULT, sign-flip for SLT |
| Control flow | br, phi, select, ret, unreachable | Path predicates, edge-predicate MUX chains |
| Type conversion | sext, zext, trunc | CNOT copy / wire selection |
| Aggregates | insertvalue, extractvalue | CNOT copy at element offset |
| Memory (static) | getelementptr (const), load | Wire offset, CNOT copy |
| Calls | call (registered callees) | Gate-level inlining via IRCall |
| Float | fadd, fsub, fmul, fdiv, fneg, fcmp | Soft-float library (branchless) |

### Tier 2: Engineering (v0.7–v0.8)

Straightforward extensions of existing patterns:

| Instruction | Approach | Blocker |
|-------------|----------|---------|
| switch | Cascaded icmp + select | None |
| freeze | Identity (no-op) | None |
| sitofp, fptosi | Soft conversion functions | None |
| fpext, fptrunc | Precision conversion | None |
| bitcast | Wire reinterpretation (zero gates) | None |
| frem | Soft remainder via soft_fdiv | None |
| vector.reduce.* | Unroll to scalar ops | None |

### Tier 3: Research (v0.7–v0.9)

Require new theory or significant architecture:

| Instruction | Approach | Research question |
|-------------|----------|-------------------|
| store | Reversible memory write | How to preserve overwritten value? |
| alloca (dynamic) | Reversible allocation | Reversible free list (AG13) |
| GEP (variable index) | QRAM / controlled-SWAP | O(N) vs O(log N) access? |
| memcpy, memmove | Reversible bulk copy | Leverage linearity? |
| Indirect calls | Dynamic dispatch | Controlled-function-pointer? |

### Tier 4: Hard but NOT Out of Scope

**NOTHING IS OUT OF SCOPE.** The stretch vision goal is 100% coverage of every
LLVM IR opcode. Every instruction in the LLVM specification will have a
reversible gate implementation, even if the approach requires novel theory.

These instructions require non-trivial design but ARE targets:

| Instructions | Approach | Status |
|-------------|----------|--------|
| invoke, landingpad, resume | Treat invoke as call + dead unwind path for deterministic callees; for non-deterministic callees, require explicit reversibility contract | Issues filed |
| catchret, catchpad, catchswitch, cleanupret, cleanuppad | Deterministic catch bodies lower normally; non-deterministic paths become unreachable | Issues filed |
| atomicrmw | Decompose to read + compute + reversible write (EXCH-based) | Issue Bennett-6nq |
| cmpxchg | Expand to icmp + conditional reversible store | Issue Bennett-dop |
| fence | No-op for single-threaded circuits (skip) | Issue Bennett-bmq |
| va_arg | Error with clear message (count is runtime-dependent) | Issue Bennett-909 |
| callbr | Error with clear message (inline asm) | Issue Bennett-e84 |
| indirectbr | Expand to cascaded icmp + br | Issue Bennett-4eu |
| ptrtoint, inttoptr | Identity (pointer IS wire index) | Issues filed |
| addrspacecast | Identity (single address space) | Issue Bennett-ay7 |
| ExtractElement, InsertElement, ShuffleVector | Unroll to scalar wire operations | Issue Bennett-vb2 |

**The goal is Enzyme-class coverage:** if Enzyme can differentiate it, Bennett
can reversibilise it. Every LLVM opcode, every common intrinsic, every language
that compiles to LLVM.

### Coverage North Star: Enzyme's frontier as ours

Enzyme's real-world coverage story (from Moses & Churavy NeurIPS 2020 and the
Enzyme.jl / Enzyme-MPI / Enzyme-GPU followups) is the honest north star:

**"Every LLVM opcode that appears in pure numerical code from supported
frontends, plus anything you write a custom rule for."**

Where Enzyme stops — identical to where Bennett.jl will stop:

1. **Inline assembly** (`callbr`, `asm!`). No general semantic model for opaque
   machine code. Hard stop for both tools.
2. **External functions without source or a custom rule**. Enzyme errors on
   `call @printf`, `call @malloc`, raw syscalls, libc math without a registered
   derivative. The escape hatch is `@enzyme_custom_rule` / `augmented_primal`.
3. **Non-reproducible intrinsics**: `llvm.readcyclecounter`,
   `llvm.thread.pointer`, `llvm.returnaddress`, `llvm.frameaddress` — read
   external state with no pure semantics.
4. **Complex C++/SEH exception handling** — Enzyme handles the simple
   `invoke`/`landingpad` pair; full `catchswitch`/`catchpad`/`cleanuppad`
   is historically fragile.
5. **Coroutines** (`llvm.coro.*`) — not supported.

**Bennett.jl's `register_callee!` IS our `@enzyme_custom_rule`.** Same escape
hatch, same semantics: the user registers a pure reversible implementation of
an opaque function and the compiler inlines it at gate level. Building out
the rule library for common libraries (libc math, BLAS, MPI) is the path to
Enzyme-level practical coverage.

Bennett.jl has two additional frontiers Enzyme doesn't share:

- **Concurrent atomic semantics**: `atomicrmw`/`cmpxchg`/`fence` are
  decomposable under single-threaded collapse but not under true concurrency
  (reversible circuits are synchronous by nature). Enzyme handles some
  parallel semantics with custom rules; we commit to single-thread.
- **Runtime exception paths**: Enzyme tolerates simple cases by treating the
  unwind edge as dead. We need an explicit **exception-flag-wire model** for
  faithful translation — every instruction has a guard, throw sets a flag,
  downstream code MUXes on it. Tracked as design work when exception-heavy
  code becomes a target.

**The practical upshot:** no LLVM opcode is provably impossible to cover
(Bennett 1973/1989 is universal for deterministic classical computation).
Every gap reduces to either (a) a design decision about semantics — which
Enzyme has already faced and resolved — or (b) a missing custom rule for an
opaque external, which is a library-building task, not a fundamental one.

---

## 5. Three Pillars

### Pillar 1: Instruction Coverage

Every LLVM IR instruction from a pure function gets a reversible gate sequence.
Integer ops map to classical reversible arithmetic. Float ops route through
branchless soft-float implementations. Memory ops use a reversible memory model
(persistent functional data structures or EXCH-based heaps).

### Pillar 2: Space Optimization

Full Bennett construction uses O(T) ancillae (one per intermediate value).
This is catastrophically wasteful for real programs. Bennett.jl provides a
spectrum of space-time tradeoffs:

| Strategy | Space | Time | Source |
|----------|-------|------|--------|
| Full Bennett | O(T) | O(T) | Bennett 1973 |
| Knill recursion | O(S log T) | O(T^{1+ε}) | Knill 1995 |
| EAGER cleanup | O(optimal) | O(T) | Parent/Roetteler/Svore 2015 |
| SAT pebbling | O(budget) | O(min) | Meuli et al. 2019 |
| In-place ops | -50% per op | O(T) | Cuccaro et al. 2004 |

Infrastructure built: dependency DAG extraction, Knill cost computation,
WireAllocator with free!, Cuccaro in-place adder. Remaining: connect these
into an actual ancilla-reducing `bennett()` via MDD graph + liveness analysis.

### Pillar 3: Composability

Reversible circuits compose naturally:
- **Controlled circuits**: `controlled(circuit)` wraps every gate with a
  control bit (NOT→CNOT, CNOT→Toffoli, Toffoli→decomposition)
- **Function inlining**: `register_callee!(f)` enables gate-level inlining
  of any pure Julia function
- **Sturm.jl integration**: `when(qubit) do f(x) end` compiles f via
  Bennett.jl and wraps in quantum control

---

## 6. Reversible Memory Model

The hardest open problem. LLVM IR uses load/store/alloca for memory —
destructive operations that overwrite previous values. Reversible computation
cannot destroy information.

### Approach A: Static Flattening (done)
For statically-known memory (NTuple, fixed structs): flatten to wire arrays.
GEP = compile-time offset. Load = CNOT copy. No runtime overhead.

### Approach B: Persistent Functional Trees (primary research direction)
Model memory as a persistent red-black tree (Okasaki 1998). Every store creates
a new tree version; the old version is preserved as the ancilla state for
Bennett uncomputation. O(log N) per access. Natural fit: the history IS the
reversibility.

### Approach C: EXCH-based Linear Heap (Axelsen/Glück 2013)
Swap-based memory: EXCH exchanges register and memory cell contents. Preserves
information bidirectionally. Linear reference counts ensure no sharing. The
combination of linearity + reversibility = automatic garbage collection.

### Approach D: QRAM (deferred)
For truly data-dependent variable-index access: bucket-brigade QRAM or
controlled-SWAP multiplexer. O(N) gates per access.

---

## 7. Version History

| Version | Milestone | Status |
|---------|-----------|--------|
| v0.1 | Operator-overloading tracer (Traced{W}) | ✓ Archived |
| v0.2 | LLVM IR approach — plain Julia, no special types | ✓ Complete |
| v0.3 | Controlled circuits + multi-block IR (br, phi) | ✓ Complete |
| v0.4 | Int16/32/64, explicit loops, tuple returns, LLVM.jl | ✓ Complete |
| v0.5 | Float64 (soft-float), path-predicate phi resolution | ✓ Complete |
| v0.6 | extractvalue, soft_fsub/fcmp/fdiv, division, register_callee! | ✓ Complete |
| v0.7 | Static memory (NTuple GEP/load) | ✓ Partial (static done, dynamic open) |
| v0.8 | Pebbling (Knill, DAG, Cuccaro adder) | ✓ Infrastructure (optimization WIP) |
| v0.9 | Sturm.jl integration | Open |
| v1.0 | Full LLVM IR coverage + space-optimized pebbling | Vision target |

---

## 8. Success Criteria for v1.0

1. **Any pure Julia function on integers compiles to a correct reversible circuit**
   — no manual annotation, no special types, no source modification

2. **Float64 functions compile transparently** — `reversible_compile(f, Float64)`
   produces correct circuits via soft-float routing

3. **NTuple and fixed-size array input/output works** — pointer parameters
   handled via static memory flattening

4. **Space optimization reduces ancillae by ≥4x** on benchmark functions
   (SHA-2 rounds, polynomial evaluation, sorting networks) relative to full
   Bennett, matching PRS15 results

5. **Gate counts within 2x of hand-optimized** for standard arithmetic
   operations (addition, multiplication) using Cuccaro-style in-place circuits

6. **Sturm.jl integration works end-to-end** — `when(qubit) do f(x) end`
   compiles f via Bennett.jl and produces a correct quantum-controlled circuit

7. **Reproducible benchmarks** — gate counts, ancilla counts, and circuit depths
   documented for a standard set of functions and compared against published
   results (PRS15 Table I/II, Meuli 2019 benchmarks)

---

## 9. Non-Goals

- **Not a general-purpose quantum compiler.** Bennett.jl compiles classical
  functions to reversible circuits. Quantum algorithms (superposition,
  measurement, entanglement) are Sturm.jl's domain.

- **Not a hardware synthesizer.** Bennett.jl produces gate-level Toffoli
  networks. Mapping to specific hardware (ion traps, superconducting qubits)
  is out of scope.

- **Not a replacement for hand-optimized circuits.** For critical kernels
  (SHA-2, AES, elliptic curve), hand-optimized circuits will always be smaller.
  Bennett.jl's value is *automation* — compile any function without manual
  circuit design.

---

## 10. Key References

All papers downloaded to `docs/literature/` with claims verified against text.

| Tag | Paper | Key result |
|-----|-------|------------|
| BENNETT89 | Bennett 1989, SIAM J. Computing | Theorem 1: O(T^{1+ε}) time, O(S·log T) space |
| KNILL95 | Knill 1995, arXiv:math/9508218 | Theorem 2.1: exact pebbling recursion |
| PRS15 | Parent/Roetteler/Svore 2015, arXiv:1510.00377 | EAGER cleanup: 5.3x qubit reduction on SHA-2 |
| MEULI19 | Meuli et al. 2019, arXiv:1904.02121 | SAT pebbling: 52.77% ancilla reduction |
| CUCCARO04 | Cuccaro et al. 2004, arXiv:quant-ph/0410184 | In-place adder: 1 ancilla, 2n Toffoli |
| OKASAKI99 | Okasaki 1999, J. Functional Programming | Persistent red-black trees |
| AG13 | Axelsen/Glück 2013, LNCS 7948 | Reversible heap with EXCH + linear refs |
| ENZYME20 | Moses/Churavy 2020, arXiv:2010.01709 | LLVM-level AD: activity analysis, shadow memory |
| REQOMP24 | Paradis et al. 2024, Quantum 8:1258 | Lifetime-guided uncomputation (96% reduction) |
