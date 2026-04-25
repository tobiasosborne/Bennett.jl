# BennettIR.jl — LLVM-Level Reversible Compilation POC

**STATUS: COMPLETED v0.2** — historical PRD; preserved as the v0.2 milestone reference.

## One-line summary

Take a plain Julia function on plain integers, extract its LLVM IR, walk the IR instructions, emit a reversible circuit. No special types. No operator overloading.

---

## 1. Why this exists

Bennett.jl proved that reversible compilation works via operator overloading on a
custom `Traced` type. That approach has a ceiling: it only sees operations that
dispatch on `Traced`. It can't see inside library code, ccall, or any code that
inspects the value representation directly.

Enzyme solved this by operating at LLVM IR — below the language, where every
Julia function is a sequence of primitive instructions regardless of how it was
written. BennettIR.jl is a minimal experiment to test whether the same approach
works for reversible compilation.

The question this POC answers: **can we mechanically walk LLVM IR and emit
correct reversible circuits?**

---

## 2. Scope

This is a tracer bullet. The absolute minimum vertical slice.

**In scope:**
- Extract LLVM IR from a plain Julia function via `InteractiveUtils.code_llvm` or
  the Julia compiler internals (`Core.Compiler`)
- Parse enough LLVM IR to handle: `add`, `sub`, `mul`, `and`, `or`, `xor`,
  `shl`, `lshr`, `icmp`, `select`, `ret`, and integer constants
- Map each LLVM instruction to reversible gates (reuse Bennett.jl's lowering)
- Bennett construction (forward + copy + uncompute)
- Bit-vector simulator to verify
- Works on Int8 functions (8-bit, exhaustively verifiable)

**Out of scope:**
- Loops, branches, phi nodes (basic blocks beyond a single straight-line block)
- Memory operations (load, store, alloca, getelementptr)
- Function calls (call instructions)
- Floating point
- Multi-argument functions (start with single Int8 → Int8)
- Optimisation, pebbling
- Any integration with Enzyme itself

**Stretch goals (attempt if core works quickly):**
- Multi-argument functions (two Int8 inputs)
- `br` + `phi` (simple if/else, two basic blocks merging)

---

## 3. How Julia exposes LLVM IR

Julia compiles every method specialisation to LLVM IR. You can access it:

```julia
# Human-readable LLVM IR as a string
code_llvm(f, (Int8,))

# Or programmatically via the compiler internals
using InteractiveUtils
# code_llvm prints to stdout; to capture as string:
ir = sprint(code_llvm, f, (Int8,))
```

For `f(x::Int8) = x + 3`, the IR will look something like:

```llvm
define i8 @julia_f_123(i8 signext %0) {
  %1 = add i8 %0, 3
  ret i8 %1
}
```

For `g(x::Int8) = x * x + 3 * x + 1`:

```llvm
define i8 @julia_g_456(i8 signext %0) {
  %1 = mul i8 %0, %0
  %2 = mul i8 %0, 3
  %3 = add i8 %1, %2
  %4 = add i8 %3, 1
  ret i8 %4
}
```

The IR for simple arithmetic on small integers is clean: no memory ops, no
branches, just straight-line SSA with `add`, `mul`, `sub`, etc.

We do NOT need a full LLVM IR parser. We need to parse the tiny subset that
appears in the output of `code_llvm` for simple integer arithmetic functions.

---

## 4. Design

### 4.1 Pipeline

```
Julia function + type signature
    ↓  code_llvm()
LLVM IR string
    ↓  parse (minimal regex/string parser)
List of SSA instructions
    ↓  lower (each instruction → reversible gates)
Forward gate sequence
    ↓  Bennett construction (forward + copy + uncompute)
ReversibleCircuit
    ↓  simulate + verify
Correctness confirmed
```

### 4.2 IR representation (internal)

```julia
# We only need to represent the instructions we care about.
# This is NOT a general LLVM IR parser.

abstract type IRInst end

struct IRAdd <: IRInst
    dest::Symbol      # SSA name, e.g. :var1
    op1::IROperand
    op2::IROperand
    width::Int        # bit width (8 for i8)
end

struct IRMul <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRSub <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRAnd <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IROr <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRXor <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRShl <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRLShr <: IRInst
    dest::Symbol
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRICmp <: IRInst
    dest::Symbol
    predicate::Symbol  # :eq, :ne, :ult, :slt, :ugt, :sgt, :ule, :sle, :uge, :sge
    op1::IROperand
    op2::IROperand
    width::Int
end

struct IRSelect <: IRInst
    dest::Symbol
    cond::IROperand    # i1
    op1::IROperand     # true value
    op2::IROperand     # false value
    width::Int
end

struct IRRet <: IRInst
    op::IROperand
    width::Int
end

# Operands are either SSA names or constants
struct IROperand
    kind::Symbol       # :ssa or :const
    name::Symbol       # SSA name (if :ssa)
    value::Int         # constant value (if :const)
end
```

### 4.3 Parser

A line-by-line regex parser. Each instruction in LLVM IR has a predictable format:

```
%dest = add i8 %op1, %op2
%dest = add i8 %op1, 3
%dest = mul i8 %op1, %op2
%dest = icmp eq i8 %op1, %op2
%dest = select i1 %cond, i8 %val1, i8 %val2
ret i8 %op
```

Parse rules:
1. Skip lines starting with `;` (comments) or that are labels/metadata
2. Match `%name = op type operand, operand` pattern
3. Operands are either `%name` (SSA) or integer literals
4. Extract dest, op, type width, operand1, operand2

This does NOT need to be robust. It needs to handle the output of `code_llvm`
for the specific test functions. If an instruction is unrecognised, error with a
clear message including the line.

### 4.4 Lowering: IR instructions → reversible gates

Each IR instruction maps to a reversible subcircuit. The mapping reuses the same
gate primitives as Bennett.jl (NOT, CNOT, Toffoli).

Each SSA variable gets a fresh W-bit wire register. The instruction's output is
computed on these fresh wires from the input wires. Input wires are not consumed.

| LLVM instruction | Reversible lowering |
|-----------------|---------------------|
| `add i8 %a, %b` | Ripple-carry adder: fresh output = a + b |
| `add i8 %a, 3` | Load constant 3 on fresh wires, then add |
| `sub i8 %a, %b` | Adder in reverse (subtract) |
| `mul i8 %a, %b` | Shift-and-add multiplier |
| `and i8 %a, %b` | Toffoli per bit |
| `or i8 %a, %b` | De Morgan: NOT inputs, AND, NOT output |
| `xor i8 %a, %b` | CNOT per bit |
| `shl i8 %a, n` | Wire permutation (shift left by constant) |
| `lshr i8 %a, n` | Wire permutation (shift right by constant) |
| `icmp eq i8 %a, %b` | XOR + OR-reduce + NOT → 1-bit output |
| `icmp slt i8 %a, %b` | Subtraction, extract sign bit |
| `select i1 %c, i8 %a, i8 %b` | MUX: same as Bennett.jl's ifelse lowering |
| `ret i8 %a` | Mark output wires |

**IMPORTANT:** If the adder/multiplier/comparator code can be shared with
Bennett.jl, factor it into a shared package or just copy it. Do not create a
dependency between the two POCs — they should be independent experiments.

### 4.5 Bennett construction

Identical to Bennett.jl. Forward pass → CNOT-copy output → reverse pass.
No changes needed. The gate-level representation is the same.

### 4.6 Simulator

Identical to Bennett.jl. Bit-vector simulator. Can be copied verbatim.

---

## 5. Test Programs

### 5.1 Increment (minimal)

```julia
f(x::Int8) = x + Int8(3)
circuit = reversible_compile(f, Int8)
for x in typemin(Int8):typemax(Int8)
    expected = (x + Int8(3)) % Int8  # wrapping arithmetic
    @assert simulate(circuit, x) == expected
end
```

### 5.2 Polynomial

```julia
g(x::Int8) = x * x + Int8(3) * x + Int8(1)
circuit = reversible_compile(g, Int8)
for x in Int8(0):Int8(15)  # keep small to avoid overflow confusion
    @assert simulate(circuit, x) == g(x)
end
```

### 5.3 Bitwise

```julia
h(x::Int8) = (x & Int8(0x0f)) | (x >> 2)
circuit = reversible_compile(h, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == h(x)
end
```

### 5.4 Comparison + select (stretch)

```julia
k(x::Int8) = x > Int8(10) ? x + Int8(1) : x + Int8(2)
circuit = reversible_compile(k, Int8)
for x in typemin(Int8):typemax(Int8)
    @assert simulate(circuit, x) == k(x)
end
```

### 5.5 Two arguments (stretch)

```julia
m(x::Int8, y::Int8) = x * y + x - y
circuit = reversible_compile(m, Int8, Int8)
for x in Int8(0):Int8(15), y in Int8(0):Int8(15)
    @assert simulate(circuit, (x, y)) == m(x, y)
end
```

---

## 6. Implementation Plan

**Phase 1: IR extraction and parsing**
- [ ] Function to extract LLVM IR string from a Julia function + type tuple
- [ ] Line-by-line parser for SSA instructions
- [ ] Test: parse IR of `f(x::Int8) = x + Int8(3)`, verify instruction list
- [ ] Test: parse IR of `g(x::Int8) = x * x + Int8(3) * x + Int8(1)`
- [ ] Print parsed instructions for manual inspection

**Phase 2: Lowering to reversible gates**
- [ ] Wire allocator
- [ ] SSA name → wire register mapping
- [ ] Lower `add`, `sub` (ripple-carry adder, copy from Bennett.jl)
- [ ] Lower `mul` (shift-and-add, copy from Bennett.jl)
- [ ] Lower constants (NOT gates on zero register)
- [ ] Lower `and`, `or`, `xor`, `shl`, `lshr`
- [ ] Lower `ret` (mark output wires)
- [ ] Test: lower `f(x::Int8) = x + Int8(3)`, inspect gate list

**Phase 3: Bennett + simulate**
- [ ] Bennett construction (copy from Bennett.jl or reimplement)
- [ ] Bit-vector simulator (copy from Bennett.jl or reimplement)
- [ ] Test: full pipeline for `x + 3`, verify all 256 inputs
- [ ] Test: full pipeline for polynomial, verify

**Phase 4: Comparison + select (stretch)**
- [ ] Lower `icmp` (eq, slt, sgt, etc.)
- [ ] Lower `select` (mux)
- [ ] Test: `x > 10 ? x + 1 : x + 2` for all 256 inputs

**Phase 5: Multi-argument (stretch)**
- [ ] Handle multiple function arguments in IR parsing
- [ ] Test: `m(x, y) = x * y + x - y`

---

## 7. File structure

```
BennettIR.jl/
├── Project.toml
├── src/
│   ├── BennettIR.jl            # module definition, exports
│   ├── ir_extract.jl           # get LLVM IR string from Julia function
│   ├── ir_types.jl             # IRInst, IROperand definitions
│   ├── ir_parser.jl            # line-by-line LLVM IR parser
│   ├── wire_allocator.jl       # fresh wire allocation
│   ├── gates.jl                # NOTGate, CNOTGate, ToffoliGate
│   ├── lower.jl                # IR instructions → reversible gates
│   ├── adder.jl                # ripple-carry adder
│   ├── multiplier.jl           # shift-and-add multiplier
│   ├── comparator.jl           # icmp lowering
│   ├── mux.jl                  # select lowering
│   ├── bennett.jl              # forward + copy + uncompute
│   ├── simulator.jl            # bit-vector simulator
│   └── diagnostics.jl          # gate_count, depth, print stats
└── test/
    ├── runtests.jl
    ├── test_parse.jl           # verify IR parsing
    ├── test_increment.jl       # x + 3
    ├── test_polynomial.jl      # x^2 + 3x + 1
    ├── test_bitwise.jl         # bitwise ops
    ├── test_compare.jl         # icmp + select (stretch)
    └── test_two_args.jl        # multi-input (stretch)
```

---

## 8. Key Risk: LLVM IR stability and Julia compiler internals

The LLVM IR output from `code_llvm` is NOT a stable API. Julia may change:
- Optimisation passes that rewrite the IR into forms we don't recognise
- SSA naming conventions
- Metadata format

Mitigation for this POC:
- Use `code_llvm(f, (Int8,), raw=true, optimize=false)` to get unoptimised IR.
  This produces more verbose but more predictable instruction sequences.
- If Julia's IR is too complex even unoptimised, try `optimize=true` — LLVM
  optimisation may actually SIMPLIFY the IR (constant folding, dead code
  elimination) making it easier to parse.
- Print the raw IR in test output so failures are diagnosable.
- If `code_llvm` output is hard to parse, investigate using Julia's typed IR
  (SSA form from `code_typed`) instead, which is higher-level and more stable.
  The tradeoff: it's Julia-specific rather than LLVM-generic.

**Fallback:** If LLVM IR parsing proves too fragile, pivot to `code_typed` (Julia's
own SSA IR). This is higher-level but still gives you the instruction-by-instruction
view. The experiment still validates the core thesis: can you go from plain Julia
functions to reversible circuits without special types?

---

## 9. Success Criteria

The POC succeeds when:

1. `f(x::Int8) = x + Int8(3)` — a completely plain Julia function with NO special
   types — compiles to a reversible circuit that is correct for all 256 inputs
2. `g(x::Int8) = x * x + Int8(3) * x + Int8(1)` — same
3. All ancillae verified zero after every simulation
4. The user never imported BennettIR.jl when writing `f` and `g`. The functions are
   standard Julia. The reversible compilation happens after the fact.

That last point is the whole thesis. The source code doesn't know it will be
reversibilised. The compiler does it.

---

## 10. What we learn from this

Regardless of success or failure, this POC answers:

**If it works:**
- LLVM IR (or Julia typed IR) is a viable level for reversible compilation
- The Enzyme-style approach (operate below the language) is feasible for Bennett
- The path to P8 (universal quantum control in Sturm.jl) goes through compiler IR,
  not operator overloading
- Next step: handle `br`/`phi` (control flow), then `load`/`store` (memory),
  then investigate using Enzyme's analysis passes directly

**If LLVM IR parsing is too fragile:**
- Pivot to Julia's `code_typed` SSA IR (more stable, Julia-specific)
- The thesis (plain functions → reversible circuits) may still hold at a higher IR level
- Informs whether Enzyme integration (which operates at LLVM IR) needs a Julia-IR
  adapter layer

**If the IR is fundamentally unsuitable:**
- Operator overloading (Bennett.jl approach) is the correct fallback
- P8 in Sturm.jl should be scoped to functions written with Sturm types only
- Still valuable: we learned the boundary of what's possible
