# BennettIR.jl v0.5 — Float64

**STATUS: COMPLETED v0.5** — historical PRD; preserved as the v0.5 milestone reference.

## One-line summary

Reversibly compile plain Julia functions on Float64 via LLVM IR. A Float64 is
64 bits. The circuit doesn't care that they represent a floating point number.

---

## 1. The key insight (again)

IEEE 754 floating point operations are deterministic bit-level functions.
`fadd double %a, %b` takes 128 input bits and produces 64 output bits via a
fixed algorithm (unpack, align, add mantissas, normalise, round, repack).
Bennett doesn't need to know it's a float. It just needs the bit function.

We don't implement IEEE 754 from scratch in gates. We let LLVM lower `fadd`
to integer operations (shifts, adds, comparisons on the exponent and mantissa
fields), then reversibilise those integer operations with our existing
infrastructure.

---

## 2. Strategy: software float via LLVM

LLVM can lower floating-point operations to integer-only implementations.
This is how soft-float targets work (embedded systems without FPU). The
idea:

1. Take a Julia function on Float64
2. Get LLVM IR (will contain `fadd`, `fmul`, `fcmp`, etc.)
3. Lower the LLVM module to a soft-float target that expands float ops
   into integer operations
4. Walk the resulting integer-only IR with our existing pipeline
5. Bennett construction as usual

If soft-float lowering via LLVM target isn't straightforward, the alternative:

**Alternative: use Julia's pure-Julia float implementation.**

Julia's `Base` contains pure-Julia implementations of float operations for
bootstrapping. Or we can write thin wrappers that decompose float ops into
bit manipulation using `reinterpret`, bitwise ops, and integer arithmetic:

```julia
function soft_fadd(a::UInt64, b::UInt64)::UInt64
    # Unpack
    sign_a = (a >> 63) & 0x1
    exp_a = (a >> 52) & 0x7ff
    mant_a = a & 0x000fffffffffffff
    # ... align, add, normalise, round, repack
    # All integer operations — our existing pipeline handles these
end
```

Then `reversible_compile(soft_fadd, UInt64, UInt64)` just works with our
existing Int64/UInt64 infrastructure. The Julia→LLVM→gates pipeline sees
only integer ops.

---

## 3. Approach: try both, ship whichever works first

### Approach A: LLVM soft-float target

Use LLVM.jl to compile the function for a soft-float target (e.g.,
`--target=riscv32` without float extension, or use LLVM's
`-soft-float` attribute). LLVM replaces `fadd`/`fmul` with calls to
compiler-rt functions (`__adddf3`, `__muldf3`, etc.) which are pure
integer implementations.

Problem: these may be opaque `call` instructions if the compiler-rt
library isn't linked. We'd need LTO to inline them.

### Approach B: Pure-Julia soft-float wrapper

Write (or find) pure-Julia implementations of `+`, `-`, `*`, `/` for
Float64 expressed as UInt64 bit manipulation. Compile THAT with our
existing pipeline.

This is the more controlled approach. We know exactly what code is
being compiled. No LLVM soft-float machinery needed.

### Approach C: Direct float instruction lowering

Add `fadd`, `fmul`, `fsub`, `fdiv`, `fcmp` as first-class LLVM opcodes
in our parser/lowerer. For each, emit the reversible IEEE 754 circuit
directly as a sequence of our existing integer gates.

This gives the tightest circuits but requires implementing the IEEE 754
algorithms as gate sequences.

**Recommendation: Start with Approach B.** Write `soft_fadd(::UInt64, ::UInt64)::UInt64`
in pure Julia using only integer operations. Compile it with the existing
pipeline. If it works, you've proven Float64 support. Then decide whether
to optimise via Approach A or C.

---

## 4. IEEE 754 Double-Precision Format

```
63    62-52     51-0
sign  exponent  mantissa
 1     11 bits   52 bits
```

- Value = (-1)^sign × 2^(exponent - 1023) × 1.mantissa
- Special cases: ±0, ±Inf, NaN (exponent = 0 or 2047)

## 5. Soft-Float Operations to Implement

### 5.1 Addition (soft_fadd)

```
Input: a::UInt64, b::UInt64 (bit patterns of two Float64)
Output: UInt64 (bit pattern of a + b in IEEE 754)

Algorithm:
1. Unpack sign, exponent, mantissa from both inputs
2. Handle special cases (zero, inf, nan) — these are just comparisons
3. Align mantissas: shift smaller mantissa right by exponent difference
4. Add or subtract mantissas (depending on signs)
5. Normalise: find leading 1, shift mantissa, adjust exponent
6. Round: apply round-to-nearest-even on the shifted-out bits
7. Repack sign, exponent, mantissa into 64-bit result
```

All steps are integer operations: shifts, adds, comparisons, bitwise ops.
Our pipeline already handles all of these.

### 5.2 Multiplication (soft_fmul)

```
1. Unpack
2. Handle special cases
3. Add exponents (subtract bias)
4. Multiply mantissas (53×53 → 106 bit product)
   This is the expensive part: O(53²) = O(2809) Toffolis
5. Normalise + round
6. Repack
```

### 5.3 Comparison (soft_fcmp)

```
1. Handle NaN (any NaN → unordered)
2. Handle signs (negative < positive)
3. Compare exponents (larger exponent → larger magnitude)
4. Compare mantissas (if exponents equal)
5. Flip result if both negative
```

All integer comparisons. Cheap.

### 5.4 Negation (soft_fneg)

Flip bit 63. One NOT gate.

### 5.5 Division (soft_fdiv) — stretch goal

Division is more complex (restoring or non-restoring division on mantissas).
Defer to v0.6 if addition and multiplication work.

### 5.6 Conversions

| LLVM instruction | Meaning | Implementation |
|---|---|---|
| `sitofp i64 %x to double` | Signed int → float | Pure integer algorithm |
| `fptosi double %x to i64` | Float → signed int | Pure integer algorithm |
| `uitofp` | Unsigned int → float | Similar |
| `fptoui` | Float → unsigned int | Similar |
| `fpext float to double` | Widen float | Bit manipulation |
| `fptrunc double to float` | Narrow float | Bit manipulation + rounding |
| `bitcast double to i64` | Reinterpret bits | Zero gates (wire aliasing) |
| `bitcast i64 to double` | Reinterpret bits | Zero gates (wire aliasing) |

---

## 6. Implementation Plan

### Phase 1: Soft-float library in pure Julia

Write pure-Julia functions using only UInt64 integer operations:

- [ ] `soft_fadd(a::UInt64, b::UInt64)::UInt64`
- [ ] `soft_fmul(a::UInt64, b::UInt64)::UInt64`
- [ ] `soft_fneg(a::UInt64)::UInt64`
- [ ] `soft_fcmp_olt(a::UInt64, b::UInt64)::UInt8` (ordered less-than)
- [ ] `soft_fcmp_oeq(a::UInt64, b::UInt64)::UInt8` (ordered equal)

Test these against Julia's native float operations:

```julia
for _ in 1:100000
    a = rand() * 200 - 100
    b = rand() * 200 - 100
    a_bits = reinterpret(UInt64, a)
    b_bits = reinterpret(UInt64, b)
    result_bits = soft_fadd(a_bits, b_bits)
    result = reinterpret(Float64, result_bits)
    @assert result == a + b  # must be bit-exact, not approximate
end
```

This phase is pure Julia, no BennettIR involvement. Just verify the soft-float
library is bit-exact.

### Phase 2: Compile soft-float through existing pipeline

- [ ] `reversible_compile(soft_fadd, UInt64, UInt64)` — use existing pipeline
- [ ] Verify: `simulate(circuit, (a_bits, b_bits)) == soft_fadd(a_bits, b_bits)`
  for a range of float values
- [ ] Print gate count for soft_fadd, soft_fmul
- [ ] All ancillae zero

This phase may require no new code at all if the soft-float library uses only
operations the pipeline already handles (integer add, subtract, multiply,
shift, bitwise, comparison, ifelse). If it does require new ops, add them.

### Phase 3: Float-aware frontend

Add a convenience layer so the user writes natural Float64 code:

```julia
f(x::Float64) = x * x + 3.0 * x + 1.0

circuit = reversible_compile(f, Float64)

# Test
for x in [-5.0, -1.0, 0.0, 0.5, 1.0, 3.14, 100.0]
    @assert simulate_float(circuit, x) == f(x)  # bit-exact
end
```

Implementation:
- [ ] When `reversible_compile` sees Float64 arguments, intercept
- [ ] Replace the function body's float ops with soft-float calls
  (via Cassette.jl overdubbing, or by compiling a wrapper that calls
  soft-float functions on UInt64 reinterpretations)
- [ ] OR: parse `fadd`/`fmul`/`fcmp` opcodes in LLVM IR and lower them
  by inlining the soft-float circuits directly
- [ ] `simulate_float(circuit, x)`: reinterpret Float64 → UInt64,
  simulate, reinterpret UInt64 → Float64
- [ ] Test with various float values including edge cases: 0.0, -0.0,
  Inf, -Inf, very small numbers (subnormals), very large numbers

### Phase 4: Float64 + control flow

- [ ] `g(x::Float64) = x > 0.0 ? x * x : -x` — float comparison + branches
- [ ] Compile and verify
- [ ] Controlled version: `controlled(circuit)`, verify ctrl=1/0
- [ ] Gate counts for all float tests

---

## 7. Test Programs

### 7.1 Float addition (via soft-float library)
```julia
circuit = reversible_compile(soft_fadd, UInt64, UInt64)
a, b = 3.14, 2.72
a_bits, b_bits = reinterpret(UInt64, a), reinterpret(UInt64, b)
result = simulate(circuit, (a_bits, b_bits))
@assert reinterpret(Float64, result) == a + b
```

### 7.2 Float polynomial (end goal)
```julia
f(x::Float64) = x * x + 3.0 * x + 1.0
circuit = reversible_compile(f, Float64)
for x in [0.0, 1.0, -1.0, 0.5, 3.14]
    @assert simulate_float(circuit, x) == f(x)
end
```

### 7.3 Newton's method step (stretch)
```julia
# One step of Newton's method for sqrt(a): x_{n+1} = (x + a/x) / 2
# Requires fdiv — stretch goal
function newton_sqrt_step(x::Float64, a::Float64)
    return (x + a / x) * 0.5
end
```

### 7.4 Edge cases
```julia
# All of these must produce bit-exact results
test_pairs = [
    (0.0, 0.0),      # 0 + 0
    (1.0, -1.0),     # cancellation
    (1e308, 1e308),   # overflow → Inf
    (1e-308, 1e-308), # near subnormal
    (Inf, 1.0),       # Inf arithmetic
    (Inf, -Inf),      # Inf - Inf = NaN
    (NaN, 1.0),       # NaN propagation
]
```

---

## 8. File structure changes

```
BennettIR.jl/
├── src/
│   ├── ... (existing files)
│   ├── softfloat/
│   │   ├── softfloat.jl        # NEW: module definition
│   │   ├── fadd.jl             # NEW: soft_fadd
│   │   ├── fmul.jl             # NEW: soft_fmul
│   │   ├── fcmp.jl             # NEW: soft_fcmp_*
│   │   ├── fneg.jl             # NEW: soft_fneg
│   │   └── conversions.jl      # NEW: sitofp, fptosi, bitcast
│   └── float_frontend.jl       # NEW: Float64-aware reversible_compile
└── test/
    ├── ... (existing tests)
    ├── test_softfloat.jl        # NEW: soft-float library correctness
    ├── test_float_circuit.jl    # NEW: reversible soft-float circuits
    ├── test_float_end_to_end.jl # NEW: f(x::Float64) = x*x + 3x + 1
    └── test_float_edge.jl       # NEW: 0, Inf, NaN, subnormal
```

---

## 9. Expected gate counts

Rough estimates based on the operations involved:

| Operation | Dominant cost | Estimated gates |
|---|---|---|
| `soft_fadd` | 53-bit mantissa add + shift + normalise | ~5,000–15,000 |
| `soft_fmul` | 53×53 mantissa multiply | ~20,000–50,000 |
| `soft_fcmp` | Exponent + mantissa comparison | ~500–1,000 |
| `soft_fneg` | 1 NOT gate | 1 |
| `x*x + 3x + 1` (full polynomial) | 2 fmul + 2 fadd | ~70,000–130,000 |

These are large but polynomial. Bennett doubles them (forward + uncompute).
Controlled version adds ~1.6x on top. Total for a controlled float polynomial:
~200,000–400,000 gates. Large. Correct.

---

## 10. Success criteria

1. `soft_fadd(a, b)` is bit-exact against Julia's `+` for 100,000 random pairs
2. `reversible_compile(soft_fadd, UInt64, UInt64)` produces a correct circuit
   verified against soft_fadd for 1,000 random float pairs
3. All ancillae zero
4. `f(x::Float64) = x * x + 3.0 * x + 1.0` compiles and produces correct
   results for a set of test values
5. Edge cases (0, Inf, NaN, subnormals) handled correctly
6. All v0.2, v0.3, v0.4 tests still pass

## 11. Constraints

- Do NOT modify existing tests or pipeline code
- The soft-float library must be BIT-EXACT against IEEE 754. Not approximately
  correct. Not within epsilon. Bit-exact. Use `reinterpret(UInt64, result)` to
  compare bit patterns. One wrong bit in the mantissa means the circuit is wrong.
- If soft_fadd is too large for the existing pipeline to handle in reasonable
  time/memory, implement a simpler float format first (e.g., 8-bit minifloat:
  1 sign + 3 exponent + 4 mantissa) as a stepping stone, then scale to Float64.
- Start with addition and multiplication. Division is a stretch goal.
- The soft-float implementations should be pure Julia using only integer
  operations that the existing pipeline already handles. No new gate types.
