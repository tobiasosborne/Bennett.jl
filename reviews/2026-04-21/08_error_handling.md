# Review: Error Handling Consistency in Bennett.jl
**Reviewer jurisdiction:** CLAUDE.md §1 — FAIL FAST, FAIL LOUD.
**Date:** 2026-04-21.
**Scope:** `/home/tobiasosborne/Projects/Bennett.jl/src/` — every `error(...)`, `throw(...)`, `@assert`, `try/catch`, `return nothing`, `missing`, `return 0` sentinel.

---

## Executive summary

Bennett.jl has **226 `error(...)` calls** in `src/`, **2 `@assert` sites**, **8 `try` blocks in one file** (all in `ir_extract.jl`), and **zero `throw(ArgumentError/AssertionError)`**. Error discipline is **aggressively good** in `ir_extract.jl` and `lower.jl` — the cc0.6 `_ir_error(inst, reason)` helper is used systematically in `ir_extract.jl`, and `lower.jl` consistently uses prefixed messages (`"lower_call!: ..."`, `"lower_store!: ..."`). But there are material gaps:

1. A **genuine §1 violation** in `ir_extract.jl:896–907`: the `_convert_instruction` dispatcher silently **swallows errors** whose message matches a regex, dropping the IR instruction entirely. This hides bugs.
2. **Over-reliance on `error(...)` as the one-true-throw**. No use of `ArgumentError`, `AssertionError`, `DomainError`. Tests use `@test_throws ErrorException` / `@test_throws Exception`, which means a typo that produces an `UndefVarError` would pass `Exception` tests and silently masquerade as the intended behaviour.
3. **Zero input validation on public API** `simulate`, `reversible_compile(parsed::ParsedIR; ...)`, `gate_count`, `controlled`, `WireAllocator().allocate!(n)`. An `n = -1` to `allocate!` silently returns an empty vector; a malformed `ReversibleCircuit` to `simulate` blows up with an `UndefVarError` or out-of-bounds rather than a boundary assertion.
4. **Entire files with zero error handling** that carry invariants (`bennett_transform.jl`, `adder.jl`, `multiplier.jl`, `divider.jl`, `simulator.jl` almost, `wire_allocator.jl`, `gates.jl`, `dep_dag.jl`, `eager.jl`, `value_eager.jl`, all of `softfloat/*`). §13 says soft-float must be bit-exact against Julia native — yet no `@assert` / `error` anywhere in `src/softfloat/`.
5. **`ir_extract.jl` has 32 `return nothing` sites** where an unsupported-instruction path is masked as "skipped". The downstream failure (an `_operand` lookup for the unbound SSA name) is the recovery mechanism, but this is fragile and specifically called out in a comment (§cc0.3). Several other `return nothing` sites in `ir_extract.jl` (lines 1705, 1706, 1720, 1548, 1561, 1698) reject types for **implicit type-filtering**, not unsupported-instruction coverage. This is §1 violation territory: they should at minimum log which instruction was dropped.
6. **`try/catch; nothing end`** — 10 sites in `ir_extract.jl` that swallow arbitrary exceptions to return sentinels (`<unknown-fn>`, `nothing`, `""`). Three of them are one-liners used inside error-message construction (defensible); the others (e.g., `_safe_operands` line 1786–1799, `_safe_is_vector_type` line 1965–1971, `_get_deref_bytes` line 2314) are hot-path swallowers. A cc0.3 comment documents this is intentional for GlobalAlias, but the regex-based `occursin("LLVMGlobalAlias", msg)` check in `_convert_instruction` is a hack that catches way more than intended.

---

## Error discipline by file

| File | `error(...)` | `@assert` | `try/catch` | `return nothing` (silent) | Fail-loud score |
|---|---|---|---|---|---|
| `Bennett.jl` | 5 | 0 | 0 | 0 | **MEDIUM** — top-level `reversible_compile` validates `strategy`/`add`/`mul` choices, but no input-type validation (`reversible_compile(f, "Int8")` → `MethodError` not a clear error). |
| `ir_extract.jl` | 68 | 0 | 8 (swallowing) | 32 | **MEDIUM** — per-instruction errors are excellent (cc0.6 helper), but `_convert_instruction` catch-block silently drops instructions by regex match. |
| `ir_parser.jl` | 3 | 0 | 0 | 2 | **LOW** — regex-match failures return `nothing` expected by caller. Legacy, largely superseded by LLVM.jl walker. |
| `ir_types.jl` | 0 | 3 | 0 | 0 | **LOW** — struct definitions; assertions are in constructors. |
| `gates.jl` | 0 | 0 | 0 | 0 | **LOW** — struct defs only; constructor takes `Int`, accepts negative wire indices silently. |
| `wire_allocator.jl` | 0 | 0 | 0 | 0 | **HIGH** — `allocate!(wa, -1)` silently returns `Int[]`; `free!` doesn't check duplicates or that wires were actually allocated. §1 violation. |
| `adder.jl` | 0 | 0 | 0 | 0 | **HIGH** — ripple-carry adder has preconditions (`length(a) == length(b) == W`) but no error. Relies on call-site validation. §1 violation. |
| `multiplier.jl` | 0 | 0 | 0 | 0 | **HIGH** — same pattern as `adder.jl`. |
| `divider.jl` | 0 | 0 | 0 | 0 | **HIGH** — no input validation. |
| `lower.jl` | 98 | 1 | 0 | 16 | **LOW-MEDIUM** — great coverage on lowering invariants. Several `return nothing` sites are post-emission cleanup, not silent failure. |
| `bennett_transform.jl` | 0 | 0 | 0 | 0 | **HIGH** — `bennett(lr)` has no invariant checks on `lr.n_wires`, `lr.input_wires`, `lr.output_wires`. Bogus `LoweringResult` → `BoundsError` at `simulate` time, not boundary error. |
| `simulator.jl` | 2 | 0 | 0 | 0 | **MEDIUM** — validates single-input invariant; has critical `error("Ancilla wire $w not zero — Bennett construction bug")` which is the Bennett correctness gate. Good. No type validation on `input::Integer`. |
| `diagnostics.jl` | 2 | 0 | 0 | 0 | **LOW** — `t_depth` validates decomposition choice. |
| `controlled.jl` | 4 | 0 | 0 | 0 | **MEDIUM** — asserts control wire unchanged (good), but no invariant check on `circuit.n_wires + 2 > typemax(Int)` style boundaries. |
| `qrom.jl` | 7 | 0 | 0 | 0 | **LOW** — precondition errors on `L, W, idx_wires`. Strong boundary checks. |
| `shadow_memory.jl` | 7 | 0 | 0 | 0 | **LOW** — precondition errors on `length` invariants. Good. |
| `feistel.jl` | 5 | 0 | 0 | 0 | **LOW** — precondition errors on `W, rounds, key_wires`. Good. |
| `mul_qcla_tree.jl` | 3 | 0 | 0 | 0 | **LOW** — input length + width checks. |
| `parallel_adder_tree.jl` | 4 | 0 | 0 | 0 | **LOW** — preconditions + post-condition `expected 1 root` check. |
| `qcla.jl` | 3 | 0 | 0 | 0 | **LOW** — preconditions on `W`, `|a|`, `|b|`. |
| `partial_products.jl` | 5 | 0 | 0 | 0 | **LOW** — preconditions on wire-list lengths. |
| `fast_copy.jl` | 2 | 0 | 0 | 0 | **LOW** — preconditions. |
| `tabulate.jl` | 2 | 0 | 0 | 0 | **LOW** — tabulate out_width bounds; return-type check. |
| `pebbling.jl` | 1 | 0 | 0 | 0 | **MEDIUM** — pebble budget error. |
| `pebbled_groups.jl` | 2 | 0 | 0 | 0 | **MEDIUM** — pebble budget; also `error("Unmapped wire ...")` for corruption detection. |
| `sat_pebbling.jl` | 0 | 0 | 0 | 2 | **MEDIUM** — `return nothing` on UNSAT is semantic, not a failure. Needs clear doc — half-documented. |
| `softmem.jl` | 0 | 1 | 0 | 0 | **HIGH** — comprehensive soft-memory library with zero boundary errors. `@assert` at macro-expansion time only. |
| `memssa.jl` | 0 | 0 | 0 | 0 | **HIGH** — parser for MemorySSA annotations; any malformed input → regex-match `nothing` or `KeyError`. |
| `softfloat/*` | 0 | 0 | 0 | 0 | **CRITICAL** — per CLAUDE.md §13, "Soft-float must be bit-exact". Zero assertions on sign-bit invariants, exponent biases, subnormal boundaries. Tests pin correctness externally; source has no invariant locks. |
| `persistent/*` | 3 (harness only) | 10 total | 0 | 0 | **LOW** — harness has strong test-time errors; impls rely on type discipline. |
| `eager.jl` / `value_eager.jl` / `dep_dag.jl` | 0 | 0 | 0 | 0 | **HIGH** — optimization passes with no invariant assertions. A bad DAG produces corrupted gates. |

---

## Critical findings

### CRITICAL-1: `_convert_instruction` swallows errors by regex match
**File:** `src/ir_extract.jl:896–907`

```julia
ir_inst = try
    _convert_instruction(inst, names, counter, lanes)
catch e
    msg = sprint(showerror, e)
    if occursin("Unknown value kind", msg) ||
       occursin("LLVMGlobalAlias", msg) ||
       (e isa MethodError && occursin("PointerType", msg))
        nothing
    else
        rethrow()
    end
end
ir_inst === nothing && continue
```

**Why it's a problem:**
- A `MethodError` whose message happens to contain `"PointerType"` could arise from many unrelated bugs (e.g. refactor passed a pointer where an integer was expected). Any such bug is silently swallowed. The instruction is dropped, its SSA dest is never bound, and the next consumer's `_operand` lookup fails with a **downstream** error that hides the real cause.
- A `"Unknown value kind"` message is not scoped to `LLVMGlobalAlias` — it matches any time LLVM.jl fails to wrap a value. If a future LLVM version starts emitting a new value kind (say, `ConstantVector`), this block will silently drop the instruction instead of failing loud, masking a real extraction gap.
- The comment ("User arithmetic (which doesn't touch runtime ptrs) extracts normally") is a **hope**, not an invariant. There's no assertion that the swallowed instruction is specifically an instruction we expected to skip.
- Interacts with §7 (Deep Bugs): if a phi resolution bug emitted an unexpected `MethodError`, this block would hide it.

**Fix:** check the exception type directly (not its stringified message), AND assert the offending instruction is exactly of the kind we expect to skip (e.g. a call with a GlobalAlias callee operand, or a load from a pgcstack ptr). Add a `@debug` / `@warn` log of the dropped opcode so session logs flag coverage holes.

---

### CRITICAL-2: `WireAllocator.allocate!(wa, -1)` silently returns `Int[]`
**File:** `src/wire_allocator.jl:8–20`

```julia
function allocate!(wa::WireAllocator, n::Int)
    wires = Int[]
    for _ in 1:n
        ...
    end
    return wires
end
```

**Why it's a problem:**
- `for _ in 1:-1` is an empty loop; `allocate!(wa, -1)` returns `Int[]` silently.
- A `LoweringResult` with `n_wires=0` and empty `input_wires`/`output_wires` propagates all the way to `bennett()`, which happily produces a circuit with `total = 0 + 0 = 0` wires that will then blow up in `simulate` at `bits[circuit.input_wires[...]]` with a `BoundsError`.
- §1 violates this: if a negative count reaches `allocate!`, something has miscomputed a width — crash immediately with context (`"allocate!: n=$n must be positive"`).
- `free!` has no verification that the wires it's returning were actually allocated, or that they're currently in the "in-use" set (there is no in-use set). Double-frees silently corrupt the free list.

**Fix:** add `n >= 0 || error("WireAllocator.allocate!: n=$n must be non-negative")` (or `n >= 1` if 0-alloc is not a semantic use case; today an empty-vector caller relies on it). Consider an ownership-set debug mode for free!.

---

### CRITICAL-3: `reversible_compile(f, T)` has no type validation
**File:** `src/Bennett.jl:50`

```julia
reversible_compile(f, types::Type...; kw...) = reversible_compile(f, Tuple{types...}; kw...)
```

**Why it's a problem:**
- `reversible_compile(x -> x, "Int8")` → `MethodError: no method matching (::var"#..."#)(::String)` at Julia call-through time. No user-facing message saying "arg_types must be integer types".
- `reversible_compile(f, Float32)` — what happens? Float32 is not routed through SoftFloat dispatch (only Float64 is). It would attempt extraction and crash with a float-type width error from `_type_width`.
- The `bit_width` kwarg silently accepts negative values — `_narrow_ir(parsed, -3)` would iterate over a negative-size wire vector.

**Fix:** add an up-front validator that the element types of the tuple are `<: Union{Signed, Unsigned, Bool, Float64}`. Clear error for each rejected type.

---

## High-severity findings

### HIGH-1: Entire files with zero error handling carry hidden invariants
**Files:** `src/adder.jl`, `src/multiplier.jl`, `src/divider.jl`, `src/bennett_transform.jl`, `src/eager.jl`, `src/value_eager.jl`, `src/dep_dag.jl`, `src/softmem.jl`, all of `src/softfloat/*`

These files implement load-bearing invariants without a single `error`, `@assert`, or `throw`:
- `adder.jl:lower_add!(gates, wa, a, b, W)` presumes `length(a) == length(b) == W`. Violated → `BoundsError` at some inner loop.
- `multiplier.jl:lower_mul!` — same pattern.
- `bennett_transform.jl:bennett(lr)` — computes `total = lr.n_wires + n_out`. No check that `lr.output_wires` are disjoint from `lr.input_wires`, or that the ancilla set is actually clean (Bennett's correctness depends on forward+uncompute being valid).
- `softfloat/fadd.jl`, `fmul.jl`, `fdiv.jl` — manipulate mantissa/exponent bit fields with no assertion that the intermediate values stay in expected ranges. §13 says "Every soft-float function must be bit-exact against Julia's native floating-point operations" — but the source has zero internal assertions. External tests enforce it, so when a regression happens, the failure surfaces in a downstream bit-exactness test, not at the wrong site.

**Fix:** add preconditions to each lowering helper (`length(a) == W`, `length(b) == W`). Add post-conditions to `bennett()` verifying `length(input ∩ output) == 0`, `ancilla = 1:total \ (input ∪ output)`. Soft-float assertions on sign-bit / exponent are a judgment call — at minimum, an assertion that normalized mantissa is in `[1 << 52, 1 << 53)` in internal ops would catch a broad class of bugs.

---

### HIGH-2: `try/catch; nothing end` one-liners silently mask errors
**File:** `src/ir_extract.jl`, 10 sites

```julia
338:    bb = try LLVM.parent(inst) catch; nothing end
340:            try LLVM.name(LLVM.parent(bb)) catch; "<unknown-fn>" end
342:            try LLVM.name(bb) catch; "<unknown-block>" end
343:    inst_str = try string(inst) catch; "<unprintable-instruction>" end
491:                    cname = try LLVM.name(ops[n_ops]) catch; "" end
957:        catch; nothing end        # _extract_const_globals, initializer probe
1218:            cname = try LLVM.name(ops[n_ops]) catch; "" end
1794:            catch; nothing end    # _safe_operands
1888:                    catch; return nothing end  # _ptr_identity
1966:    try ... catch; return false end  # _safe_is_vector_type
1990:            catch; continue end   # _any_vector_operand scan
```

- Lines 338–343 are in `_ir_error_msg`, used *only* inside error-message construction. Defensible: we don't want the error reporter to itself crash. But they should catch a **more specific** exception type (LLVM.jl's `LLVMException`, not bare `catch`).
- Lines 491, 1218 (callee-name probes): swallow to `""`, then compared to `"llvm.memcpy"` etc. An unrelated exception (corrupted IR) is silently treated as "not a llvm.memcpy call" → no error, silent miscompile. §1 violation territory.
- Lines 957 (`_extract_const_globals`): swallows `LLVM.initializer` errors. Comment says for GlobalAlias. But a different failure (e.g., LLVM version bump changing API) would silently drop the global → QROM dispatch goes through a MUX tree instead → gate count regression with no error. §6 (gate-count baselines) violation.
- Lines 1794, 1888, 1966, 1990: defensive "safe" wrappers. The cc0.3 reasoning is documented, but the bare `catch` with no exception type filter means a Julia typo in the calling code manifests as "that operand isn't a vector" and gets silently skipped.

**Fix:** narrow the catches to `LLVMException` / `LLVM.LLVMException`. Anything else should propagate.

---

### HIGH-3: `return nothing` in `_convert_instruction` for unsupported type filters
**File:** `src/ir_extract.jl`

Multiple sites silently drop an instruction if its operand/result isn't a type we handle:
- Line 1508 (call): `return nothing` if callee lookup fails
- Line 1548 (GEP): `return nothing` if base is not recognised
- Line 1561 (load): `return nothing` if not integer type
- Line 1705 (store): `val` isn't integer
- Line 1706 (store): `ptr.ref` not in `names`
- Line 1720 (alloca): elem_ty not integer

These silently drop the instruction AND fail to bind the SSA dest (if any). Comment on line 892–895 frames this as intentional: "Skipped instructions leave their SSA dest un-bound; downstream consumers that actually read the dest raise an ErrorException at `_operand` lookup time". This is **delayed fail-loud** — not great:

- The error is displaced. The user sees "unknown operand ref for: %foo" at a distant block, not "load of pointer-typed value at %foo".
- If the dropped instruction's dest is **never** read (pure side-effect), no error ever fires — the IR is silently miscompiled.
- `return nothing` on line 1706 (`haskey(names, ptr.ref)`) is especially dangerous: it silently accepts a store to an unknown pointer, dropping the write. Under `optimize=false` this could silently drop a user's data write.

**Fix:** replace the type-filter `return nothing` with `_ir_error(inst, "unsupported type for <opcode>: <why>")`. The "cc0.3 swallowing" concern is handled by the existing catch-block in the dispatcher — a direct error in `_convert_instruction` will propagate and be filtered there.

---

### HIGH-4: No per-type exception. Everything is `ErrorException`.
**All files.**

```
error("lower: unknown add strategy :$add; ...")
error("simulate(cc, ctrl, input) requires single-input ...")
error("Ancilla wire $w not zero — Bennett construction bug")
```

All three use `error(msg)`, which throws `ErrorException`. Consequences:
- **Tests can't distinguish between categories.** `@test_throws ErrorException reversible_compile(f, Int8; strategy=:nope)` (test_tabulate.jl:117) would pass equally well if `reversible_compile` threw an unrelated `ErrorException` from a totally different cause (e.g., a bug in the Bennett pipeline that erroneously throws before the strategy check). This is a **type-I error mask**.
- **CLAUDE.md §1's "crashes not corrupted state"** is satisfied in spirit (errors propagate), but a crash from an `UndefVarError` or `MethodError` is structurally different from a deliberate invariant violation. Using `ArgumentError` for input validation, `AssertionError` (or `@assert`) for invariants, and `ErrorException` only for "IR-level unsupported pattern" would make the test suite much more precise.
- `@test_throws Exception` (used in `test_negative.jl:22`, `test_mul_dispatcher.jl:44`, etc.) is even weaker — any kind of crash, including a Julia compilation failure, would satisfy it.

**Fix:**
- Use `ArgumentError` for user-input validation (`reversible_compile` strategy/add/mul/bit_width).
- Use `AssertionError` (or `@assert`) for internal invariants (`bennett` post-conditions, `simulator` ancilla checks).
- Keep `ErrorException` for IR-level coverage gaps (`_ir_error` already does this implicitly).
- Update tests to check specific types: `@test_throws ArgumentError reversible_compile(f, Int8; strategy=:nope)`.

---

### HIGH-5: cc0.6 convention applied in `ir_extract.jl` but not elsewhere
**Files:** `src/ir_extract.jl` (applied), `src/lower.jl` (not), `src/bennett_transform.jl` (none).

The cc0.6 convention `ir_extract.jl: <opcode> in @<func>:%<block>: <instr> — <reason>` is systematically applied in `ir_extract.jl` via `_ir_error(inst, reason)`. **36 of 68 error calls in `ir_extract.jl` use `_ir_error`;** the remaining 32 are at file/module/sret-slot scope where no `inst` is available, and they **manually prepend** `"ir_extract.jl: "` (32/32 — consistent).

By contrast, `lower.jl` uses per-function prefixes (`"lower_call!: ..."`, `"lower_store!: ..."`) but there's no canonical `_lower_error` helper. This means:
- Format is inconsistent between `ir_extract.jl` and `lower.jl`.
- A few `lower.jl` errors omit the prefix entirely (`"Unhandled instruction type: ..."` at line 164, `"Undefined SSA variable: ..."` at line 172, `"Unknown binop: ..."` at line 1149, `"Unknown icmp predicate: ..."` at line 1277, `"Unknown cast op: ..."` at line 1408, `"GEP base ... not found"` at line 1522/1605, `"Loop detected in LLVM IR..."` at line 349, `"Cannot topologically sort blocks..."` at line 680, `"Phi $(inst.dest) has no pre-header..."` at 713-714, `"Loop header must end..."` at 728, `"Block $label has no predecessors..."` at 828, `"No predicate contributions..."` at 849, `"Cannot resolve phi node..."` at 1059).

These bare errors can't be grep'd by filename prefix, which hinders debugging.

**Fix:** introduce a `_lower_error(site::String, reason::String)` helper. Prefix all of lower.jl's errors with `"lower.jl: <site>: ..."`. Prefix bennett_transform.jl's future errors similarly.

---

### HIGH-6: `simulate` has weak input validation
**File:** `src/simulator.jl:5–12`

```julia
function simulate(circuit::ReversibleCircuit, input::Integer)
    length(circuit.input_widths) == 1 || error("simulate(circuit, input) requires single-input circuit, got $(length(circuit.input_widths)) inputs")
    return _simulate(circuit, (input,))
end

function simulate(circuit::ReversibleCircuit, inputs::Tuple{Vararg{Integer}})
    return _simulate(circuit, inputs)
end
```

- No check that `length(inputs) == length(circuit.input_widths)` in the tuple form. Mismatched tuple silently produces a `BoundsError` in `_simulate` at the `inputs[k]` lookup. §1 violation.
- No check that `input >= 0` or `input` fits in the expected width. Passing `Int64(typemax(Int64))` to a 1-wire circuit silently truncates; the caller might think they've probed `2^63 - 1` but the circuit only sees `1`.
- No check that `circuit.n_wires > 0`.

**Fix:** add a tuple-length check and a bit-width bounds assertion. Make input-width overflow loud.

---

## Medium-severity findings

### MEDIUM-1: `_get_deref_bytes` returns `0` for three different failure modes
**File:** `src/ir_extract.jl:2304–2336`

```julia
function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
    # param not found in function params → return 0
    # dereferenceable attr not found → return 0
    # defline regex no match → return 0
end
```

Three distinct failure modes — "this isn't one of our params" (indicates an internal bug), "no dereferenceable attr" (silent, expected for pgcstack-style ptrs), "regex fallback failed" (LLVM text format changed) — all produce the same sentinel `0`. A returned 0 suppresses adding the arg to `args` in `_module_to_parsed_ir_on_func`. So if a user passes a genuine pointer argument that LLVM marks as dereferenceable(N) in a form this function can't parse, it's silently dropped from the function signature. Subsequent wire allocation is wrong.

**Fix:** distinguish `nothing` (no deref attr, expected) from an explicit error if `param` isn't found in the function. Keep the regex fallback but log when it fires.

---

### MEDIUM-2: `_extract_const_globals` swallows init errors
**File:** `src/ir_extract.jl:955–959`

```julia
init = try
    LLVM.initializer(g)
catch
    nothing
end
```

Comment says "LLVM.initializer errors for unknown value kinds (e.g. GlobalAlias)". But the bare catch swallows *any* exception, including `OutOfMemoryError` or `BoundsError` from a corrupted LLVM module. An unexpected failure silently drops the global; downstream QROM dispatch fails over to MUX-tree, and the gate count regresses with no error — **§6 violation**.

**Fix:** catch `LLVMException` specifically.

---

### MEDIUM-3: Sentinel `OPAQUE_PTR_SENTINEL` with inconsistent downstream handling
**File:** `src/ir_extract.jl:1760`

```julia
const OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)
```

This sentinel flows through `ParsedIR` representing "we couldn't resolve this pointer." Comment says: "Consumers that treat it as user arithmetic fail loud in `lower.jl`'s `resolve!`." Let me check — in `resolve!` (lower.jl:168–186), an `IROperand(:const, ...)` is materialised as NOT gates for each set bit. So OPAQUE_PTR_SENTINEL materialises as a single 0-value constant (no NOT gates), NOT as an error. It's only loud if the name `:__opaque_ptr__` is looked up as an SSA — but it's `:const`, so it never triggers the "Undefined SSA variable" error.

**This is a silent-miscompile vulnerability.** If a pointer value accidentally flows into arithmetic (e.g., via a buggy cast), it's treated as `0` and compiled through.

**Fix:** either error at `resolve!` time when the operand is OPAQUE_PTR_SENTINEL, or use a distinct `IROperand.kind` (e.g., `:opaque`) that `resolve!` checks for.

---

### MEDIUM-4: `_fold_constexpr_operand` for pointer `icmp` returns `iconst(0/1)` without provenance
**File:** `src/ir_extract.jl:1915–1957`

When a ConstantExpr `icmp eq` between two pointers resolves, the result is a boolean `iconst(0)` or `iconst(1)`. This is correct for the static-decidability case, but there's no record that this was folded. If a future dev adds a conditional codepath in the lowering pipeline that depends on the fold, the folded constant will be compiled through as user arithmetic. No provenance breadcrumb.

**Fix:** not a correctness bug today, but add a comment/debug log. Low priority.

---

### MEDIUM-5: `error()` inside macro-generated functions
**File:** `src/lower.jl:2540–2606`, `src/softmem.jl:279`

The `@eval` block generates `_lower_load_via_mux_NxW!` / `_lower_store_via_mux_NxW!` helpers. The errors inside are `error(...)` with concatenated strings. Stack traces point to the macro-generated line, not the template line. `@assert N * W <= 64 "shape ($N, $W) exceeds UInt64 packing"` is at macro-expansion time — catches shape-list mistakes at module load, which is good.

**Fix:** none needed — just noted as an error-surface gotcha.

---

### MEDIUM-6: `lower.jl:726` missing `file:line` / `inst` context
**File:** `src/lower.jl:728`

```julia
(term isa IRBranch && term.cond !== nothing) || error("Loop header must end with conditional branch, got: $(typeof(term))")
```

Doesn't say **which** loop header. The user has to grep for their function. Compare with `ir_extract.jl`'s cc0.6 convention (`@funcname:%blockname`). Fix: include header's label: `"Loop header %$hlabel must end ..."`.

Similar missing-context sites:
- `lower.jl:164` — `error("Unhandled instruction type: $(typeof(inst)) — $(inst)")` — doesn't say which block.
- `lower.jl:172` — `"Undefined SSA variable: %$(op.name)"` — doesn't say which consumer.
- `lower.jl:849` — `"No predicate contributions for block $label"` — has label but not enclosing function.
- `lower.jl:1059` — `"Cannot resolve phi node: no branch cleanly partitions ..."` — no phi dest; only blocks.

---

### MEDIUM-7: Pebbling budget errors inconsistent
**Files:** `src/pebbling.jl:163`, `src/pebbled_groups.jl:174`

```julia
# pebbling.jl:163
s <= 1 && error("Insufficient pebbles: need $(min_pebbles(n)) for $n groups, have $s")

# pebbled_groups.jl:174
s <= 1 && error("Insufficient pebbles: need at least $(min_pebbles(n)) for $n gates, have $s")
```

Different wording ("groups" vs "gates") and phrasing ("need" vs "need at least") for same-pattern check. Minor.

---

### MEDIUM-8: `simulator.jl` reversibility check error lacks context
**File:** `src/diagnostics.jl:158`

```julia
bits == orig || error("Reversibility check failed: $(sum(bits .!= orig)) wires differ")
```

Says how many wires differ but not **which** — when the check fails, the debugger has to re-run manually to localize. Add the first-few differing wire indices.

---

## Low-severity findings

### LOW-1: `_auto_name` uses a mutable counter that can silently wrap
**File:** `src/ir_extract.jl:249–252`

```julia
function _auto_name(counter::Ref{Int})
    counter[] += 1
    Symbol("__v$(counter[])")
end
```

No upper bound. In practice fine (Int64), but no assertion.

### LOW-2: `_narrow_ir` accepts `W=0`
**File:** `src/Bennett.jl:120`

If `bit_width=0`, `_narrow_ir` is not called (gated by `if bit_width > 0`). But `_narrow_ir` itself has no internal validation of `W`. If a future caller passes `W=0`, it would silently produce 0-width instructions.

### LOW-3: `ir_parser.jl` errors on unrecognized instruction but not on malformed numbers
**File:** `src/ir_parser.jl:125`

`parse(Int, m.captures[1])` can throw on malformed integer. `@test_throws ArgumentError` would trigger, but users see a cryptic `Base.InvalidValue` rather than "malformed LLVM IR".

### LOW-4: `tabulate.jl` trusts `f` doesn't throw
**File:** `src/tabulate.jl:149`

```julia
y = f(args...)
```

Calls user's `f` on 2^W inputs. If `f` throws for some input (e.g., division by zero), the user sees that error. Arguably correct — it's their function — but no wrapping/context. If the intended semantics is "tabulate all outputs", maybe wrap in `try` and error with "tabulate: f threw on input $x".

### LOW-5: `controlled.jl` assumes `n_wires + 1` and `n_wires + 2` are free
**File:** `src/controlled.jl:18–19`

`ctrl_wire = circuit.n_wires + 1` hardcodes an assumption that wire indices are contiguous `1:n_wires`. The `WireAllocator` invariant is contiguous allocation, but `ReversibleCircuit` struct doesn't enforce `n_wires == max(all wire indices in gates)`. A crafted circuit with non-contiguous wires (e.g. gate targeting wire 100 with `n_wires = 5`) would produce a malformed controlled circuit with no error.

### LOW-6: `ir_types.jl` constructors don't validate
**File:** `src/ir_types.jl` (no errors at all)

Constructors like `IRBinOp(dest, op, op1, op2, width)` accept `width = -1` or `op = :bogus`. Fields are typed, so basic type errors catch. But a `:bogus` binop symbol propagates to lowering and hits `error("Unknown binop: :bogus")` — delayed fail-loud. A constructor-time `@assert op in (:add, :sub, ...)` would catch at IR-emission time.

---

## Dead error paths

I didn't find obvious dead-code error paths via static inspection. The two candidates worth flagging:
- `src/ir_extract.jl:1059` — `error("Cannot resolve phi node: no branch cleanly partitions ...")` at end of `lower_phi!` alternate algorithm. Unclear which algorithm path reaches this under current inputs. Not dead but worth documenting the trigger CFG shape.
- `src/pebbling.jl:70–71` — `n <= 1 && return 0`, `s <= 1 && return 0` in `min_pebbles`. Dual early-out looks like belt-and-suspenders; one branch may be unreachable depending on caller precondition.

---

## Silent coercion

`convert(Int, val)` on `LLVM.ConstantInt` values (11 sites in `ir_extract.jl`): if the ConstantInt is 64-bit with top bit set, this would throw `InexactError` — which is loud. Good.

`UInt64(op.value)` in `_operand_to_u64!` (`lower.jl:2651`): `op.value` is an `Int`, which can be negative. `UInt64(-1)` throws `InexactError` — also loud. Good.

`Int(raw & ...)` in `simulator.jl:66`: operates on a masked `UInt64`, so safe.

No silent overflow/wrap sites I can find.

---

## Error test coverage map

From `grep @test_throws test/`:

| Error site | Test coverage |
|---|---|
| `reversible_compile` unknown strategy | `test_tabulate.jl:117` (`ErrorException`) |
| `reversible_compile` Float64 + :tabulate | `test_tabulate.jl:124` |
| `reversible_compile` unknown mul/add | `test_mul_dispatcher.jl:44`, `test_add_dispatcher.jl:49` (`Exception`) |
| `reversible_compile(f, Float64×4)` | `test_negative.jl:27` |
| `simulate` multi-input as single-input | `test_negative.jl:33` |
| `reversible_compile` unbounded loop | `test_negative.jl:22` (`Exception`) |
| sret heterogeneous struct | `test_sret.jl:122`, `test_0c8o_vector_sret.jl:155` |
| T5 corpus LLVM extraction failures | 3 in test_t5_corpus_rust.jl, 3 in test_t5_corpus_c.jl, 3 in test_t5_corpus_julia.jl |
| `_compile_ir` memory corpus | `test_memory_corpus.jl:484`, `test_lower_store_alloca.jl:98` |
| `pebbled_bennett` pebble budget | `test_pebbled_space.jl:67` |
| `t_depth` unknown decomp | `test_toffoli_depth.jl:80` |

**Gaps (no test):**
- `WireAllocator.allocate!` negative `n` (critical gap — not tested because there's no error to test)
- Most `ir_extract.jl` `_ir_error` sites (sret edge cases, fcmp predicate, insertelement dynamic idx, bitcast width mismatch, extractelement poison, vector lane-count mismatch) — some are hard to trigger from Julia
- `lower.jl:1149` `"Unknown binop"` (this is dead code today — the dispatch handles all known ops, falls through only if IR has a novel binop we don't handle)
- `lower.jl:349` loop without `max_loop_iterations` — covered by `test_negative.jl:22` but via `Exception`, not `ErrorException`
- `simulator.jl:31` ancilla-not-zero — this is the correctness invariant. It's tested *implicitly* by every `verify_reversibility` call, but there's no test that deliberately constructs a broken circuit and asserts it's rejected.
- `controlled.jl:82` ancilla-not-zero for controlled circuits — same as above.

---

## Summary of top actions

By priority, if I had to pick the 5 most important fixes:

1. **Fix `ir_extract.jl:896–907` regex-based error swallowing** — narrow to exception types, add logging.
2. **Validate `WireAllocator.allocate!` input** — `n >= 0` assertion.
3. **Replace `return nothing` with explicit errors in `_convert_instruction`** type-filter paths (lines 1508, 1548, 1561, 1705, 1706, 1720).
4. **Add `ArgumentError` variants** for user-facing input validation (`reversible_compile` strategy/add/mul/bit_width/types). Tighten tests to `@test_throws ArgumentError`.
5. **Add preconditions to `adder.jl`, `multiplier.jl`, `divider.jl`, `bennett_transform.jl`** — `length(a)==length(b)==W`, disjoint input/output sets.

Each is a CLAUDE.md §1 (fail-loud) improvement. None is a correctness bug today, but each narrows the window where a future bug would masquerade as a downstream error.

---

**End of review.**
