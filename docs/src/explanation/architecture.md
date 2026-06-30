# Architecture

_For the reader who wants to understand how a plain Julia function becomes a reversible circuit — the four stages, the contracts between them, and the design decisions that shaped each one. This is the "why", not a how-to; for runnable recipes see the [API reference](../reference/api.md)._

Bennett.jl is a compiler. It takes a plain Julia function on plain integers (and `Float64` via soft-float) and emits a classical reversible circuit built from exactly three gates — NOT, CNOT, and Toffoli — such that all ancilla wires return to zero. It does this by extracting the function's LLVM IR, walking that IR as typed objects, lowering each instruction to gates, and finally applying Bennett's 1973 construction to make the whole thing reversible.

There is no operator overloading, no tracing, no special number type threaded through your code. Plain Julia in, reversible circuit out.

## The pipeline at a glance

```
Julia function          LLVM IR              ParsedIR            Reversible circuit
---------------        ---------            ----------          ------------------
f(x::Int8)     -->  code_llvm()  -->  extract_parsed_ir()  -->  lower()  -->  bennett()
                    (LLVM.jl C API)    (typed IR bundle)        (gates)      (fwd+copy+rev)
                                                                                 |
                                                                                 v
                                                                            simulate()
                                                                            verify_reversibility()
```

Four stages, each a pure function of the previous one's output:

1. **Extract** — `extract_parsed_ir(f, arg_types)` runs `code_llvm`, walks the module via the LLVM.jl C API, and produces a `ParsedIR`.
2. **Lower** — `lower(parsed)` maps each IR instruction to NOT/CNOT/Toffoli gates, producing a `LoweringResult`.
3. **Bennett** — `bennett(lr)` applies forward + copy + reverse so that every ancilla returns to zero, producing a `ReversibleCircuit`.
4. **Simulate** — `simulate(circuit, input)` runs a bit-vector simulation and verifies the ancilla-zero and input-preservation invariants.

The front door that orchestrates all four is `reversible_compile` (`src/Bennett.jl`). A first look:

```julia
using Bennett

c = reversible_compile(x -> x + Int8(1), Int8)

gate_count(c)            # => (total = 58, NOT = 6, CNOT = 40, Toffoli = 12)
ancilla_count(c)         # => 25
toffoli_depth(c)         # => 12
depth(c)                 # => 19
verify_reversibility(c)  # => true
```

Two things to notice up front. `gate_count` returns a **`NamedTuple`** `(total, NOT, CNOT, Toffoli)`, not a bare `Int` — reach the scalar with `gate_count(c).total`. And `verify_reversibility` is not "did it run"; it forward-runs the circuit on random inputs (`n_tests=100` by default) and asserts every ancilla came back to zero and every input wire is preserved. "Runs without error" is never a passing test in this project.

`reversible_compile` accepts thirteen keyword arguments, all defaulted from the exported `CompileOptions` struct (`optimize`, `add`, `mul`, `strategy`, `fold_constants`, `target`, `mem`, …). The defaults reproduce the ripple-carry baseline above: `add=:auto` resolves to `:ripple`, `fold_constants=true`. The full value sets live in the [API reference](../reference/api.md); this page is about what happens *inside*.

## Stage 1 — Extract: LLVM IR to ParsedIR

`extract_parsed_ir(f, arg_types)` generates LLVM IR via `code_llvm(f, arg_types; dump_module=true)`, optionally runs a preprocessing pass pipeline, and walks the entry function into a `ParsedIR`.

The walk uses a **two-pass name table** keyed on `LLVMValueRef` (the raw C pointer). Pass one assigns a stable SSA name to every value, including LLVM's unnamed temporaries; pass two converts each instruction using those names. The `_convert_instruction` dispatcher (`src/extract/instructions.jl`) is a per-opcode if-chain that emits one of twenty concrete `IRInst` subtypes: `IRBinOp`, `IRICmp`, `IRSelect`, `IRPhi`, `IRCast`, `IRBranch`, `IRRet`, `IRCall`, `IRLoad`, `IRStore`, `IRAlloca`, `IRSwitch`, and so on (see `src/ir_types.jl`). Two LLVM features get expanded during the walk:

- **Intrinsics.** `_handle_intrinsic` expands roughly thirty-five `llvm.*` intrinsics inline — `umax`/`umin`/`smax`/`smin`, `ctpop`, `ctlz`/`cttz`, `bitreverse`, `bswap`, `fshl`/`fshr`, the rounding family (`floor`/`ceil`/`trunc`/`roundeven`), and the transcendental family (`sqrt`, `exp`/`exp2`, `log`-family, `pow`, `sin`/`cos`/`tan`, `fma`). The min/max/rounding/transcendental intrinsics are routed to registered `soft_*` callees.
- **Callees.** A `call` whose mangled LLVM name (`julia_<name>_NNN` / `j_<name>_NNN`) matches a registered name becomes an `IRCall`, marked for gate-level inlining at lowering time. About seventy soft-float and memory primitives are auto-registered on module load (`src/callees.jl`); you can add your own with `register_callee!`.

Note one subtlety: float arithmetic is **not** handled at the LLVM-opcode level. The only float opcode the dispatcher recognises natively is `fneg`, which it lowers as a sign-bit `xor` — not a soft-float call. A raw native `fadd double` would hit "unsupported LLVM opcode". `Float64` works only because the internal `SoftFloat` struct (`src/softfloat_dispatch.jl`) re-routes `+`, `*`, `/`, … into `call soft_fadd`/`soft_fmul`/… *before* `code_llvm` ever emits a native float op. That is the whole trick behind soft-float support, and it is why the branchless design (below) matters.

### `ir_extract.jl` is a shim, not a monolith

A common misconception, repeated in older docs: that all extraction lives in one ~2.7k-line `src/ir_extract.jl`. It does not. `src/ir_extract.jl` is a **25-line `include` shim** that loads ~19 files under `src/extract/`, in original textual order so parse-time references resolve. The real code is split by concern:

| File | Responsibility |
|------|----------------|
| `src/extract/entry.jl` | public entry points (`extract_parsed_ir`, `.ll`/`.bc` ingest), preprocessing passes |
| `src/extract/instructions.jl` | the `_convert_instruction` opcode dispatcher + `_handle_intrinsic` (the largest file) |
| `src/extract/module_walk.jl` | entry-function discovery, module walk, switch expansion |
| `src/extract/helpers.jl` | `_operand`, width computation, opcode/predicate maps |
| `src/extract/sret.jl` | struct-return detection and aggregate synthesis |
| `src/extract/vectors.jl` | constant-lane vector scalarisation (`insert`/`extract`/`shuffle`) |
| `src/extract/constexpr.jl` | `GlobalAlias` and constant-expression folding |
| `src/extract/callees.jl` | the callee registry, lookup, and the IR cache |

The legacy regex parser `src/ir_parser.jl` was **deleted** (2026-04-25). The LLVM.jl C-API walker is the sole source of truth for IR — never regex over IR text. This is a hard project rule: LLVM IR is not a stable API, so `src/extract/` adapts to LLVM rather than pinning its textual form.

### The ParsedIR contract

The stages are decoupled by one data structure (`src/ir_types.jl`):

```julia
struct ParsedIR
    ret_width::Int                                   # bit-width of the return value
    args::Vector{Tuple{Symbol,Int}}                  # (ssa_name, width) per argument
    blocks::Vector{IRBasicBlock}                     # the CFG, each block a list of IRInst
    ret_elem_widths::Vector{Int}                     # [8] for i8, [8,8] for a 2-tuple return
    globals::Dict{Symbol,Tuple{Vector{UInt64},Int}}  # compile-time constant arrays (QROM tables)
    memssa::Union{Nothing,MemSSAInfo}                # optional MemorySSA alias info
    synth_ptr_provenance::Set{Tuple{Symbol,Int,Int}} # synthetic compile-time addresses
end
```

`lower()` consumes a `ParsedIR` and nothing else — it never re-reads LLVM. That clean boundary is what lets the same `ParsedIR` be lowered to a gate circuit *or* handed to the BennettVM backend (`target=:reversible_vm`).

## Stage 2 — Lower: ParsedIR to gates

`lower(parsed)` is where the bulk of the compiler lives. It walks the CFG in topological order (ignoring back-edges), allocates wires, and emits a flat list of NOT/CNOT/Toffoli gates plus the bookkeeping that Stage 3 needs. The per-opcode dispatch is by Julia multiple dispatch: `_lower_inst!(ctx, inst, label)` has one method per `IRInst` subtype, and a catch-all that errors loudly on anything unhandled.

| IR instruction | Gate implementation |
|----------------|---------------------|
| `add` | strategy-dispatched: ripple / Cuccaro / QCLA |
| `sub` | two's complement (NOT + add + carry-in) |
| `mul` | strategy-dispatched: shift-add / QCLA-tree |
| `and` / `or` / `xor` | per-bit Toffoli / CNOT |
| `shl` / `lshr` / `ashr` | constant amount: direct CNOT rewiring; variable amount: barrel shifter (`ceil(log2 W)` MUX stages) |
| `icmp` | modified adder (unsigned), sign-flip then unsigned (signed) |
| `select` | per-bit MUX controlled by the condition |
| `phi` | path-predicate MUX chain (see below) |
| `br` | block predicates via AND/OR/NOT gates |
| `sext` / `zext` / `trunc` | CNOT copy / wire selection |
| loops | bounded unrolling with MUX-frozen loop-carried values |
| `call` | gate-level inlining via recursive compilation |

### `lower.jl` is a shim too

As with extraction: `src/lower.jl` is an **18-line `include` shim**, not the ~3k-line monolith older docs describe. The implementation is split across `src/lowering/`:

| File | Responsibility |
|------|----------------|
| `src/lowering/types.jl` | structs (`LoweringResult`, `GateGroup`, `LoweringCtx`) + the `_lower_inst!` dispatch table |
| `src/lowering/operand.jl` | `resolve!` (operand → wires), SSA liveness analysis |
| `src/lowering/driver.jl` | the `lower()` entry point, constant folding, the per-block walk |
| `src/lowering/cfg.jl` | back-edge detection, topological sort, loop unrolling |
| `src/lowering/phi.jl` | **path-predicate computation and PHI resolution** — the #1 correctness-risk file |
| `src/lowering/arith.jl` | binops, shifts, icmp, select, casts, `_pick_add_strategy` / `_pick_mul_strategy` |
| `src/lowering/aggregate.jl` | div/rem, GEP/pointer offsets, loads, struct aggregates |
| `src/lowering/call.jl` | gate-level call inlining |
| `src/lowering/memory.jl` | reversible mutable memory (alloca/store/load strategies) — the largest piece |

To add a new instruction handler you do **not** edit a dispatch line in the block walker. You add a `_lower_inst!(ctx::LoweringCtx, inst::YourOp, ::Symbol)` method in `src/lowering/types.jl` plus the emitter in the appropriate `src/lowering/*.jl` file; the block walker calls `_lower_inst!` generically.

### Arithmetic strategy dispatch

Reversible arithmetic is not one algorithm per operation — it is a cost surface, and the right point on it depends on what you are optimising for. `lower_binop!` routes `:add` and `:mul` through `_pick_add_strategy` / `_pick_mul_strategy` (`src/lowering/arith.jl`), honoring the `add=` / `mul=` kwargs threaded down from `reversible_compile`.

| `add=` | Primitive | Shape |
|--------|-----------|-------|
| `:ripple` | `lower_add!` (`src/adder.jl`) | O(n) depth, out-of-place |
| `:cuccaro` | `lower_add_cuccaro!` (`src/adder.jl`) | O(n) depth, in-place, 1 ancilla |
| `:qcla` | `lower_add_qcla!` (`src/qcla.jl`) | O(log n) depth, out-of-place, O(n) ancilla |
| `:auto` | **always `:ripple`** | preserves the gate-count baselines |

`add=:auto` **always** resolves to ripple-carry. The older "Cuccaro when the second operand is dead, ripple otherwise" heuristic was removed: Cuccaro's one-wire saving is erased by Bennett's copy-out, and it has worse Toffoli-depth. Cuccaro is now reached only by an explicit `add=:cuccaro`.

| `mul=` | Primitive | Shape |
|--------|-----------|-------|
| `:shift_add` | `lower_mul!` (`src/multiplier.jl`) | O(W²) Toffoli, O(W²) Toffoli-depth |
| `:qcla_tree` | `lower_mul_qcla_tree!` (`src/mul_qcla_tree.jl`) | O(W²) Toffoli, O(log²W) Toffoli-depth, self-reversing |
| `:auto` | `:shift_add` at `target=:gate_count`, `:qcla_tree` at `target=:depth` | |

There is **no Karatsuba**: `mul=:karatsuba` was removed (2026-04-27) and now throws. It was 1.9–3.5× worse on Toffoli count than schoolbook for every width up to 64; the crossover is past W=128. The dispatcher accepts only `:auto`, `:shift_add`, `:qcla_tree`.

The payoff is visible on a 32×32 multiply, where the two strategies sit at very different points on the cost surface:

```julia
c1 = reversible_compile((x, y) -> x * y, Int32, Int32)                 # default => shift_add
toffoli_depth(c1)   # => 180

c2 = reversible_compile((x, y) -> x * y, Int32, Int32; mul=:qcla_tree)
toffoli_depth(c2)   # => 56
```

The framework is additive: a new strategy plugs into `_pick_{add,mul}_strategy` without touching any call site.

### The WireAllocator

Every gate names its wires by integer index. Handing out those indices is the job of `WireAllocator` (`src/wire_allocator.jl`), a deliberately tiny structure — about fifty lines — with two parts:

- a **bump pointer** `next_wire`, incremented when a fresh wire is needed, and
- a **free-list** of wires returned by `free!`, kept **sorted descending** so that `pop!` (which removes the last element) returns the *minimum* free wire in O(1).

`allocate!(wa, n)` returns `n` wires, drawing from the free-list before bumping. The descending sort is a small but load-bearing detail: reusing the lowest available index keeps wire numbers compact, which matters because peak live wires is one of the metrics the pebbling strategies optimise.

The allocator is also a fail-fast surface. `allocate!` rejects negative `n` (a silent zero-trip loop once produced an empty wire vector that blew up far downstream as a `BoundsError`). `free!` rejects a double-free via a linear scan of the free-list — O(N²) worst case, but acceptable at Bennett's allocator sizes, and far cheaper than the bug it prevents: handing the same wire to two distinct consumers. And a freed wire must be in the zero state; freeing a dirty wire is a contract violation, not a convenience.

### Phi resolution and the false-path-sensitization bug class

This is the most subtle part of the compiler, and the one with the most scar tissue. An LLVM `phi` node merges values arriving from different predecessor blocks: at a control-flow join, the value is "whatever came in along the edge we actually took". A reversible circuit has no notion of "the edge we took" — every gate fires unconditionally. So phi nodes must be lowered to **MUX circuits**, conditioned on bits that encode which path was live.

The naive approach — resolve a phi by reachability, muxing on the branch conditions that *could* lead to each incoming value — has a well-known failure mode borrowed from VLSI verification: **false-path sensitization**. In a diamond CFG, where both arms of an outer `if` feed the same inner phi, a MUX condition for one arm can fire even when that arm's guard was false. The result is a silently wrong value and, worse, ancillae that do not return to zero. The v0.5 soft-float overflow bug was exactly this.

The fix is **path predicates**, grounded in Gated SSA / Psi-SSA theory (`src/lowering/phi.jl`). Every basic block gets a single-bit **predicate wire** that holds 1 iff execution reached that block. The entry block's predicate is a NOT into a constant; a merge block's predicate is the OR of its incoming **edge predicates**; and each edge predicate is the AND of the source block's predicate with the branch condition (or its negation) that selects that edge:

```
edge_pred(src -> true-target)  = AND(block_pred[src], cond)
edge_pred(src -> false-target) = AND(block_pred[src], NOT cond)
edge_pred(src -> unconditional)= block_pred[src]
```

Because the edge predicates leaving any block are **mutually exclusive**, exactly one MUX in the resolution chain fires. `resolve_phi_predicated!` chains `lower_mux!` (four gates per bit: three CNOTs and a Toffoli) over the incoming values, conditioned on those edge predicates. This is correct for *any* CFG topology — diamonds, multi-way merges, nested conditionals — not just simple if/else.

Two structural invariants defend this guarantee, and they are asserted, not assumed: every predicate is a **single-bit** wire, and a block's predecessor list must contain **distinct** entries. A duplicated predecessor would let one value contribute twice and break "exactly one fires"; the assertion turns that into an immediate crash. The legacy reachability-based resolver was deleted outright so that only this one path exists — two phi resolvers in the highest-risk file would be an invitation for them to drift.

The lesson generalises to soft-float, and explains a design choice covered below: any construct that lowers to a `phi` inherits this risk, so the soft-float library is written to avoid producing phis at all.

## Stage 3 — Bennett: gates to a reversible circuit

A raw `LoweringResult` computes `f(x)` but leaves a trail of dirty intermediate wires. Bennett's 1973 construction cleans them. `bennett(lr)` (`src/bennett_transform.jl`) does three things:

1. **Forward** — apply all gates in order, computing `f(x)` and every intermediate.
2. **Copy** — CNOT-copy the output wires onto fresh copy wires.
3. **Reverse** — apply all gates in reverse order, uncomputing every intermediate.

Afterwards the input wires hold `x`, the copy wires hold `f(x)`, and every ancilla is back to zero. This works because each of the three gates is an involution: applying the forward sequence and then its reverse is the identity, except that the copy step has already captured the answer. The cost is roughly `2 × length(lr.gates) + n_out` gates and `n_out` extra wires.

The reference: Charles H. Bennett, "Logical Reversibility of Computation", *IBM J. Res. Dev.* 17(6):525–532, 1973, [doi:10.1147/rd.176.0525](https://doi.org/10.1147/rd.176.0525). (The 1989 "Time/Space Trade-Offs" paper, [doi:10.1137/0218053](https://doi.org/10.1137/0218053), is a different result — do not conflate the two DOIs.)

### The self-reversing fast path

Some primitives end with clean ancillae already — the Sun-Borissov QCLA-tree multiplier, the QROM table lookups, most soft-float kernels. For these, the copy-and-reverse pass would only double the gate count without changing the output. When `lr.self_reversing == true`, `bennett` runs the forward gates only, after validating the claim with a battery of deterministic probes (all-zero, all-one, and walking-1 on the first and last input wires) that assert ancillae return to zero and inputs are preserved. Since this validation is built in, a mis-marked primitive crashes loudly rather than producing a subtly broken circuit. The fast path is honored by **all** strategies, not just the default.

### Six space-time strategies

`bennett` is dispatched on a strategy tag (`src/bennett_strategies.jl`):

```julia
bennett(lr; strategy::BennettStrategy = DefaultStrategy())
```

There are six concrete strategies: `DefaultStrategy` (the plain forward+copy+reverse above), `EagerStrategy` (gate-level dead-end uncompute, PRS15-flavoured), `ValueEagerStrategy` (PRS15 Algorithm 2: group-level EAGER with Kahn reverse-topological uncompute), `CheckpointStrategy`, `PebbledStrategy(max_pebbles)` (Knill 1995 recursion), and `PebbledGroupStrategy(max_pebbles)` (group-level pebbling with wire reuse). Five legacy aliases — `eager_bennett`, `value_eager_bennett`, `checkpoint_bennett`, `pebbled_bennett`, `pebbled_group_bennett` — are exported as zero-overhead forwarders. Note that `bennett` itself is **not** exported; reach it as `Bennett.bennett`.

Every non-default strategy refuses branching CFGs and falls back to `DefaultStrategy`: their dependency analysis cannot see wire-level cross-dependencies through the synthetic predicate groups a branch introduces. Loop-bearing results also fall back to the default, which is the only strategy that implements the loop-convergence copy-out. The earlier SAT-based pebbling experiment (`sat_pebbling.jl`, Meuli 2019) was deleted along with its PicoSAT dependency; a modern-solver replacement is tracked but unimplemented.

### The wire-partition invariant

The `ReversibleCircuit` constructor (`src/gates.jl`) enforces a four-set partition of `1:n_wires`: **inputs**, **outputs**, **ancillae**, and **loop-check** wires. Ancillae must be disjoint from inputs and outputs; loop-check wires disjoint from all three; and the union must cover every wire with nothing unclassified.

One subtlety often gets stated wrong: it is **not** true that "input wires are never targeted by any gate". Input ∩ output overlap is explicitly *permitted*, precisely so self-reversing primitives (soft-float, QROM) can write their results back onto the input wires. The invariant that actually holds is ancilla and loop-check **disjointness** — that is what guarantees the ancillae are zero on the way out.

The fourth class, **loop-check** wires (`LoopGuard`), exists because data-dependent loops are unrolled a fixed K times. Each loop contributes one guard wire that holds 1 iff the loop converged within K iterations; `simulate` errors loudly if it finds a zero, so an input that needed more than K iterations is a crash, never a silent wrong answer.

### Lifting to a controlled circuit

`controlled(c)` wraps a circuit so it takes an explicit control bit: `(ctrl, x, 0) -> (ctrl, x, ctrl ? f(x) : 0)`. It promotes each gate up one rung — NOT becomes CNOT, CNOT becomes Toffoli, Toffoli becomes three Toffolis plus a shared ancilla — and classifies the control bit as the inner circuit's first input wire. This is the seam for quantum control (`when(qubit) do f(x) end` in Sturm.jl):

```julia
c  = reversible_compile(x -> x + Int8(1), Int8)
cc = controlled(c)

simulate(cc, true,  Int8(42))   # => 43   (control on: computes f(x))
simulate(cc, false, Int8(42))   # => 0    (control off: output register stays 0)
```

Note the off-branch leaves the output register at 0 — it does not pass the input through.

## Stage 4 — Simulate

`simulate(circuit, input)` (`src/simulator.jl`) is the ground truth. It allocates a `Bool` vector for all wires, loads the input bits, applies each gate in sequence, **asserts every ancilla wire is zero**, checks the input wires are preserved, and reads back the output. For a multi-output circuit it returns a `Tuple` of `Integer`s; otherwise a single `Integer`:

```julia
f(x::Int8) = x*x + Int8(3)*x + Int8(1)
c = reversible_compile(f, Int8)

simulate(c, Int8(5))    # => 41
gate_count(c).total     # => 482   (NOT = 14, CNOT = 300, Toffoli = 168)
verify_reversibility(c) # => true
```

`verify_reversibility(c; n_tests=100)` wraps this in a random sweep. The companion metrics in `src/diagnostics.jl` — `gate_count`, `ancilla_count`, `constant_wire_count`, `depth`, `t_count` (= 7 × Toffoli), `toffoli_depth`, `t_depth(;decomp=:ammr|:nc_7t)`, `peak_live_wires` — are how the project pins regression baselines and reads cost trade-offs.

## Memory models

Mutable memory in a reversible circuit is its own design space, dispatched per allocation site by `_pick_alloca_strategy` (`src/lowering/memory.jl`). The five paths trade differently:

- **QROM** (read-only table lookup) — when a `getelementptr` indexes a compile-time-constant global. A binary decision tree of Toffolis (Babbush-Gidney 2018): for a table of `L` entries it costs `2(L-1)` Toffoli gates and O(L·W) CNOTs, with a T-count of `4(L-1)` that is **independent of the word width W**.
- **Shadow memory** (universal store/load) — a CNOT-copy pattern (the Enzyme/Moses-Churavy 2020 shadow trick): `3W` CNOTs per store, `W` per load, zero Toffolis.
- **MUX-EXCH** — when `N·W ≤ 64`, an in-register MUX exchange for dynamically-indexed small arrays.
- **shadow-checkpoint** — the fallback when `N·W > 64`.
- **Persistent maps** — under `mem=:persistent`, a persistent-map data structure (`persistent_impl ∈ {:linear_scan, :okasaki, :hamt, :cf}`; linear scan is the default and, at all measured scales, the winner).

A Feistel network (`emit_feistel!`) for bijective hashing exists at roughly `4W` Toffolis (Luby-Rackoff 1988) but is **never** auto-dispatched — it is opt-in only.

The QROM path is what `target=:gate_count` reaches for a small lookup table. For example, a 4-entry S-box indexed by the low two bits compiles to a 114-gate circuit:

```julia
sbox(x::UInt8) = (UInt8(0x63), UInt8(0x7c), UInt8(0x77), UInt8(0x7b))[(x & UInt8(0x3)) + 1]
gate_count(reversible_compile(sbox, UInt8))
# => (total = 114, NOT = 10, CNOT = 96, Toffoli = 8)
```

## Key design decisions

### Why LLVM IR (not tracing or overloading)

Operating at the LLVM level means any language that lowers to LLVM — Julia, C via clang, Rust via rustc — can feed the compiler, exactly as Enzyme does automatic differentiation at the LLVM level. There is no custom number type to thread through your code, no operator overloading to intercept, no source rewriting. You write plain Julia on plain integers; the compiler reads the IR the optimiser already produced. The cost is that LLVM IR is not a stable API, which is why `src/extract/` is the single point of contact and is built to adapt to LLVM rather than pin its output.

### Why branchless soft-float

IEEE 754 is full of conditional behaviour — NaN, Inf, subnormals, rounding modes. Written with ordinary branches, that control flow becomes LLVM `phi` nodes, and phi nodes are exactly the construct that risks false-path sensitization in MUX lowering (see Stage 2). So the soft-float library (`src/softfloat/`, the `SoftFloatLib` module, sixty exported `soft_*` primitives) is written **branchlessly**: `ifelse` instead of `if`, which LLVM lowers to `select` instead of `phi`, sidestepping the entire bug class. The core operations — `+`, `-`, `*`, `/`, negate, fma, sqrt, all comparisons, all conversions, rounding, min/max — are **bit-exact** against Julia's native `Float64`. The transcendentals (`exp`, `log`, `sin`, `cos`, `pow`, the hyperbolics, …) are within ≤2 ulp, not bit-exact, and each one is tested over its subnormal-output range so the garbage-output class of bug is caught up front. `Float32` is rejected entirely: there are no native f32 primitives, so an f32 path would have to double-round through f64 and would not be bit-exact.

### Why Bennett plus pebbling

Bennett's 1973 construction is simple and provably correct, but it keeps every intermediate value live until the reverse pass, using O(T) ancillae. For real programs that is wasteful. The pebbling strategies (Knill's recursion, the EAGER variants, checkpointing) trade gate count for peak wire usage — recomputing intermediates instead of storing them, the reversible analogue of the classic pebble game. The right trade-off depends on the target: a classical CMOS backend cares about gate count, a NISQ device cares about qubit count, a fault-tolerant backend cares about T-depth. Keeping the construction pluggable lets one `LoweringResult` be scheduled six different ways.

### Why per-op strategy dispatch

The same logic applies one level down, to arithmetic. There is no single best reversible adder or multiplier — there is a cost surface, and you choose a point on it. Classical CMOS minimises gate count; NISQ minimises ancilla; fault-tolerant quantum minimises Toffoli-depth. The strategy dispatchers let a caller pick per operation without touching compiler internals: `reversible_compile(f, T; mul=:qcla_tree)` routes every `mul` in `f` through the O(log²W)-depth Sun-Borissov multiplier, paying in extra Toffolis and ancillae for shallower depth. New strategies are additive — they register with `_pick_{add,mul}_strategy` and the call sites are untouched.

## File map

A corrected, current view of the source tree (the directories that matter for the pipeline):

```
src/
  Bennett.jl              module + reversible_compile front door + CompileOptions
  softfloat_dispatch.jl   the internal SoftFloat struct (routes Float64 ops to soft_*)
  ir_types.jl             IRInst hierarchy + the ParsedIR / LoweringResult contracts
  ir_extract.jl           25-line include shim over src/extract/
  extract/                ~19 files: instructions, intrinsics, module walk, sret, vectors, callees
  lower.jl                18-line include shim over src/lowering/
  lowering/               types, operand, driver, cfg, phi, arith, aggregate, call, memory
  wire_allocator.jl       bump pointer + descending free-list
  gates.jl                NOTGate, CNOTGate, ToffoliGate, LoopGuard, ReversibleCircuit
  bennett_transform.jl    _bennett_default + self-reversing fast path + probe battery
  bennett_strategies.jl   BennettStrategy + 6 subtypes + bennett() dispatch
  controlled.jl           controlled() lifting (NOT->CNOT->Toffoli promotion)
  simulator.jl            bit-vector simulate + ancilla/input invariants
  diagnostics.jl          gate_count, ancilla_count, depth, t_count, toffoli_depth, verify_reversibility
  adder.jl                ripple-carry + Cuccaro in-place
  qcla.jl                 Draper-Kutin-Rains-Svore 2004 carry-lookahead adder
  multiplier.jl           shift-and-add multiplier
  mul_qcla_tree.jl        Sun-Borissov 2026 polylog-depth multiplier (self-reversing)
  divider.jl              soft_udiv / soft_urem (registered callees)
  dep_dag.jl              dependency DAG for the pebbling strategies
  pebble/                 pebbling.jl, eager.jl, value_eager.jl, pebbled_groups.jl
  qrom.jl                 Babbush-Gidney 2018 QROM (Toffoli decision tree)
  shadow_memory.jl        universal reversible store/load
  feistel.jl              reversible Feistel network (opt-in)
  softfloat/              SoftFloatLib module: IEEE 754 binary64 in integer arithmetic
  persistent/             Persistent module: persistent-map data structures
```

Note what is *not* here: there is no `ir_parser.jl` and no `sat_pebbling.jl` — both were deleted. And `lower.jl` / `ir_extract.jl` are shims, not the implementation; look in `src/lowering/` and `src/extract/`.

## The BennettVM target

The pipeline does not have to end at a gate circuit. `reversible_compile(f, T; target=:reversible_vm)` forks at the `ParsedIR` stage and hands off to the sibling **BennettVM** compiler, returning a `BennettVM.VMProgram` instead of a `ReversibleCircuit`. Bennett.jl exposes the seam through a write-once backend hook (`_REVERSIBLE_VM_BACKEND`): until you run `using BennettVM`, a `:reversible_vm` compile errors with a message telling you to load it; once BennettVM's `__init__` registers itself, the target is live. This is shipped, not aspirational — end-to-end programs round-trip through it today. Bennett.jl deliberately does not depend on BennettVM (that would be a dependency cycle); the dependency runs the other way.

---

For the public surface — every kwarg, every metric, every supported input type — see the [API reference](../reference/api.md). For the project's first principles, see the [README](../../../README.md).
