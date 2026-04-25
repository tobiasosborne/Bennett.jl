## Session log — 2026-04-11 (continued): Documentation + narrow bit-width

### Documentation added

- `docs/src/tutorial.md` — 10-section walkthrough, all code snippets verified
- `docs/src/api.md` — complete API reference for all exported functions
- `docs/src/architecture.md` — 4-stage pipeline, file map, design rationale
- README.md updated with Documentation section, corrected gate count baselines

### Narrow bit-width compilation (`bit_width` parameter)

Added `bit_width` kwarg to `reversible_compile`. Compiles Int8 functions as if
they operated on W-bit integers. Implementation: `_narrow_ir()` post-processes
the ParsedIR to replace all instruction widths before lowering.

**Gate count scaling (x+1):**

| Width | Gates | Wires |
|-------|-------|-------|
| Int1  | 11    | 6     |
| Int2  | 22    | 8     |
| Int3  | 35    | 11    |
| Int4  | 48    | 14    |
| Int8  | 100   | 26    |

**Polynomial cost breakdown (Horner form: `(x+3)*x + 1`):**

The multiplier dominates at every width. Even for Int2, `x*x` needs 42 gates
and 15 ancillae due to the shift-and-add algorithm (O(W^2) Toffoli + O(W^2) wires).
LLVM rewrites `x^2 + 3x + 1` into Horner form `(x+3)*x + 1`, so there's one multiply.

| Operation | Int2 gates | Int2 wires | Int4 gates | Int4 wires |
|-----------|-----------|------------|-----------|------------|
| x+1       | 22        | 8          | 48        | 14         |
| x+x       | 6         | 7          | 12        | 13         |
| x*x       | 42        | 19         | 170       | 61         |
| poly      | 80        | 25         | 256       | 71         |

**Gotcha:** Signed comparisons change semantics at narrow widths. In 3-bit signed,
values 4-7 are negative (-4 to -1). `sle` on 3-bit operands treats bit 2 as sign.
Best for unsigned arithmetic or functions staying within the positive range.

### Issues closed in this session (final count)

59 review issues filed, 45 implemented + 14 deferred to future sessions:
- **CRITICAL**: 4/4 done (phi fallback, name counter, remap validation, pebbling docs)
- **HIGH**: 16/20 done (all correctness + testing, 3/4 code quality, 2/4 perf)
- **MEDIUM**: 15/23 done (large refactors deferred)
- **LOW**: 9/12 done (new features deferred)

New test assertions added: ~5,600+ across 10 new test files.
8 git commits for review fixes, 1 for docs, 1 for narrow bit-width.

## Session log — 2026-04-11: Mother of all code reviews

### What was done

6-agent code review (Test Coverage, Architecture/Research, Julia Idioms, Knuth, Torvalds, Carmack).
59 beads issues filed. 19 issues closed in this session.

### Issues closed

**All 4 CRITICAL (P0):**
- C1 (Bennett-y3c): Removed silent fallback to buggy phi resolver — now errors if block_pred empty
- C2 (Bennett-126): Replaced global _name_counter with local Ref{Int} threaded through functions
- C3 (Bennett-9qk): Added _remap_wire() validation in pebbled_groups.jl — unmapped wires now error
- C4 (Bennett-ug9): Documented Knill pebble game vs circuit model distinction + added tests

**HIGH correctness (H1-H4):**
- H1: else error() for unhandled instructions in lower_block_insts!
- H2: Narrowed bare try/catch to MethodError in _get_deref_bytes
- H3: Removed dead resolve! call in lower_ptr_offset!
- H4: Replaced all @assert with error() for core invariants (simulator, controlled, diagnostics)

**HIGH testing (T1-T6):**
- T1: test_soft_sitofp.jl — 1143 tests for Int64→Float64 bit-exact
- T2: ceil(Float64) test added to test_float_intrinsics.jl
- T3: test_gate_count_regression.jl — 13 baseline assertions (updated to current values)
- T4: test_negative.jl — 3 error condition tests
- T5: soft_fcmp_ole/une library tests added to test_softfcmp.jl
- T6: test_constant_wire_count.jl — 5 assertions

**HIGH code quality (Q1, Q4):**
- Q1: Extracted ~150 lines of duplicated soft-float code into softfloat_common.jl
- Q4: Replaced callee substring matching with exact name lookup + regex

**Other:**
- P4: Eliminated reverse(lr.gates) allocation in bennett.jl
- M9: Typed Vector{Any} literals in simulator and lower

### Key gotchas

1. **Gate count baselines shifted**: Path-predicate phi resolution (v0.5) adds block-predicate
   overhead (NOT+CNOT gates). Old baselines (86/174/350/702) are now (100/204/412/828).
   Toffoli counts unchanged (28/60/124/252). New scaling: 2x+4 per width doubling.

2. **Knill pebble game ≠ circuit gate model**: The F(n,s) cost formula describes abstract
   pebble operations. In a circuit, running n gates forward is always n steps. The recursion
   controls WHICH segments are live simultaneously, not total gate count (always 2n-1+n_out).
   Actual space reduction requires group-level pebbling (pebbled_groups.jl).

3. **Callee matching had two paths**: LLVM-mangled names (julia_<name>_NNN from call
   instructions) AND hardcoded bare names ("soft_fcmp_ole" from fcmp intrinsic handling
   in ir_extract.jl). New _lookup_callee handles both: exact dict match first, then regex.

4. **phi_info type**: The loop phi info is Tuple{Symbol, Int, IROperand, IROperand},
   not Tuple{Symbol, Int, Tuple{IROperand,Symbol}, Tuple{IROperand,Symbol}}.

5. **_reset_names! needed as no-op**: Many test files call Bennett._reset_names!() before
   calling extract_parsed_ir directly. With the local counter, the function does nothing
   but must exist for backward compatibility.

## Previous: Next session: Float64 support

The next major challenge is floating-point arithmetic. This requires:

1. **Understanding IEEE 754 at the bit level**: Float64 is 64 bits (1 sign + 11
   exponent + 52 mantissa). Floating-point operations (fadd, fmul, etc.) have
   complex reversible implementations involving integer addition of mantissas,
   exponent alignment, rounding, and normalization.

2. **LLVM IR for float ops**: Julia Float64 operations compile to LLVM `fadd`,
   `fmul`, `fsub`, `fdiv`, `fcmp`, `fpext`, `fptrunc`, `sitofp`, `fptosi`, etc.
   These are NOT simple integer operations — they have dedicated hardware
   semantics.

3. **Key question**: Is it feasible to build reversible circuits for IEEE 754
   operations? Each float add/mul involves: exponent comparison, mantissa shift,
   mantissa add, normalization, rounding. These are all expressible as integer
   operations on the 64-bit representation. But the gate count will be enormous.

4. **Possible approaches**:
   a. Lower float ops to their integer-level implementations (exponent/mantissa
      manipulation). Very complex, very many gates.
   b. Use fixed-point arithmetic instead of IEEE 754. Simpler, fewer gates,
      but different semantics.
   c. Treat Float64 as a 64-bit integer for bit-manipulation (reinterpret), and
      only support operations that Julia/LLVM express as integer ops on the bits.
   d. Start with a simple case: Float64 addition only, build the reversible
      IEEE 754 adder, verify against Julia's native addition.

5. **Check first**: What does `code_llvm(x -> x + 1.0, Tuple{Float64})` actually
   produce? If LLVM uses `fadd double`, we need to lower that. If Julia's
   optimizer does something simpler for specific cases, we might get lucky.

---

## 2026-04-10 — v0.8 EAGER cleanup (Bennett-6lb)

### What was built

`eager_bennett(lr::LoweringResult) -> ReversibleCircuit` — a drop-in alternative
to `bennett()` that eagerly uncomputes dead-end wires during the forward pass.

New files:
- `src/eager.jl`: `eager_bennett`, `compute_wire_mod_paths`, `compute_wire_liveness`
- `test/test_eager_bennett.jl`: 971 tests (helpers + correctness + peak liveness)
- `src/diagnostics.jl`: added `peak_live_wires(circuit)` diagnostic

### Algorithm (final, correct)

- **Phase 1**: Forward gates. Dead-end wires (never used as a control by ANY gate)
  are reversed immediately after their last modification. These wires contribute
  nothing to the computation; cleaning them is always safe.
- **Phase 2**: CNOT copy outputs (identical to full Bennett).
- **Phase 3**: Reverse remaining forward gates in reverse gate-index order, skipping
  gates that target eagerly-cleaned wires. Identical to full Bennett except those
  gates are omitted.

### Key research finding: per-wire mod-path reversal is WRONG

**Attempted**: Reverse each wire's modification path independently, in
reverse-dependency topological order (dependents before dependencies).

**Why it fails**: A gate G at position i uses control wire C. In the forward pass,
C held value V_i at step i. By the end of forward, C holds V_final (possibly
different if later gates also targeted C). Per-wire reversal of G's target
uses V_final instead of V_i. Result: incorrect uncomputation.

Full Bennett reverse works because it replays ALL gates in exact reverse order.
At each step, the state matches the forward state at that step. Per-wire
grouping breaks this invariant.

**Lesson**: Don't invent clever gate orderings without hand-tracing on real data.
The x+3 circuit's wire 19 is modified by G13 AFTER being used as a control in
G12. Per-wire reversal of wire 28 (which includes reversing G12) sees wire 19's
final value instead of its value at G12. This was only caught by extracting
and tracing the actual 41-gate sequence.

### What EAGER actually optimizes

For linear computations (additions, polynomials), almost every wire is on the
path from inputs to outputs. Dead-end wires are rare (only unused constant
bits). The main benefit:

| Function | Peak live (full) | Peak live (eager) | Reduction |
|----------|-----------------|-------------------|-----------|
| x + 3    | 7               | 6                 | 1 wire    |
| x²+3x+1 | 8               | 7                 | 1 wire    |

PRS15 achieves 5.3x on SHA-2 because SHA-2 has many parallel independent
subcomputations with dead-end intermediate values. Our test functions are
too linear. To get significant reduction, need either:
1. Functions with parallel independent branches (SHA-2, AES round functions)
2. Wire reuse during lowering (WireAllocator.free! integration)
3. Full pebbling (Knill recursion + re-computation checkpointing)

### Gotchas

1. **Julia scoping in -e scripts**: `local ok = true` inside a for loop doesn't
   work at top-level. Use `global passed = false` or wrap in a function.

2. **Kahn's algorithm direction**: Kahn's gives dependencies first (leaves first).
   For uncomputation order, need dependents first. Must `reverse!()`.

3. **Gate-level vs value-level EAGER**: PRS15 operates on MDD (AST-level values),
   not individual gates. At the gate level, the "modification path" for a wire
   may interleave with other wires' modifications, breaking per-wire reversal.
   The gate-level equivalent of EAGER is much more constrained.

4. **Dual refcounting insight**: Each control wire is used twice (forward + reverse).
   Only wires with ZERO total uses (fwd + rev) can be eagerly cleaned during
   Phase 1. This limits Phase 1 to dead-end wires only.

### Next steps for Bennett-6lb

The EAGER infrastructure is in place. To achieve significant ancilla reduction:

1. **Wire reuse in Phase 3**: After Phase 3 uncomputes a wire, free its index
   via WireAllocator. Later Phase 3 operations can reuse it. This requires
   modifying the gate sequence to remap wire indices — essentially register
   allocation on the Phase 3 schedule.

2. **Pebbling integration**: Use Knill's recursion to determine checkpoint
   boundaries. Between checkpoints, run forward + reverse (mini-Bennett).
   This trades gates for wires, achieving the time-space tradeoff.

3. **Better test functions**: Implement SHA-2 or AES as test targets for EAGER.
   These have the parallel structure that enables significant cleanup.

---

