# Bennett.jl

**The Enzyme of reversible computation.** An LLVM-level compiler that transforms arbitrary pure Julia functions into reversible circuits (NOT, CNOT, Toffoli) via [Bennett's 1973 construction](https://doi.org/10.1137/0218053). First reversible compiler with full LLVM `store`/`alloca` support through four specialized, automatically-dispatched memory strategies, plus user-selectable adder and multiplier strategies including Draper QCLA and the Sun-Borissov 2026 polylogarithmic-depth multiplier.

```julia
using Bennett

# Any pure Julia function — no special types, no annotation
f(x::Int8) = x * x + Int8(3) * x + Int8(1)

circuit = reversible_compile(f, Int8)
simulate(circuit, Int8(5))    # => 41
verify_reversibility(circuit) # => true
gate_count(circuit)           # => 872

# Strategy-select the multiplier (shift_add | karatsuba | qcla_tree | auto)
c_qcla = reversible_compile((x, y) -> x * y, Int32, Int32; mul=:qcla_tree)
toffoli_depth(c_qcla)  # => 56 (O(log²n) — Sun-Borissov 2026)
# vs default shift-and-add:
c_sa = reversible_compile((x, y) -> x * y, Int32, Int32)
toffoli_depth(c_sa)    # => 190 (O(n))

# Draper QCLA adder: O(log n) Toffoli-depth instead of O(n) ripple
c_add = reversible_compile((x, y) -> x + y, Int32, Int32; add=:qcla)

# Float64 via branchless soft-float (bit-exact with hardware)
g(x::Float64) = x^2 + 3.0*x + 1.0
circuit_f = reversible_compile(g, Float64)

# Compile-time constant tables → Babbush-Gidney QROM (O(L) Toffoli, W-independent)
h(x::UInt8) = let tbl = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))
    tbl[(x & UInt8(0x3)) + 1]
end
circuit_tbl = reversible_compile(h, UInt8)   # 146 gates (MUX fallback would be ~7,500)

# Mutable arrays with dynamic indexing — handled automatically
k(x::Int8, y::Int8, i::Int8) = let a = Ref(x)
    a[] = x + y
    a[]
end
circuit_mut = reversible_compile(k, Int8, Int8, Int8)
```

## What this does

Given any pure, deterministic function `f`, Bennett.jl produces a reversible circuit `(x, 0) → (x, f(x))` using only NOT, CNOT, and Toffoli gates, with all ancillae verified zero after execution. The circuit is correct by construction.

The compiler extracts LLVM IR from plain Julia via [LLVM.jl](https://github.com/maleadt/LLVM.jl)'s C API, walks the IR as typed objects, lowers each instruction to reversible gates, and applies Bennett's construction. No operator overloading, no special types — plain Julia in, reversible circuit out.

## Why

- **Quantum control**: `when(qubit) do f(x) end` — any classical computation becomes a quantum-controlled operation (motivates integration with [Sturm.jl](https://github.com/tobiasosborne/Sturm.jl))
- **Reversible hardware synthesis**: direct compilation to Toffoli networks for adiabatic/reversible CMOS
- **Space-optimized quantum oracles**: Grover, phase estimation, QSVT all need reversible implementations of classical functions

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/tobiasosborne/Bennett.jl")
```

Requires Julia 1.10+ and LLVM.jl.

## Features

### LLVM instruction coverage (38 core opcodes, ≈90% of what a pure deterministic Julia function produces)

| Category | Instructions |
|----------|-------------|
| **Terminators** (4/11) | `ret`, `br`, `switch` (cascaded), `unreachable` |
| **Integer arithmetic** (13/13) | `add`, `sub`, `mul`, `udiv`, `sdiv`, `urem`, `srem`, `shl`, `lshr`, `ashr`, `and`, `or`, `xor` |
| **Float arithmetic** (5/5) | `fadd`, `fsub`, `fmul`, `fdiv`, `fneg` (via branchless soft-float) |
| **Comparison** | `icmp` (all 10 predicates), `fcmp` (6 predicates) |
| **Control flow** | `phi`, `select`, `freeze`, bounded loops (explicit unroll) |
| **Type conversion** (8/13) | `sext`, `zext`, `trunc`, `fptoui`, `fptosi`, `uitofp`, `sitofp`, `bitcast` |
| **Aggregates** (2/2) | `insertvalue`, `extractvalue` |
| **Memory** (4/7) | `alloca`, `load`, `store`, `getelementptr` |
| **Calls** | `call` with registered callees (gate-level inlining) |

**Missing opcodes** (filed as bd issues, all P3 — not critical path): vector ops (`extractelement`, `insertelement`, `shufflevector`), exception handling (`invoke`, `landingpad`, `catchpad`, etc.), atomic ops (`atomicrmw`, `cmpxchg`, `fence`), transcendental intrinsics (`sqrt`, `sin`/`cos`, `log`/`exp`/`pow`), pointer casts (`ptrtoint`, `inttoptr`, `addrspacecast`), `frem`, `fpext`/`fptrunc`, `va_arg`.

### Memory strategies — automatically dispatched per allocation site

`_pick_alloca_strategy(shape, idx)` picks the cheapest correct lowering for every store/load:

| Strategy | When it activates | Per-store cost | Per-load cost | Paper |
|----------|-------------------|----------------|---------------|-------|
| **Shadow** | static idx, any shape | 3·W CNOT, 0 Toffoli | W CNOT, 0 Toffoli | Enzyme-adapted (Moses & Churavy 2020) |
| **MUX EXCH** | dynamic idx, (W=8, N∈{4,8}) | 7,122 / 14,026 gates | 7,514 / 9,590 gates | — |
| **QROM** | read-only global constant table | — | 4(L-1) Toffoli + O(L·W) CNOT | Babbush-Gidney 2018 §III.C |
| **Feistel hash** | reversible bijective key hash | — | 8·W Toffoli | Luby-Rackoff 1988 |
| **Persistent-DS** | runtime-unbounded mutable memory (`mem=:persistent`) | ~414 gates per set (W=8, `:linear_scan`, asymptotic) | same | Okasaki 1998 / Conchon-Filliâtre 2007 |

Pass `mem=:persistent` to `reversible_compile` to opt into the persistent-DS tier.
The `persistent_impl` kwarg selects the backing implementation (`:linear_scan`
[default], `:okasaki`, `:hamt`, `:cf`); `:linear_scan` wins every (W, depth) cell
in the T5-P7a head-to-head benchmark and is the recommended default (see
[BENCHMARKS.md](BENCHMARKS.md#persistent-ds-head-to-head-pareto-t5-p7a)).

Strategies compose: a function with static-idx stores (shadow) followed by a dynamic-idx load (MUX EXCH) works end-to-end — the MUX reads the post-shadow-mutation primal state.

### Persistent-DS scaling — counterintuitive finding

T5 epic (complete as of 2026-05-20) extends the dispatcher with a persistent-heap
fallback for unbounded `Vector{T}` / `Dict{K,V}` patterns. Four candidate impls
were benchmarked in the T5-P7a head-to-head sweep (see BENCHMARKS.md); the early
scaling sweep below measured impl candidates against `linear_scan` at workloads
`K = max_n` (full structure population):

| max_n | linear_scan total | linear_scan per-set | CF semi-persistent | CF per-set |
|---:|---:|---:|---:|---:|
| 4 | ~1,900 gates | ~475 | 61,728 | 15,432 |
| 16 | ~7,000 | ~440 | 1,077,452 | 67,341 |
| 64 | ~27,000 | ~420 | 17,458,600 | 272,791 |
| 256 | ~107,000 | ~417 | OOM-skipped (~280M predicted) | — |
| 1000 | **414,028** | **~414** | OOM-skipped (~4.5B predicted) | — |

**linear_scan per-set cost is constant in max_n** (asymptotically ~414 gates/set after the Bennett-1xub refresh — 3.3× lower than the 2026-04-20 baseline of ~1,400). Bennett.jl's lowering compresses the branchless "preserve N-1 slots, write 1" pattern regardless of N. CF's variable-depth Diff-write doesn't compress, giving O(N²) total. HAMT/Okasaki cannot beat linear_scan because their per-set work strictly includes more arithmetic (popcount alone is 2,782 gates standalone — 6.7× linear_scan's measured per-set floor). N=1000 reaches **414K gates** via linear_scan.

**Why this contradicts CPU intuition**: CPU-cheap primitives (popcount, pointer deref, tree balance) are gate-expensive. The right reversible DS is one whose per-op pattern matches what Bennett.jl can compress: a single target slot with N-1 no-op preserves. See [`docs/memory/persistent_ds_scaling.md`](docs/memory/persistent_ds_scaling.md) for the full sweep methodology and cost-model derivation.

### Benchmark headlines

| Benchmark | Bennett.jl | Baseline | Ratio |
|-----------|------------|----------|-------|
| QROM lookup L=4, W=8 | 70 gates | MUX tree 7,514 | **107× smaller** |
| QROM lookup L=8, W=8 | 146 gates | MUX tree 9,590 | **66× smaller** |
| Shadow store W=8 | 24 CNOT | MUX EXCH 7,122 | **297× smaller** |
| Feistel hash W=32 | 480 gates | Okasaki 3-node insert 71,000 | **148× smaller** |
| MD5 full (64 steps, extrap.) | ~48k Toffoli | ReVerC 2017 eager 27.5k | 1.75× |
| SHA-256 round | 1,632 Toffoli | PRS15 Table II hand-opt 683 | 2.4× |

QROM's Toffoli count is exactly **4(L-1) and independent of W** — matches the Babbush-Gidney paper bound. Feistel is exactly **8W Toffoli** (4 rounds × 2·half-width). Shadow memory is strictly **3W CNOT / W CNOT** with zero Toffolis from the mechanism itself.

### Space optimization

Multiple Bennett construction strategies for space-time tradeoffs:

| Strategy | SHA-256 round wires | Reduction |
|----------|--------------------|-----------|
| Full Bennett | 2,049 | baseline |
| `checkpoint_bennett` | 1,761 | 14% |
| `pebbled_group_bennett` (Meuli 2019 SAT pebbling) | tunable | up to 50% |
| Cuccaro in-place adder | 1,545 | 25% |
| `value_eager_bennett` (PRS15 EAGER) | further reduction | — |

**Self-reversing primitives** *(downstream library authors — Sturm.jl, future quantum backends — read this)*: a `LoweringResult` whose gate sequence already ends with clean ancillae AND whose result lives on the primary output wires (e.g. QROM lookup, Sun-Borissov multiplier) is *pre-reversed*. Passing it through `bennett()` with `self_reversing=false` would emit the forward + copy-out + reverse wrap anyway — typically doubling the gate count and adding `n_out` ancillae. To opt into the fast path:

1. Construct the `LoweringResult` with `self_reversing=true` (the **8-arg** constructor — the 6-arg and 7-arg convenience forms default to `false`):
   ```julia
   lr = LoweringResult(gates, n_wires, input_wires, output_wires,
                       input_widths, output_elem_widths,
                       GateGroup[], true)   # ← self_reversing=true
   ```
2. Call either `bennett(lr)` (checks the flag and short-circuits) or `bennett_direct(lr)` (asserts `self_reversing=true` — pins the contract at the call site instead of in a constructor argument).

Both run the U03 probe battery (`_validate_self_reversing!`, Bennett-egu6) so a forged claim — dirty ancillae or input mutation — is rejected with a precise error naming the offending wire. Canonical example: `lower_tabulate` (`src/tabulate.jl:208-212`). Downstream impact: switching from the default-wrapped path to the self-reversing fast path cuts peak qubits from 28 → ~22 on Sturm.jl's N=15 Shor mulmod (Bennett-cvnb / Sturm.jl-ao1).

### Arithmetic strategy dispatchers

`reversible_compile(f, T; add=STRAT, mul=STRAT)` selects the
lowering per operation:

| Operation | Strategies | Best for |
|-----------|------------|----------|
| `add=:ripple`   | Out-of-place ripple-carry, O(n) depth | Default, tight Toffoli count |
| `add=:cuccaro`  | In-place with 1 ancilla (Cuccaro 2004) | Ancilla-constrained paths |
| `add=:qcla`     | Carry-lookahead, O(log n) Toffoli-depth (Draper 2004) | Depth-sensitive FTQC |
| `add=:auto`     | Cuccaro when operand dead, ripple otherwise | Pre-P2 default |
| `mul=:shift_add`  | Schoolbook, O(n²) Toffolis | Classical reversible, small W |
| `mul=:karatsuba`  | Recursive, O(n^log₂3) Toffolis | W ≥ 32 gate-count optimization |
| `mul=:qcla_tree`  | QCLA adder tree, O(log²n) T-depth (Sun-Borissov 2026) | Depth-sensitive FTQC |
| `mul=:auto`       | Legacy shift-add / Karatsuba | Pre-P2 default |

Head-to-head at W=64 for `x * y`: QCLA tree Toffoli-depth=64 vs
shift-add 382 (6× shallower) vs Karatsuba 260 (4× shallower), at
5× / 2.5× more Toffolis respectively. Full table in
[BENCHMARKS.md](BENCHMARKS.md#multiplication-strategies-head-to-head).

### MemorySSA integration

Opt-in analysis for memory patterns that survive T0 preprocessing:

```julia
parsed = extract_parsed_ir(f, Tuple{UInt8, Bool}; use_memory_ssa=true)
parsed.memssa isa MemSSAInfo  # Def/Use/Phi graph extracted from LLVM
```

Captures via `print<memoryssa>` pass-output parsing. Informs future lowering decisions for conditional stores, aliased pointers, and phi-merged memory states. See `docs/memory/memssa_investigation.md` for the go/no-go analysis.

### Wider types and composability

- **Int8/16/32/64**: gate count scales linearly (2× per width doubling)
- **Float64**: full IEEE 754 via branchless soft-float (bit-exact with hardware on add/sub/mul/div/neg/cmp/fptosi/sitofp across 1.2M random raw-bit pairs including all subnormal, NaN, Inf, signed-zero, and overflow regions)
- **Float32**: IEEE 754 conversion only. `Float32` is **NOT** a directly supported `reversible_compile` argument type; mixed-precision LLVM IR that contains f32 arithmetic is lowered by widening to f64 (`soft_fpext`), computing in f64, and truncating back (`soft_fptrunc`) — this double-rounds and is **NOT bit-exact** against hardware f32 arithmetic. Native 24-bit-mantissa f32 paths (`soft_f32_fadd`, …) are tracked in `Bennett-3rph` as future work.
- **Tuple return**: `(new_a, new_e) = sha256_round(a, ..., w)`
- **NTuple input**: pointer parameters handled via static memory flattening
- **Ref**: scalar mutable state via shadow memory
- **Mutable arrays**: `[x, y, z]` through the T3b.3 universal dispatcher
- **Persistent-DS fallback**: `mem=:persistent` + `persistent_impl` for runtime-unbounded mutable memory; all four impls (`:linear_scan`, `:okasaki`, `:hamt`, `:cf`) wired and benchmarked
- **Multi-language ingest**: `extract_parsed_ir_from_ll(path)` and `extract_parsed_ir_from_bc(path)` accept `.ll`/`.bc` files from any LLVM frontend (C via `clang -emit-llvm`, Rust via `rustc --emit=llvm-ir`, C++, Fortran); the reversible-compile pipeline is language-agnostic at the LLVM IR level
- **Controlled circuits**: `controlled(circuit)` wraps every gate with a control bit
- **Function inlining**: `register_callee!(f)` enables gate-level inlining of any pure Julia function
- **Bounded loops**: explicit unrolling via `max_loop_iterations` kwarg — see [Architectural limits](#architectural-limits) for what this implies (and the v-next Reversible-VM target that lifts the restriction)
- **Heap-memory recogniser** (opt-in `mem=:heap`): M1 dead-vector slices, M2 statically-sized `Array{T}(undef, N)`, M3 `push!`-built `Vector{T}` with static count, M4 fail-loud scope hardening for `Dict` / runtime-N. Default `mem=:auto` does not run the recogniser — touching Julia's GC stack hits the U15 inline-asm wall

## Quick start

```julia
using Bennett

# Compile a function
circuit = reversible_compile(x -> x + Int8(1), Int8)

# Simulate
simulate(circuit, Int8(42))   # => 43

# Inspect
gate_count(circuit)           # => 100
ancilla_count(circuit)        # => 76
t_count(circuit)              # => 196 (Toffoli × 7)
verify_reversibility(circuit) # => true

# Controlled version (for quantum control)
cc = controlled(circuit)
simulate(cc, true, Int8(42))  # => 43 (control = true)
simulate(cc, false, Int8(42)) # => 42 (control = false)
```

## Architectural limits

Bennett.jl compiles to a **fixed gate sequence** — every operation, every branch, every loop iteration is decided at compile time. This is the same constraint every quantum oracle has: a circuit has no runtime program counter, no runtime-sized memory, no dynamic dispatch. Two consequences follow directly.

### Loops must be statically bounded

LLVM resolves loops with compile-time-constant trip counts (`for i in 1:4`) before Bennett ever sees them — no configuration needed. Data-dependent loops (`while n > 0`, Collatz iteration) survive LLVM as back-edges; you must pass `max_loop_iterations=K` to `reversible_compile`, and Bennett unrolls the body K times with MUX gates that freeze the loop-carried state on exit.

- **Missing `max_loop_iterations`** when a back-edge exists → compile fails immediately with `ArgumentError` ([`src/lowering/driver.jl:81`](src/lowering/driver.jl)).
- **K too small at simulation time** → `simulate` throws `ErrorException` naming the bound and suggesting `max_loop_iterations=2K` (Bennett-s0tn convergence guard, [`src/simulator.jl:215-222`](src/simulator.jl)). **Never a silent wrong answer.**
- **True nested loops** (a loop whose body contains another loop at the LLVM level) → rejected at compile time with `"nested loops not supported"` ([`src/lowering/cfg.jl:111`](src/lowering/cfg.jl)).
- **Sequential loops** in the same function → supported; each unrolls independently. Gate count is additive.
- **A callee that itself contains a loop, called from inside a loop body** → works, but the callee is inlined with a **hardcoded inner `max_loop_iterations=64`** regardless of the outer caller's kwarg ([`src/lowering/call.jl:88`](src/lowering/call.jl)). Gate count grows as O(K × callee_gates) — this can be very large and is not obvious from the source. Tracked as a known smell.

### Memory must be statically sized

Every `alloca`, every `Vector{T}`, every persistent-DS instance has a known shape (width × count) at compile time. The opt-in `mem=:heap` recogniser (Bennett-gps7 → Bennett-bd5f, milestones M1–M4) extends what Bennett can prove to be statically-sized — but a `Dict{K,V}` (Bennett-800b) or a runtime-sized `Array{T}(undef, n)` is rejected at extraction with a precise signpost message naming the offending pattern.

### Coming in v-next: the Bennett-VM target

The fixed-circuit constraint is **architectural, not a bug**. A quantum oracle running on a Bennett-circuit-based backend needs that fixed sequence. But for classical reversible programs — and for dynamic quantum circuits with mid-circuit measurement + classical feedforward — the constraint is unnecessary.

The next major version adds a second lowering target: a **reversible abstract machine** with a program counter and reversible state transitions. On that target, a `while` loop simply runs, dynamically, as many times as the input demands; the existing Bennett pebbling/checkpoint machinery handles its uncomputation. The circuit target stays — both are first-class via the existing `target=` kwarg. See [`Bennett-ReversibleVM-PRD.md`](Bennett-ReversibleVM-PRD.md) for the design (tracked as Bennett-spqu); no implementation exists at the time of this README.

## Build & test

```bash
cd Bennett.jl
julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite runs 688k assertions across 275 test files (~200 testsets) in about **28 minutes** wall-clock under `JULIA_NUM_THREADS=32` on a 64-thread dev machine (cold), not counting Julia precompile of `LLVM.jl`/`Pkg`. The 12 `test_*_llvm_*_dispatch.jl` files dominate (~65% of wall-time, compile-bound — each builds a 2.4M-gate circuit for a transcendental's LLVM-intrinsic dispatch path). The compile-cache workstream (Bennett-hybr / sr8v / uiaq, 2026-05-23) added an identity-keyed `reversible_compile` cache so re-compiles within a session are free. Set `BENNETT_T5_TESTS=0` to skip the multi-language corpus subset (Julia / C via `clang` / Rust via `rustc`); the `clang` and `rustc` corpora self-skip when their compilers are absent.

## Architecture

```
Julia function          LLVM IR                Parsed IR             Reversible Circuit
──────────────         ─────────              ──────────            ──────────────────
 f(x::Int8)    ──►  code_llvm() ──► extract_parsed_ir() ──► lower() ──► bennett()
                    (LLVM.jl C API)      │                    │              │
                                         │              strategy              │
                                     preprocess         dispatch              ▼
                                     sroa/mem2reg        ▼                simulate()
                                     simplifycfg    ┌──────────┐          verify_reversibility()
                                     instcombine    │ Shadow   │          gate_count() / t_count()
                                                    │ MUX EXCH │          controlled()
                                      (optional)    │ QROM     │
                                     MemorySSA      │ Feistel  │
                                     annotations    └──────────┘
```

1. **Extract** — `extract_parsed_ir(f, arg_types)` uses LLVM.jl C API to walk IR as typed objects. Optional `preprocess=true` runs sroa/mem2reg/simplifycfg/instcombine. Optional `use_memory_ssa=true` captures MemorySSA via printer-pass stderr.
2. **Lower** — `lower(parsed_ir)` maps each instruction to reversible gates. For memory ops, `_pick_alloca_strategy` picks shadow / MUX EXCH / QROM / Feistel per op.
3. **Bennett** — `bennett(lr)` applies forward + CNOT-copy + reverse (all ancillae return to zero). Alternative: `pebbled_group_bennett` (SAT-pebbling), `value_eager_bennett` (PRS15 EAGER), `checkpoint_bennett`.
4. **Simulate** — `simulate(circuit, input)` runs bit-vector simulation with ancilla-zero verification.

## Extending Bennett.jl

The compiler is structured around small, single-responsibility hooks. Most extensions land in one or two files; only changes to the core pipeline (per CLAUDE.md §2) require the **3+1 agent protocol** (2 independent design proposers + 1 implementer + 1 reviewer).

### Adding a new LLVM instruction handler

LLVM IR opcodes are converted to typed `IRInst` subtypes in [`src/ir_extract.jl`](src/ir_extract.jl), then lowered to gates in [`src/lower.jl`](src/lower.jl).

1. **Decide the IR shape.** Look at `IRBinOp`, `IRICmp`, `IRSelect`, `IRPhi`, etc. in [`src/ir_types.jl`](src/ir_types.jl) for the existing struct conventions. Either reuse one (most arithmetic / comparison opcodes do) or add a new `struct YourOp <: IRInst`.
2. **Extract.** Add a case in `_convert_instruction` (in `ir_extract.jl`) that builds your `IRInst` from an `LLVM.Instruction`. Always extract actual IR via `code_llvm(f, ArgTypes)` first — never guess the format (CLAUDE.md §5, §9).
3. **Lower.** Add `lower_youropcode!(gates, wa, vw, inst::YourOp; …)` in `lower.jl`, and dispatch from `lower_block_insts!` to it.
4. **Test.** Per CLAUDE.md §3 (red-green TDD): write a `test/test_<bead-id>_<opcode>.jl` that compiles a tiny Julia function exercising the opcode and asserts (a) `verify_reversibility` and (b) `simulate(c, x) == juliareference(x)` for representative inputs. For Int8, sweep all 256.
5. **Worklog.** Prepend a session log entry to the current top chunk under `worklog/`.

Because steps 2 and 3 touch core files (`ir_extract.jl`, `lower.jl`), use the 3+1 protocol unless the change is a surgical bug-fix or an obvious mechanical extension.

### Adding a new gate type

Most users will not need this — `NOTGate`, `CNOTGate`, `ToffoliGate` cover all classical reversible primitives — but if you're prototyping a higher-level operator (e.g. a multi-controlled Toffoli):

1. Add `struct YourGate <: ReversibleGate` in [`src/gates.jl`](src/gates.jl), with `_gate_target` / `_gate_controls` accessors at the bottom of the same file.
2. Add `apply!(b::Vector{Bool}, g::YourGate)` at the top of [`src/simulator.jl`](src/simulator.jl).
3. Add `gate_count` / `t_count` / `toffoli_depth` cases in [`src/diagnostics.jl`](src/diagnostics.jl).
4. Add `bennett_transform.jl` reverse semantics — usually trivial since reversible gates are self-inverse.

Touches `gates.jl` (CLAUDE.md §2 core file) → 3+1 unless surgical.

### Adding a new adder / multiplier strategy

Strategies are routed via the `add` / `mul` kwargs to `reversible_compile`. Current dispatch lives in `_pick_add_strategy` and `_pick_mul_strategy` (in `lower.jl`).

1. Implement `lower_add_yourname!(gates, wa, a, b, W)` (or `lower_mul_yourname!`) in `src/adder.jl` / `src/multiplier.jl` / a new file. Invariants: ancillae must end zero (Bennett's invariant) AND inputs must be preserved (Bennett-6azb / U58). Document gate-count and Toffoli-depth in the docstring.
2. Add the strategy symbol to the `add ∈ (:auto, :ripple, :cuccaro, :qcla, :yourname)` validation in `lower()`.
3. Wire it into `_pick_add_strategy(:yourname)` and add a case in the per-binop dispatcher.
4. Pin a baseline in `test/test_gate_count_regression.jl` per **explicit** strategy kwarg (Bennett-hjwp / U150 — never pin via `:auto`, so the default dispatcher can evolve independently).

### The 3+1 agent protocol

Per **CLAUDE.md §2**, any change to the core pipeline (`ir_extract.jl`, `lower.jl`, `bennett_transform.jl`), gate types (`gates.jl`, `ir_types.jl`), or the phi resolution algorithm requires:

- **2 proposer subagents** — independent design proposals; must not see each other's output.
- **1 implementer** — picks the better proposal or synthesises.
- **1 reviewer** (the orchestrator) — checks correctness, ancilla hygiene, and test coverage.

This is what keeps the phi-resolution / false-path-sensitization class of bugs (CLAUDE.md "Phi Resolution and Control Flow" section) out of the codebase. Surgical bug fixes (a 3-line `sizehint!` removal, a single error-message rewrite, a known-stale compat-hack deletion) typically don't need the full ceremony — but call it explicitly when you skip it.

Per CLAUDE.md §14, **no GitHub CI** — local quality gates only (`Pkg.test()`, the pre-push hook in `scripts/pre-push`, `bd` for issue tracking, and `benchmark/regression_check.jl` for compile-time + gate-count canaries).

## Documentation

- **[Tutorial](docs/src/tutorial.md)** — compile your first reversible circuit in 10 minutes
- **[API Reference](docs/src/api.md)** — every exported function with examples
- **[Architecture Guide](docs/src/architecture.md)** — how the compiler works internally
- **[Vision PRD](Bennett-VISION-PRD.md)** — the full v1.0 roadmap and Enzyme analogy
- **[Memory design docs](docs/memory/)** — `memssa_investigation.md`, `shadow_design.md`, `persistent_ds_scaling.md`
- **[BENCHMARKS.md](BENCHMARKS.md)** — auto-generated head-to-head tables vs published compilers
- **[WORKLOG.md](WORKLOG.md)** — the full development log; per-task gate counts, gotchas, design decisions

## Key references

| Tag | Paper | Key result |
|-----|-------|------------|
| Bennett 1989 | Time/Space Trade-Offs for Reversible Computation | O(T^{1+ε}) time, O(S·log T) space |
| Knill 1995 | Analysis of Bennett's Pebble Game | Exact pebbling recursion |
| Cuccaro 2004 | A New Quantum Ripple-Carry Addition Circuit | In-place adder: 1 ancilla, 2n-1 Toffoli |
| Draper-Kutin-Rains-Svore 2004 | A Logarithmic-Depth Quantum Carry-Lookahead Adder | QCLA: O(log n) Toffoli-depth, O(n) ancilla |
| Sun-Borissov 2026 | A Polylogarithmic-Depth Quantum Multiplier | QCLA-tree multiplier: O(log² n) T-depth |
| Luby-Rackoff 1988 | How to Construct Pseudorandom Permutations | 4-round Feistel = bijective permutation |
| PRS15 | Parent/Roetteler/Svore, Reversible Circuit Compilation | EAGER cleanup: 5.3× reduction on SHA-2 |
| Babbush-Gidney 2018 | Encoding Electronic Spectra with Linear T Complexity | QROM: 4L-4 T, independent of W |
| Enzyme 2020 | Moses & Churavy, Automatically Synthesize Fast Gradients | LLVM-level AD — inspiration for shadow memory |
| Meuli 2019 | SAT-based Pebbling | 52.77% ancilla reduction |
| ReVerC 2017 | Parent/Roetteler/Svore CAV | Prior state-of-art reversible compiler |
| Reqomp 2024 | Paradis et al., Space-constrained Uncomputation | Up to 96% reduction via lifetime-guided |

All papers downloaded to `docs/literature/` with claims verified against text.

## Project status

**Memory plan critical path complete** (2026-05-20): all five memory strategies
(Shadow, MUX EXCH, QROM, Feistel hash, Persistent-DS) plus universal dispatcher,
MemorySSA ingest, and full SHA-256 (BC.3) shipped. The T5 persistent-DS epic
closed 2026-05-20 with the T5-P7a head-to-head Pareto benchmark confirming
`:linear_scan` as the winning default. See `WORKLOG.md` and `BENCHMARKS.md` for
per-task detail.

**Active workstreams:**

- **T5 open follow-ups** (post-epic): wide-W persistent callees (Bennett-8o70),
  HAMT `optimize=false` compatibility (Bennett-7sb7), HAMT mod-32 key collision
  (Bennett-2xws), Rust corpus LLVM-version skew (Bennett-n88f). The core T5
  dispatcher (P6) and the head-to-head benchmark (P7a) are complete.
- **Advanced-arithmetic primitives** — Draper-Kutin-Rains-Svore 2004 QCLA adder (`src/qcla.jl`) and Sun-Borissov 2026 polylogarithmic-depth multiplier (`src/mul_qcla_tree.jl` + `partial_products.jl` + `parallel_adder_tree.jl` + `fast_copy.jl`) all shipped.
- **Catalogue grinding** — A 19-agent code review on 2026-04-21 produced a unified catalogue of 173 issues (`reviews/2026-04-21/UNIFIED_CATALOGUE.md`). ~40 closed; the rest range from snack-sized doc fixes to multi-session 3+1 refactors.

**Future focus** (per `Bennett-VISION-PRD.md`): Sturm.jl integration for quantum control (`when(qubit) do f(x) end`); Julia EscapeAnalysis integration (T0.3 / `Bennett-glh`); `@linear` macro for in-place-linear functions (T2b); structural refactors of `lower.jl` and `ir_extract.jl` (catalogue items U40/U41/U43/U55/U69).

## Contributing

Bennett.jl uses [`bd` (beads)](https://github.com/ksdgg/beads) for issue tracking — open issues live in the project's Dolt repo, not in GitHub Issues.

**Start here:**

1. **Read** `CLAUDE.md` for the non-negotiable development protocols (fail-loud assertions, red-green TDD, exhaustive verification, the 3+1 protocol for core-pipeline changes, etc.). These apply to human and agent contributors equally.
2. **Read** the relevant PRD for the area you'll touch — `Bennett-PRD.md` (v0.1 entry-point) through `BennettIR-v05-PRD.md` (Float64 / soft-float). The PRD defines scope, success criteria, and test cases for each version.
3. **Skim** the most recent worklog chunk under `worklog/` (the highest-numbered file is the latest session). The end-of-entry "Next agent starts here" sections are usually a punch list of ready work.

**Find a starter issue:**

```bash
bd ready                  # all issues ready to work, no blockers
bd ready -n 50            # show more
bd show Bennett-<id>      # full description + linked sites
bd update Bennett-<id> --claim   # mark in-progress
```

Good first beads are typically tagged P3 with type `task` and clear "Sites:" pointers in the description (e.g. `src/X.jl:NN-MM`). Recent doc-snack examples that landed in a single session each: Bennett-uzic (citations), Bennett-d1ee (WHY comments), Bennett-5ttt (status banners), Bennett-2jny (Base collection protocols on `ReversibleCircuit`).

**Run the tests** — Bennett.jl runs all quality gates locally; the project deliberately has no GitHub Actions CI (CLAUDE.md §14):

```bash
JULIA_NUM_THREADS=32 julia --project -e 'using Pkg; Pkg.test()'   # full suite (~28 min cold)
julia --project test/test_increment.jl       # single file
BENNETT_CI=1 julia --project -e 'using Pkg; Pkg.test()'  # promote toolchain skips to errors
```

**Workflow** for completing a bead: `bd update <id> --claim` → write a red-green test under `test/` → make the edit → `Pkg.test()` green → `bd close <id> --reason="..."` → commit with the bead-id in the subject line → `bd dolt push && git push`. Pattern recap with examples lives in any recent worklog entry.

For larger or core-pipeline changes (anything in `src/lower.jl`, `src/ir_extract.jl`, `src/bennett_transform.jl`, `src/gates.jl`, `src/ir_types.jl`, or the phi-resolution algorithm), please follow the **3+1 protocol** in CLAUDE.md §2 — two independent proposers, one implementer, one reviewer.

## License

[AGPL-3.0](LICENSE)
