# BennettIR.jl v0.4 — Wider Integers, Explicit Loops, Arrays

**STATUS: COMPLETED v0.4** — historical PRD; preserved as the v0.4 milestone reference.

## One-line summary

Extend from Int8 to Int64, handle loops LLVM won't unroll, and support
constant-index array reads.

---

## 1. Where we are

v0.3 delivers: plain Julia → LLVM IR → reversible circuit → controlled circuit.
Works for Int8, single and multi-argument, branches, LLVM-unrolled loops.
All ancillae verified zero. Controlled circuits verified.

Limitations:
- Only Int8 (i8). Real code uses Int64.
- Loops only if LLVM unrolls them.
- No arrays / memory access.

## 2. What v0.4 adds

Three features, in priority order. Each is independently useful and testable.

---

## 3. Feature A: Wider Integer Types

### 3.1 What needs to change

The gate-level infrastructure (adder, multiplier, comparator, mux) is already
parameterised by bit width. In principle, going from i8 to i16/i32/i64 is just
wider wires. The question is whether:

1. `code_llvm` produces clean IR for wider types (it should)
2. The parser handles `i16`, `i32`, `i64` type annotations (trivial regex change)
3. The simulator and Bennett construction scale (they should — linear in width)
4. Gate counts are reasonable (they'll be large for i64 but polynomial)

### 3.2 Potential complications

- **LLVM may use different instruction patterns for wider types.** For example,
  i64 multiply might lower to a `call @__muldi3` (compiler-rt helper) on some
  platforms rather than an inline `mul i64`. Check the actual IR.
- **Overflow semantics.** i8 wraps mod 256. i64 wraps mod 2^64. The adder
  circuit already wraps naturally. No change needed.
- **Sign extension.** `sext i8 %x to i64` — extends sign bit. This is a wire
  operation: copy MSB to all upper bits. Must parse and lower this.
- **Zero extension.** `zext i8 %x to i64` — pad with zeros. Even simpler:
  upper wires are already zero.
- **Truncation.** `trunc i64 %x to i8` — take lower 8 bits. Wire selection.

### 3.3 New LLVM instructions to parse

| Instruction | Meaning | Reversible lowering |
|---|---|---|
| `sext i8 %x to i64` | Sign extend | Copy MSB to upper wires (CNOT from MSB to each upper wire) |
| `zext i8 %x to i64` | Zero extend | Upper wires stay zero (no gates) |
| `trunc i64 %x to i8` | Truncate | Take lower 8 wire bits (wire selection, no gates) |

### 3.4 Tests

**Test A1: Int16 arithmetic**
```julia
f(x::Int16) = x * x + Int16(3) * x + Int16(1)
circuit = reversible_compile(f, Int16)
for x in Int16(0):Int16(100)
    @assert simulate(circuit, x) == f(x)
end
```

**Test A2: Int32 arithmetic**
```julia
f(x::Int32) = x * Int32(7) + Int32(42)
circuit = reversible_compile(f, Int32)
# Can't exhaustively test. Use random sampling.
for _ in 1:10000
    x = rand(Int32(0):Int32(10000))
    @assert simulate(circuit, x) == f(x)
end
```

**Test A3: Int64 arithmetic**
```julia
f(x::Int64) = x + Int64(1)
circuit = reversible_compile(f, Int64)
# Test edge cases + random
for x in [0, 1, -1, typemax(Int64), typemin(Int64), rand(Int64, 100)...]
    @assert simulate(circuit, x) == f(x)
end
```

Print gate counts for each width to confirm polynomial scaling.

**Test A4: Mixed width (extension/truncation)**
```julia
f(x::Int8) = Int8(Int16(x) * Int16(x))  # widen, multiply, truncate
circuit = reversible_compile(f, Int8)
for x in Int8(-10):Int8(10)
    @assert simulate(circuit, x) == f(x)
end
```

**Test A5: Signed semantics**
```julia
f(x::Int8) = x < Int8(0) ? -x : x  # absolute value
circuit = reversible_compile(f, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == f(x)
end
```

---

## 4. Feature B: Explicit Loop Handling

### 4.1 The problem

When LLVM doesn't unroll a loop, the IR contains a back-edge: a `br` that
jumps to a previously-defined basic block. v0.3 detects this and errors.

We need to handle it.

### 4.2 Strategy: bounded unrolling in our code

The user provides a maximum iteration count. We unroll the loop body that
many times, each guarded by the loop exit condition.

```
iteration 1: if (cond) { body } else { skip }
iteration 2: if (cond) { body } else { skip }
...
iteration K: if (cond) { body } else { skip }
```

Each "skip" means the body's output wires don't change (mux selects the
identity). When the loop exits early, all remaining iterations are no-ops.

### 4.3 Detecting loops in the IR

A loop is a cycle in the basic block graph. Specifically:

1. A **back-edge**: `br` from block B to block H where H dominates B
   (H appears before B in topological order)
2. A **header** block H: the target of the back-edge, containing a phi
   node for the loop induction variable
3. A **latch** block B: the source of the back-edge
4. An **exit condition**: a conditional `br` in either the header or latch
   that can exit the loop

### 4.4 IR representation

```julia
struct IRLoop
    header::Symbol              # header block label
    latch::Symbol               # latch block label (has back-edge to header)
    exit_block::Symbol          # block jumped to on loop exit
    exit_cond::IROperand        # the i1 condition controlling exit
    exit_on_true::Bool          # true if br takes exit on cond=true
    body_blocks::Vector{Symbol} # blocks inside the loop (header to latch)
    phi_nodes::Vector{IRPhi}    # phi nodes in header (loop-carried variables)
end
```

### 4.5 Lowering loops

```
Given a loop with max_iterations = K:

For each iteration i = 1..K:
    1. Lower the loop body (all blocks from header to latch)
       - First iteration: phi inputs come from the pre-header (entry values)
       - Subsequent iterations: phi inputs come from previous iteration's
         output wires (the latch values)
    2. Compute the exit condition
    3. Mux: if exit condition is true, select "done" (freeze output);
       otherwise, feed outputs back as inputs to next iteration
    
After K iterations:
    The final output wires hold the loop result.
    Bennett uncomputes all intermediate iterations.
```

### 4.6 API for max iterations

```julia
# User specifies the bound:
circuit = reversible_compile(f, Int8; max_loop_iterations=100)

# Or auto-detect for simple constant-bound loops:
# If the loop bound is a constant visible in the IR (e.g., icmp slt i8 %i, 10),
# extract it automatically. Otherwise, require the user to specify.
```

### 4.7 Tests

**Test B1: Simple counted loop (LLVM won't unroll)**
```julia
function sum_to(n::Int8)
    acc = Int8(0)
    for i in Int8(1):n
        acc += i
    end
    return acc
end

circuit = reversible_compile(sum_to, Int8; max_loop_iterations=127)
for n in Int8(0):Int8(15)
    @assert simulate(circuit, n) == sum_to(n)
end
```

**Test B2: While loop**
```julia
function collatz_steps(x::Int8)
    steps = Int8(0)
    val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val ÷ Int8(2)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end

circuit = reversible_compile(collatz_steps, Int8; max_loop_iterations=20)
for x in Int8(1):Int8(30)
    @assert simulate(circuit, x) == collatz_steps(x)
end
```

**Test B3: Nested loop (stretch)**
```julia
function mat_trace_2x2(a::Int8, b::Int8, c::Int8, d::Int8)
    # a b
    # c d
    return a + d
end

# Simple enough to not need loops, but if a nested-loop example is needed:
function dot_product(x1::Int8, x2::Int8, y1::Int8, y2::Int8)
    return x1 * y1 + x2 * y2
end

circuit = reversible_compile(dot_product, Int8, Int8, Int8, Int8)
for x1 in Int8(0):Int8(7), x2 in Int8(0):Int8(7),
    y1 in Int8(0):Int8(7), y2 in Int8(0):Int8(7)
    @assert simulate(circuit, (x1, x2, y1, y2)) == dot_product(x1, x2, y1, y2)
end
```

---

## 5. Feature C: Constant-Index Array Access

### 5.1 What this means

```julia
function get_third(arr::NTuple{4, Int8})
    return arr[3]
end
```

In LLVM IR, a tuple/struct access with a constant index becomes
`extractvalue` or a `getelementptr` + `load` with constant offset.

### 5.2 LLVM instructions

| Instruction | Meaning | Reversible lowering |
|---|---|---|
| `extractvalue {i8, i8, i8, i8} %s, 2` | Get field 2 from struct | Wire selection: output wires = wires of field 2 |
| `insertvalue {i8, i8, i8, i8} %s, i8 %v, 2` | Set field 2 | Wire copy + replacement |
| `getelementptr` + `load` with constant index | Array element access | Wire selection from the flattened wire array |

### 5.3 Representation

Tuples and fixed-size arrays in LLVM IR are aggregate types. Each element
occupies a contiguous range of wires. `extractvalue` just selects that range.
No gates needed — it's a compile-time wire mapping.

`insertvalue` creates a new aggregate with one field replaced. This is a
wire copy of all fields except the replaced one, plus wire copy of the new value.
Cost: O(total_width) CNOTs.

### 5.4 Tests

**Test C1: Tuple access**
```julia
function first_plus_third(t::NTuple{4, Int8})
    return t[1] + t[3]
end

circuit = reversible_compile(first_plus_third, NTuple{4, Int8})
for a in Int8(0):Int8(15), c in Int8(0):Int8(15)
    @assert simulate(circuit, (a, Int8(0), c, Int8(0))) == a + c
end
```

**Test C2: Tuple return**
```julia
function swap_pair(a::Int8, b::Int8)
    return (b, a)
end

circuit = reversible_compile(swap_pair, Int8, Int8)
for a in Int8(0):Int8(15), b in Int8(0):Int8(15)
    @assert simulate(circuit, (a, b)) == (b, a)
end
```

**Test C3: Struct-like computation**
```julia
function complex_mul_real(a_re::Int8, a_im::Int8, b_re::Int8)
    # (a_re + i*a_im) * b_re = a_re*b_re + i*a_im*b_re
    return (a_re * b_re, a_im * b_re)
end

circuit = reversible_compile(complex_mul_real, Int8, Int8, Int8)
for ar in Int8(0):Int8(7), ai in Int8(0):Int8(7), br in Int8(0):Int8(7)
    @assert simulate(circuit, (ar, ai, br)) == complex_mul_real(ar, ai, br)
end
```

---

## 6. Implementation Plan

### Phase 1: Wider integers (Feature A)
- [ ] Update parser to handle `i16`, `i32`, `i64` type widths
- [ ] Parse `sext`, `zext`, `trunc` instructions
- [ ] Lower `sext` (CNOT MSB to upper wires), `zext` (no-op), `trunc` (wire selection)
- [ ] Test: compile and verify Int16 polynomial
- [ ] Test: compile and verify Int32 linear function
- [ ] Test: compile and verify Int64 increment
- [ ] Test: mixed-width with extension/truncation
- [ ] Test: signed semantics (absolute value)
- [ ] Print gate count scaling table: W=8, 16, 32, 64 for same function

### Phase 2: Explicit loop handling (Feature B)
- [ ] Loop detection: identify back-edges, header, latch, exit condition
- [ ] `IRLoop` struct
- [ ] `max_loop_iterations` parameter on `reversible_compile`
- [ ] Bounded unrolling: emit K copies of loop body with exit-condition mux
- [ ] Loop-carried phi: connect latch outputs of iteration i to header inputs of iteration i+1
- [ ] Auto-detect constant bounds from `icmp` in exit condition (optional)
- [ ] Test: sum_to(n) with data-dependent bound
- [ ] Test: collatz_steps with while loop + branches

### Phase 3: Constant-index array/tuple access (Feature C)
- [ ] Parse `extractvalue` instruction
- [ ] Parse `insertvalue` instruction
- [ ] Parse LLVM aggregate types (`{i8, i8, i8, i8}`, `[4 x i8]`)
- [ ] Lower `extractvalue` as wire selection (zero gates)
- [ ] Lower `insertvalue` as wire copy + replacement
- [ ] Handle `NTuple` calling convention (check how Julia passes tuples in LLVM IR)
- [ ] Test: tuple element access
- [ ] Test: tuple return (multiple output values)
- [ ] Test: struct-like computation

### Phase 4: Integration tests
- [ ] Controlled circuit wrapping a loop-based function
- [ ] Controlled circuit wrapping a tuple-accessing function
- [ ] Gate count table for all new tests
- [ ] All v0.2 and v0.3 tests still pass

---

## 7. File structure changes

```
BennettIR.jl/
├── src/
│   ├── ... (existing files)
│   ├── ir_parser.jl            # MODIFIED: wider types, sext/zext/trunc, extractvalue,
│   │                           #           insertvalue, aggregate types
│   ├── lower.jl                # MODIFIED: lower sext/zext/trunc/extractvalue/insertvalue
│   ├── loops.jl                # NEW: loop detection, bounded unrolling
│   └── aggregates.jl           # NEW: aggregate type wire mapping
└── test/
    ├── ... (existing tests)
    ├── test_int16.jl           # NEW
    ├── test_int32.jl           # NEW
    ├── test_int64.jl           # NEW
    ├── test_mixed_width.jl     # NEW
    ├── test_loop_explicit.jl   # NEW
    ├── test_collatz_loop.jl    # NEW
    ├── test_tuple.jl           # NEW
    └── test_v04_combined.jl    # NEW
```

---

## 8. Success criteria

1. `f(x::Int64) = x + Int64(1)` produces a correct reversible circuit
2. Gate count for width W scales as O(W) for addition, O(W²) for multiplication
3. A loop with data-dependent bound (sum_to) compiles with explicit unrolling and
   produces correct results
4. Tuple element access compiles to zero gates (wire selection only)
5. All v0.2 and v0.3 tests still pass
6. All ancillae zero in all new tests

## 9. Constraints

- Do NOT modify existing tests
- For loops: error if `max_loop_iterations` is not provided AND the bound can't
  be auto-detected. Never silently produce a wrong circuit from an insufficient
  iteration bound.
- For wider types: if `code_llvm` produces unexpected instructions (e.g., calls
  to compiler-rt helpers for i64 multiply), error clearly rather than silently
  skipping the instruction
- Tuple tests may require checking how Julia lowers `NTuple` at the LLVM level.
  If Julia passes tuples by pointer rather than by value, the test functions may
  need adjustment. Check the IR first.
