# John Carmack Reviews Bennett.jl

**Date:** 2026-04-11
**Codebase:** 5,599 lines of Julia across 30 source files
**Scope:** Full read of all src/, src/softfloat/, sampling of test/ and WORKLOG.md

---

## Overall Assessment

This is a real compiler. It actually works. That puts it ahead of 90% of academic
projects I have seen. The pipeline is clean: LLVM IR in, reversible gates out,
bit-vector simulation to verify. The architecture is sound. The test coverage is
serious -- exhaustive Int8 verification over all 256 inputs, 1000+ random tests
for soft-float, SHA-256 round function as an integration test. The Bennett
construction itself is 28 lines. The core idea is beautiful in its simplicity.

But this is a compiler that generates 265K gates for a single floating-point
multiply, then simulates them one gate at a time on a Bool array. There are
serious engineering problems between "it works" and "it ships." I am going to
focus on those.

The codebase reads like it was built by disciplined agents following good
process. TDD, regression baselines, WORKLOG. That is the right way to build
a compiler. What I want to see next is the shift from "does it work" to "can
it handle real workloads" -- and that requires attacking the performance and
memory problems I will detail below.

---

## What Works Well

1. **The pipeline is clean and modular.** Extract -> Lower -> Bennett -> Simulate.
   Each stage has a clear contract. You can test each stage independently. This
   is the right architecture.

2. **Bennett construction is dead simple.** `bennett.jl` is 28 lines. Forward,
   CNOT-copy, reverse. The `sizehint!` on line 14 shows someone thought about
   allocation. The invariant (all ancillae return to zero) is verified in every
   simulation. Good.

3. **Exhaustive testing for small widths.** Testing all 256 Int8 inputs is the
   gold standard. You know it works for Int8. The gate count regression baselines
   (86, 174, 350, 702 -- exactly 2x per doubling) give confidence in the scaling.

4. **The soft-float implementation is genuinely impressive.** Writing bit-exact
   IEEE 754 fadd/fmul/fdiv in branchless integer arithmetic, then compiling those
   to reversible circuits -- that is a non-trivial achievement. The fact that it
   passes 1000+ random tests against hardware floats means it is correct.

5. **Multiple Bennett strategies.** Full Bennett, EAGER, value-level EAGER,
   pebbled, checkpoint, SAT-based pebbling. This shows serious understanding of
   the space-time tradeoff landscape. The checkpoint_bennett in pebbled_groups.jl
   is particularly clever -- forward, checkpoint result, reverse, reuse wires.

6. **The callee inlining mechanism.** `lower_call!` recursively compiles callees
   and inlines their forward gates with wire remapping. This is how you build
   composable systems. Registering soft-float functions for gate-level inlining
   via `register_callee!` is a clean design.

7. **Cuccaro in-place adder.** The optimization in adder.jl to use Cuccaro's
   algorithm when the second operand is dead (liveness analysis determines this)
   is exactly the kind of targeted optimization that matters. 1 ancilla instead
   of W-1.

---

## Performance Analysis

### The Simulation Hot Loop

`simulator.jl` lines 1-3 are the entire inner loop:

```julia
apply!(b::Vector{Bool}, g::NOTGate)     = (b[g.target] ^= true; nothing)
apply!(b::Vector{Bool}, g::CNOTGate)    = (b[g.target] ^= b[g.control]; nothing)
apply!(b::Vector{Bool}, g::ToffoliGate) = (b[g.target] ^= b[g.control1] & b[g.control2]; nothing)
```

This is clean, correct, and *catastrophically slow for large circuits.*

For a 265K-gate fmul circuit, you are doing 265,000 dynamic dispatches on
`ReversibleGate` (abstract type), each touching one Bool in a `Vector{Bool}`.
Julia's `Vector{Bool}` stores one Bool per byte, not per bit. So for a circuit
with 100K wires, you are using 100KB of memory for the state vector, and every
gate access is a random byte-level load/store.

**Impact:** For the SHA-256 round function (5,818 gates) this is fine. For
soft_fmul (265K gates), simulation of one input pair takes O(265K) dynamic
dispatches. The test suite runs 100 random pairs, so that is 26.5M gate
evaluations with type dispatch overhead. For soft_fdiv (even larger with the
56-iteration restoring division loop), this is going to be painful.

**Fix, staged by priority:**

1. **Immediate (2x-4x):** Use `BitVector` instead of `Vector{Bool}`. Julia's
   `BitVector` packs 64 bits per UInt64 word. Gate operations become bit
   operations on packed words. Memory drops from 1 byte/wire to 1 bit/wire.

2. **Medium term (5x-10x):** Encode gates as a flat array of integers instead
   of `Vector{ReversibleGate}`. Use a tag byte for gate type, then 1-3 wire
   indices. This eliminates the abstract type dispatch. Process gates in a
   tight loop with a switch on the tag. Julia will JIT this into a tight
   branch-based loop.

3. **Long term (10x-50x):** For batch simulation (testing all 256 Int8 inputs),
   simulate 64 inputs simultaneously using UInt64 words -- each bit position
   is a different input. One pass over 86 gates tests 64 inputs. This turns
   256-input exhaustive testing into 4 simulation passes.

### Circuit Construction

The gate list is a `Vector{ReversibleGate}`. Every `push!(gates, ...)` is a
dynamic allocation of a small struct (1-3 Ints) on the heap, pushed into a
vector that grows with amortized doubling. For 265K gates, this is 265K small
allocations. Julia's GC will handle this, but it is not free.

The `bennett()` function does `append!(all_gates, lr.gates)` then
`append!(all_gates, reverse(lr.gates))`. The `reverse(lr.gates)` creates a
full copy of the gate vector. For 265K forward gates, that is 265K allocations
just for the reverse copy. The Bennett circuit has 530K + n_out gates total.

**Fix:** `reverse(lr.gates)` should be `Iterators.reverse(lr.gates)`. Wait --
you cannot `append!` from a lazy iterator directly with the same underlying
array (the forward gates are already in `all_gates`). The current approach
copies the forward gates, appends, copies the reverse, appends. Better: build
`all_gates` by iterating forward once, pushing copy gates, then iterating
backward. No intermediate `reverse()` allocation.

### Wire Allocator

`wire_allocator.jl` line 23-28: `free!` does a linear scan
(`searchsortedfirst`) and `insert!` into the middle of a sorted vector. Both
are O(n) per call. If you free 10K wires (which happens in pebbled_groups.jl),
each insert is O(n) into a growing list. Total cost: O(n^2) for n frees.

**Fix:** Use a proper min-heap (`DataStructures.BinaryMinHeap`) or just a
`Set{Int}` with `pop!`. The sorted-list approach is fine for small circuits
but will bite when pebbled_groups frees thousands of wires repeatedly.

### Compilation Time

`lower_call!` at lower.jl:1377 recursively calls `extract_parsed_ir` and
`lower` for every callee. For soft_fdiv, which calls `soft_fadd` (indirectly
via floor/ceil), this means re-extracting and re-lowering the same function
multiple times. There is no caching of compiled callees.

**Fix:** Add a `Dict{Function, LoweringResult}` cache. First call compiles;
subsequent calls reuse. This is a classic memoization problem. For the current
soft-float suite it probably does not matter (each function is called once), but
for any composition of float operations, it will.

---

## Data Structure & Memory Review

### Gate Representation

`gates.jl` defines three struct types, all subtypes of `ReversibleGate`:

```julia
struct NOTGate <: ReversibleGate
    target::WireIndex     # 8 bytes
end
struct CNOTGate <: ReversibleGate
    control::WireIndex    # 8 bytes
    target::WireIndex     # 8 bytes
end
struct ToffoliGate <: ReversibleGate
    control1::WireIndex   # 8 bytes
    control2::WireIndex   # 8 bytes
    target::WireIndex     # 8 bytes
end
```

`WireIndex = Int` = 8 bytes on 64-bit. A Toffoli gate is 24 bytes, a NOT is
8 bytes, a CNOT is 16 bytes. But because they are stored in `Vector{ReversibleGate}`
(abstract type), Julia boxes each element. Every gate is a heap-allocated object
with a type tag pointer. On 64-bit Julia, each boxed gate is approximately
32-48 bytes with GC overhead. A 265K-gate circuit uses roughly 8-12 MB just
for gate storage.

For a 1M-gate circuit (say, multiple float ops composed), that is 32-48 MB.
Not terrible, but wasteful.

**Fix:** Use a struct-of-arrays representation:

```julia
struct FlatCircuit
    types::Vector{UInt8}     # 0=NOT, 1=CNOT, 2=Toffoli
    wire1::Vector{Int32}     # target for NOT, control for CNOT/Toffoli
    wire2::Vector{Int32}     # target for CNOT, control2 for Toffoli
    wire3::Vector{Int32}     # target for Toffoli (0 for NOT/CNOT)
end
```

4 bytes * 3 + 1 byte = 13 bytes per gate. A 265K circuit drops from ~10 MB
to ~3.5 MB. Cache locality improves dramatically because the simulation loop
reads types sequentially, then wire indices sequentially. This is the kind of
data-oriented design that gives you 3x-5x on modern CPUs.

Also: `Int32` for wire indices. You will not have 2 billion wires. 32-bit
indices halve the memory vs Int64, and they fit in cache lines better.

### Ancilla Wire List

In `bennett.jl` line 24:

```julia
ancillae = [w for w in 1:total if !(w in in_set) && !(w in out_set)]
```

This iterates over ALL wires 1:total and checks set membership for each.
`in_set` and `out_set` are `Set{Int}`, so each lookup is O(1). The
comprehension allocates a new array. For a circuit with 100K wires, this
allocates a ~100K-element vector. Fine, but it is done in every Bennett variant
(bennett, eager_bennett, value_eager_bennett, pebbled_group_bennett,
checkpoint_bennett -- I count 5 copies of this exact pattern). Factor it out.

### ReversibleCircuit Memory

A `ReversibleCircuit` holds `gates::Vector{ReversibleGate}`, `input_wires`,
`output_wires`, `ancilla_wires` (all `Vector{WireIndex}`), plus a few
`Vector{Int}` for widths. For a soft_fmul circuit:
- gates: ~530K elements (~15 MB boxed)
- ancilla_wires: ~100K elements (~800 KB)
- Total: ~16 MB per circuit

For a composition of 10 float operations (a realistic Sturm.jl use case):
~160 MB. That is getting uncomfortable. The flat representation would cut
this to ~50 MB.

---

## Simulation Hot Path

The simulation loop in `_simulate` (simulator.jl:14-30):

```julia
bits = zeros(Bool, circuit.n_wires)    # 1 byte per wire
# ... load inputs ...
for gate in circuit.gates              # abstract type iteration
    apply!(bits, gate)                 # dynamic dispatch per gate
end
# ... check ancillae, read output ...
```

Problems:

1. **Dynamic dispatch on every gate.** Julia will compile three specializations
   of `apply!`, but the loop dispatches dynamically because `gate` has abstract
   type `ReversibleGate`. Julia typically handles this with union-splitting
   (since there are only 3 concrete types), which should turn this into a
   branch-based dispatch. But still -- for 265K gates, that is 265K branches.

2. **Random memory access.** Each gate reads/writes 1-3 bytes at arbitrary
   positions in the `bits` array. No spatial locality. For 100K wires, the
   bits array is 100KB -- fits in L2 cache on modern CPUs but not L1. Every
   gate is an L1 miss waiting to happen.

3. **No vectorization possible.** The simulation is inherently sequential --
   gate N's output affects gate N+1's input. You cannot SIMD this in the
   normal direction. But you CAN batch across inputs (simulate 64 inputs
   simultaneously with UInt64 bitwise ops -- see recommendation above).

4. **Ancilla check at the end** (line 26-28): iterates over all ancilla wires
   and checks each bit. For 100K ancillae, this is 100K Bool loads. Not a
   bottleneck (runs once per simulation), but for production you would want
   to just check that all non-input, non-output wires are zero by scanning
   the bits array once.

**The single most impactful optimization for this codebase is batched
simulation.** One pass over the gates, operating on UInt64 words where each
bit is a different input. For exhaustive Int8 testing (256 inputs), this turns
256 simulation passes into 4. For random testing with 100 inputs, it turns 100
passes into 2. The speedup is 50x-64x at the cost of replacing
`Vector{Bool}` with `Vector{UInt64}` and rewriting 3 lines of `apply!`.

---

## Soft-Float Circuit Size

The elephant in the room. From the WORKLOG and test expectations:

| Function   | Gates      | Wires  |
|-----------|------------|--------|
| soft_fadd  | ~94K       | ~30K   |
| soft_fmul  | ~265K      | ~85K   |
| soft_fdiv  | enormous   | huge   |

These numbers are *per operation*. A function like `f(x) = x*x + x` on Float64
would need one fmul (~265K) and one fadd (~94K) = ~360K gates. A dot product
of two 3-vectors is 3 fmul + 2 fadd = ~980K gates. A single SHA-256 round is
5,818 gates on UInt32. The float circuits are 50x-100x larger.

Why are they so large? Three factors:

1. **Schoolbook multiplication.** The 53x53-bit mantissa multiply in fmul.jl
   uses a half-word decomposition (4 partial products of ~27x26 bits), each
   assembled with `lower_mul!` which is a shift-and-add O(W^2) multiplier.
   A 27x26-bit schoolbook multiply generates O(27*26) = O(700) Toffoli gates
   per partial product. Four of them plus additions to assemble = major gate
   count.

2. **Bennett doubling.** The Bennett construction doubles the gate count
   (forward + reverse). For a lowering with N forward gates, Bennett produces
   2N + n_output gates. So if lowering produces 132K gates, Bennett gives 265K.

3. **Branchless computation.** Every soft-float function computes ALL code
   paths (normal, subnormal, infinity, NaN, zero) unconditionally and selects
   the result. This is correct for reversible compilation (no phi/branch
   issues), but it means every special case adds gates even when it does not
   apply. The select chains at the end of fadd.jl (lines 189-200) are 12
   conditional selects, each generating W=64 MUX circuits = 768 Toffoli gates
   just for the final select chain.

**Optimization opportunities:**

1. **Karatsuba multiplication is already implemented!** `multiplier.jl` has
   `lower_mul_karatsuba!` (line 36-113). But it is gated behind `use_karatsuba`
   which defaults to false. For 53-bit mantissa multiplication, Karatsuba would
   reduce from O(W^2) to O(W^1.585). For W=27 sub-products, this is a meaningful
   improvement. Enable it and measure.

2. **The 56-iteration restoring division loop in fdiv.jl** (lines 48-56) is the
   dominant cost for fdiv. Each iteration does a comparison (>= is a
   subtractor), a conditional subtract, and a shift. That is O(56 * 64) ~
   3500 operations per iteration, times 56 iterations = ~200K gate-level
   operations before Bennett doubling. A Newton-Raphson approach (estimate +
   2-3 multiply-and-correct iterations) would use ~3-4 multiplications instead
   of 56 division steps. At 265K per multiply, that is not obviously better --
   but with Karatsuba multiplies, it could be.

3. **Constant folding.** `lower.jl` has a `_fold_constants` pass (lines 323-416)
   but it is disabled by default (`fold_constants::Bool=false`). For soft-float
   circuits, many wires carry compile-time constants (masks, bias values).
   Folding these eliminates gates whose controls are known-zero (no-op) or
   known-one (reduces to simpler gate). Enable and measure.

---

## API & Integration Readiness

The user-facing API is clean:

```julia
circuit = reversible_compile(f, Int8)
result = simulate(circuit, x)
```

For Sturm.jl integration, the path is:

```julia
circuit = reversible_compile(f, UInt32, UInt32)
cc = controlled(circuit)
# Use cc in quantum circuit
```

**What works for integration:**

- `reversible_compile` accepts plain Julia functions with standard types
- `controlled()` wraps any circuit with a control wire
- The gate types (NOT, CNOT, Toffoli) are the right abstraction for quantum backends
- Error messages are generally clear (fail-fast philosophy is well-implemented)

**What needs work:**

1. **No incremental composition.** You cannot take two compiled circuits and
   compose them (series or parallel). You must compile the entire function as
   a monolith. For Sturm.jl, you will want `c3 = compose(c1, c2)` and
   `c_par = parallel(c1, c2)`.

2. **Float64 compilation is fragile.** The SoftFloat dispatch trick (lines
   74-141 of Bennett.jl) depends on Julia inlining through the wrapper. The
   comment says `@inline` at the call site is required. This is a fragile
   contract -- Julia's inliner is a heuristic, not a guarantee. If the inliner
   decides not to inline for a complex function, the compilation silently
   produces wrong code (struct-passing ABI that ir_extract cannot handle).
   There should be a verification step that checks the generated LLVM IR
   does not contain unexpected alloca/store patterns.

3. **max_loop_iterations is a footgun.** If the user's function has a loop and
   they forget this parameter, they get a hard error. If they set it too low,
   they get wrong results (the loop does not complete). There should be a
   verification mode that detects incomplete loop unrolling (exit condition
   never fires) and errors.

4. **No resource estimation before compilation.** For a Sturm.jl developer,
   the question "how many qubits does this need?" should be answerable without
   running the full compilation. A quick static analysis of the LLVM IR
   (count instructions, estimate gate count) would help.

---

## Risk Assessment

### Single Biggest Risk: LLVM Version Compatibility

The entire system depends on `code_llvm` producing IR that `ir_extract.jl`
can parse. Every Julia version update potentially changes the LLVM IR output.
The two-pass name table approach (keyed on `LLVMValueRef` C pointers) is
robust against naming changes, but structural changes (new instruction
patterns, different optimization passes, changed calling conventions) will
break things.

The `_known_callees` lookup in ir_extract.jl:42-49 uses substring matching
on LLVM function names:

```julia
function _lookup_callee(llvm_name::String)
    for (jname, f) in _known_callees
        if occursin(jname, lowercase(llvm_name))
            return f
        end
    end
    return nothing
end
```

This is brittle. LLVM name mangling can change between versions. The
`lowercase` comparison adds a layer of defense, but this is still string
matching on compiler-internal names. A single LLVM upgrade that changes
the mangling of `j_soft_fadd` to `julia_soft_fadd_12345` would break
every float operation.

**Mitigation:** Pin the LLVM.jl version. Add a CI job that runs on nightly
Julia to detect breakage early. Consider using Julia's native method lookup
to identify callees instead of string matching on LLVM names.

### Second Risk: Phi Resolution Correctness

The phi resolution algorithm in lower.jl (lines 714-868) is complex and
has known fragility (false-path sensitization). The CLAUDE.md explicitly
warns about this. The branchless soft-float approach was adopted specifically
to avoid phi resolution bugs. This means the system has a known weakness that
it is routing around rather than fixing.

For Sturm.jl integration, users will write functions with branches. Those
branches will hit the phi resolution code path. The fact that the developers
themselves chose to avoid branches in the soft-float code tells you the phi
resolution is not fully trusted.

### Third Risk: Scale

The current system works for single operations on small to medium integers
(Int8 through Int64) and single float operations. Composing multiple float
operations (e.g., a 10-line physics simulation) will produce millions of
gates. The simulation time for testing will become prohibitive. The memory
usage will become non-trivial. The wire allocator's O(n^2) free list will
become a bottleneck. None of these are fundamental problems, but they are
all problems that need solving before real use.

---

## Specific Findings

### Severity scale: [CRITICAL] can cause wrong results, [HIGH] major perf/usability, [MEDIUM] should fix, [LOW] cleanup

1. **[HIGH]** `simulator.jl:16` -- `zeros(Bool, circuit.n_wires)` allocates
   1 byte per wire. For 265K-wire circuits, this is 265KB per simulation.
   Use `BitVector` for 8x memory reduction and better cache behavior.
   Impact: 2x-4x simulation speedup.

2. **[HIGH]** `bennett.jl:21` -- `reverse(lr.gates)` allocates a full copy
   of the gate vector. For 265K gates, this is ~8MB of temporary allocation.
   Fix: iterate backward directly instead of materializing the reverse.
   Impact: 50% reduction in peak memory during circuit construction.

3. **[HIGH]** `gates.jl` -- Abstract type `Vector{ReversibleGate}` causes
   boxing of every gate. For 530K-gate circuits, this is ~16MB of heap
   allocations with GC pressure. Fix: flat struct-of-arrays representation.
   Impact: 3x-5x memory reduction, significant GC reduction.

4. **[MEDIUM]** `wire_allocator.jl:24-28` -- `free!` uses O(n) insertion
   into a sorted vector. For pebbled_groups.jl which frees wires repeatedly,
   this becomes O(n^2). Fix: use a binary min-heap.
   Impact: Matters only for large circuits with aggressive wire reuse.

5. **[MEDIUM]** `ir_extract.jl:42-49` -- Callee lookup via substring
   matching on LLVM names is fragile across Julia/LLVM versions. Fix:
   use a more robust identification mechanism (e.g., function pointer
   comparison at the Julia level before entering LLVM).
   Impact: Will bite on Julia version upgrade.

6. **[MEDIUM]** `lower.jl:1382-1385` -- `lower_call!` re-extracts and
   re-lowers callees on every call. No caching. Fix: memoize compiled
   callees in a `Dict{Function, LoweringResult}`.
   Impact: Matters when composing multiple float operations.

7. **[MEDIUM]** `Bennett.jl:56-57` -- Global mutable state:
   `_name_counter` and `_known_callees`. These make the compiler
   non-threadsafe. For a single-threaded compiler this is fine, but
   if Sturm.jl wants to compile circuits in parallel, this will race.
   Fix: pass naming state through the compilation context.
   Impact: Blocks future parallelism.

8. **[MEDIUM]** `diagnostics.jl:14-24` -- `depth()` computes circuit
   depth by iterating all gates and maintaining per-wire depth. For 530K
   gates, this is O(gates * max_fan_in) = O(530K * 3). Fine for one call,
   but it is called in `print_circuit` which is called in every test.
   Impact: Test suite slowdown for large circuits.

9. **[MEDIUM]** `diagnostics.jl:110-125` -- `peak_live_wires` runs a
   full simulation just to track which wires are non-zero. This is O(gates)
   with full simulation overhead. If you just need the peak, you can
   compute it from gate topology without simulating.
   Impact: Expensive diagnostic called during optimization analysis.

10. **[LOW]** `ir_parser.jl` -- 168 lines of legacy regex parser still
    included. Not on the critical path. Remove it to reduce maintenance
    surface. One test file (`test_parse.jl`) depends on it.
    Impact: Dead code maintenance burden.

11. **[LOW]** `divider.jl` -- `soft_udiv` and `soft_urem` use 64-iteration
    restoring division loops. When compiled to circuits, each iteration
    generates comparison + conditional subtract + shift = thousands of gates.
    Impact: Division circuits will be very large. Consider long-division
    with smaller iterations for narrow types.

12. **[LOW]** `multiplier.jl:98-104` -- Karatsuba shifts and additions
    allocate intermediate result vectors via `allocate!` + `lower_add!`.
    Each recursive level allocates fresh wires for shifted copies. These
    intermediate wires are never freed. For checkpoint_bennett this is
    fine (they get reversed), but it inflates the wire count unnecessarily.
    Impact: Higher wire count for Karatsuba than necessary.

13. **[MEDIUM]** `lower.jl:486-487` -- DFS-based back-edge detection
    (`find_back_edges`) uses recursive `dfs()`. For deeply nested CFGs
    (100+ blocks), this could stack overflow. Fix: iterative DFS with
    explicit stack.
    Impact: Stack overflow on pathological inputs.

14. **[LOW]** `controlled.jl:47-52` -- Toffoli promotion uses 3 Toffoli
    gates + 1 shared ancilla. This is correct but not optimal. The
    relative-phase Toffoli decomposition uses fewer T-gates. For quantum
    backends that care about T-count, this matters.
    Impact: 7 T-gates per controlled Toffoli instead of 4.

15. **[HIGH]** `simulator.jl:37-50` -- `_read_output` uses untyped
    `vals = []` (line 42), which creates a `Vector{Any}`. Every `push!`
    into this vector boxes the integer value. Fix: `vals = Int[]` or use
    a properly typed container. For single-element returns (the common
    case), this code path is not hit, but for tuple returns it allocates
    unnecessarily.
    Impact: Minor perf issue but indicates lack of type stability attention.

---

## Ship-Readiness Checklist

For minimum viable integration with Sturm.jl:

- [x] Integer arithmetic (Int8 through Int64): **SOLID**. Exhaustively tested,
  gate counts are regression baselines.
- [x] Bitwise operations: **SOLID**. Full coverage.
- [x] Comparisons and select: **SOLID**. All 10 icmp predicates implemented.
- [x] Branches and phi resolution: **WORKS BUT FRAGILE**. Known false-path
  sensitization risk. Tested with nested if/else and diamond CFGs.
- [x] Loop unrolling: **WORKS WITH CAVEATS**. Requires max_loop_iterations.
  No automatic bound detection.
- [x] Tuple returns: **WORKS**. insertvalue + extractvalue.
- [x] Controlled circuits: **SOLID**. NOT/CNOT/Toffoli promotion correct.
- [x] Soft-float (fadd, fmul, fdiv, fcmp, conversions): **WORKS**. Bit-exact.
  But circuit sizes are enormous.
- [ ] Performance at scale: **NOT READY**. Simulation is too slow for 100K+ gates.
- [ ] Memory at scale: **NOT READY**. 265K-gate circuits use ~20MB per circuit.
- [ ] Circuit composition: **NOT IMPLEMENTED**. Cannot compose two circuits.
- [ ] Resource estimation: **NOT IMPLEMENTED**. No way to estimate cost before
  compiling.
- [ ] Error recovery: **PARTIAL**. Errors crash with messages, but the global
  state (`_name_counter`) is left dirty. Subsequent compilations may produce
  wrong names.

---

## Recommendations (ordered by impact)

1. **Implement batched simulation (UInt64 word-parallel).** This is the single
   highest-ROI change. Replace `Vector{Bool}` with `Vector{UInt64}`, simulate
   64 inputs per pass. 50x-64x speedup for testing. 4 hours of work. This
   unblocks serious testing of large circuits.

2. **Enable Karatsuba multiplication by default for W > 16.** Already
   implemented, just gated behind a flag. Measure the gate count reduction
   for soft_fmul's 53-bit mantissa multiplication. Expected: 30-40% fewer
   Toffoli gates in the multiplier, 15-20% fewer total gates.

3. **Enable constant folding by default.** Already implemented in lower.jl
   lines 323-416. For soft-float circuits, many gates operate on known
   constants (masks, bias values). Expected: 5-15% gate reduction.

4. **Replace `reverse(lr.gates)` in bennett.jl with backward iteration.**
   Eliminate the temporary allocation. One-line fix. Expected: 50% reduction
   in peak memory during construction.

5. **Switch to flat gate representation (struct-of-arrays).** This is a
   bigger refactor but gives 3x-5x memory reduction and better cache
   performance for simulation. Touch gates.jl, simulator.jl, bennett.jl,
   diagnostics.jl. Half a day of work.

6. **Add a compilation cache for callees.** Memoize `lower_call!` results.
   Critical for composing multiple float operations. Two hours of work.

7. **Fix wire allocator free list.** Replace sorted vector with min-heap.
   Matters for pebbled/checkpoint constructions. One hour of work.

8. **Add circuit composition primitives.** `series(c1, c2)` and
   `parallel(c1, c2)`. Required for Sturm.jl integration where you build
   circuits incrementally. Half a day of work.

9. **Add a verification mode for loop unrolling.** After unrolling, check
   that the exit condition fired at least once. If it never fired, the loop
   was not fully unrolled and the result is wrong. Error with a helpful
   message suggesting a larger max_loop_iterations.

10. **Pin LLVM.jl version and add version-compatibility CI.** The single
    biggest operational risk is a Julia upgrade breaking LLVM IR extraction.
    Detect this early.

---

## Final Thoughts

This is a well-built prototype that proves a compelling thesis: you can take
arbitrary Julia functions and automatically compile them to reversible circuits
for quantum control. The correctness story is strong. The architecture is clean.
The code quality is high for a research system.

The path to shipping is performance. Not algorithmic correctness -- that is
already there. The bottleneck is the constant factor: gates stored as boxed
abstract types, simulation one gate at a time on uncompressed booleans, no
batching, no caching. These are all fixable in days, not months.

Ship the integer path first. Int8 through Int64, branches, loops, tuples --
all solid. Get Sturm.jl integration working on integer arithmetic. Then
optimize the float path. The soft-float circuits are correct but enormous.
They need the optimizations (Karatsuba, constant folding, better Bennett
strategies) to be practical.

The phi resolution fragility is the technical debt to pay down. The branchless
soft-float approach is a correct workaround, but it means the compiler has a
known weakness for branching code. For Sturm.jl users who write `if x > 0`
in their kernel functions, this needs to work reliably. Invest in better
testing of diamond CFGs and complex control flow.

The project has the fundamentals right. Now it needs engineering focus on the
performance path to make it real.

-- JC
