# Julia Idiom Review -- Bennett.jl

## Executive Summary

Bennett.jl is a well-structured Julia codebase with clean type hierarchies, good use of multiple dispatch for gate types, and solid overall architecture. The code is clearly written by developers who understand Julia's strengths. However, there are several areas where idiomatic Julia practices are not followed -- the most impactful being type-unstable containers in the simulator and lowering hot paths, use of `@assert` where `error()` is mandated by the project's own principles, untyped `[]` literals creating `Vector{Any}`, global mutable state without thread-safety considerations, and significant code duplication across the softfloat module. None of these are correctness-threatening, but they represent performance and maintainability debt.

**Severity breakdown:**
- CRITICAL: 0
- HIGH: 7
- MEDIUM: 17
- LOW: 12

---

## Type Stability Analysis

The codebase is generally type-stable where it matters most (the gate application loop in the simulator, the main compile pipeline). However, several containers use abstract element types or untyped constructors, and one key function has a type-unstable return path.

**Key concerns:**

1. `simulator.jl:42` -- `vals = []` creates a `Vector{Any}`. This is used in `_read_output` for multi-element returns. Every `push!` into this array boxes the value. Should be `vals = Int64[]` or better, a comprehension.

2. `lower.jl:555` -- `phi_info = []` creates a `Vector{Any}`. This holds `(dest, width, pre_header_operand, latch_operand)` tuples. Should be `phi_info = Tuple{Symbol, Int, IROperand, IROperand}[]`.

3. `ir_types.jl:119` -- `IRBasicBlock.instructions::Vector{IRInst}` uses the abstract type `IRInst`. This is unavoidable given the heterogeneous instruction set, but it means every access to an instruction requires dynamic dispatch. Consider a tagged-union approach or accept the cost.

4. `simulator.jl:37-50` -- `_read_output` returns either `Int*` (single element) or `Tuple(vals)` (multi-element). The return type is `Union{Int8, Int16, Int32, Int64, Int, Tuple}` -- fully type-unstable. Callers cannot infer the return type at compile time.

5. `ir_extract.jl:265` -- `_convert_instruction` returns `Union{Nothing, IRInst, Vector{IRInst}}`. This three-way return type forces the caller at line 139-147 to check `isa Vector` at runtime. Consider always returning a `Vector{IRInst}` (length 0 for skip, 1 for single, N for multi).

---

## Performance Antipatterns

### Global Mutable State

6. `ir_extract.jl:33` -- `const _known_callees = Dict{String, Function}()`. This is module-level mutable state. The `Function` type is abstract -- `Dict{String, Function}` forces boxing of every value. Additionally, `_lookup_callee` at line 42-49 iterates all entries with `occursin` on every LLVM call instruction. For the current ~15 entries this is fine, but the design is O(n*m) where n is callees and m is call instructions.

7. `ir_extract.jl:56` -- `const _name_counter = Ref(0)`. Global mutable counter. Not thread-safe. Called via `_reset_names!()` at the start of `reversible_compile` and again inside `lower_call!` (line 1381-1383) which saves and restores it. This save/restore pattern is fragile and would break under concurrent compilation.

8. `ir_extract.jl:91` -- `names = Dict{_LLVMRef, Symbol}()`. Created per-compilation, not global, but `_LLVMRef` is a `Ptr{LLVM.API.LLVMOpaqueValue}` -- dictionary hashing of pointers is fine but worth noting for correctness: these pointers are only valid within the `LLVM.Context` block.

### Allocation Patterns

9. `wire_allocator.jl:11-12` -- `popfirst!(wa.free_list)` on a sorted `Vector{Int}` is O(n) because it shifts all elements. The comment says "min-heap" but uses a sorted list with `searchsortedfirst`/`insert!` for insertion (also O(n)) and `popfirst!` for extraction (O(n)). For a true min-heap, use `DataStructures.BinaryMinHeap` or Julia's `Base.Order.Forward` with a proper heap. For the current use pattern (allocate many, free few), this may not be a bottleneck, but it is architecturally misleading.

10. `bennett.jl:20` -- `append!(all_gates, reverse(lr.gates))` allocates a full reversed copy of the gate vector. For large circuits (SHA-256 has ~11000 forward gates), this creates a 11000-element temporary. Use `for i in length(lr.gates):-1:1; push!(all_gates, lr.gates[i]); end` or `Iterators.reverse`.

11. `diagnostics.jl:113-125` -- `peak_live_wires` simulates the entire circuit bit-by-bit while tracking a `Set{Int}` of nonzero wires AND a `Vector{Bool}` of bits. The `Set{Int}` operations (`push!`, `delete!`, `length`) are O(1) amortized but with significant constant overhead. A `BitSet` would be more appropriate.

12. `lower.jl:523` -- `queue = [b.label for b in blocks if indeg[b.label] == 0]` used as a FIFO queue with `popfirst!` (line 525). `popfirst!` on a `Vector` is O(n). Use a `Deque` from DataStructures.jl, or since the queue is typically small, accept the cost but document the tradeoff.

### String Allocations in Hot Paths

13. `ir_extract.jl:61-63` -- `_auto_name()` creates a new `Symbol("__v$(_name_counter[])")` via string interpolation on every unnamed LLVM value. During compilation of a large function (e.g., SHA-256), this can generate hundreds of symbols. `Symbol` construction from interpolated strings allocates a temporary string. Consider pre-computing or caching symbols.

14. `lower.jl:1194` -- `Symbol("__div_$(inst.dest)")` and similar pattern at lines 1196-1200. String interpolation into Symbol constructors is common throughout the lowering pass. Each creates a temporary string.

---

## Struct Design Review

The struct design is generally strong. All IR types and gate types are immutable, which is correct for these value-semantic types.

15. `ir_types.jl:1-7` -- `IROperand` uses `Symbol` for both `:ssa` and `:const` kinds, wasting the `name` field for constants and the `value` field for SSA refs. A `Union{Symbol, Int}` discriminated by `kind` would be more honest, but the current flat struct avoids heap allocation. This is a defensible design choice, not a bug. However, the `kind::Symbol` field forces runtime dispatch on every operand access. A parametric type or separate `SSAOperand`/`ConstOperand` types with a union would enable the compiler to specialize.

16. `wire_allocator.jl:1` -- `WireAllocator` is correctly `mutable struct` since it tracks state. Good.

17. `gates.jl:1` -- `const WireIndex = Int`. This type alias provides no type-safety (Julia does not distinguish `Int` from `WireIndex` in dispatch). Consider a `struct WireIndex; val::Int; end` if wire/non-wire confusion is a risk, but for this codebase the alias is probably sufficient.

18. `lower.jl:7-16` -- `GateGroup` has 8 fields, several with `Vector{Int}` or `Vector{Symbol}`. The backward-compatible constructors at lines 19-20 fill defaults. This is clean. However, `GateGroup` is immutable but carries mutable `Vector` fields, meaning the vectors themselves can still be mutated after construction. If immutability is intended, use `Tuple` for fixed-length fields.

19. `ir_types.jl:91-97` -- `IRCall` has `callee::Function`. The abstract `Function` type means any operation on `callee` (calling it, comparing it) goes through dynamic dispatch. Since `callee` is only used by `lower_call!` to extract parsed IR, this is acceptable.

20. `pebbled_groups.jl:27-31` -- `ActivePebble` has `wmap::Dict{Int,Int}`. This is concrete and good. But it is a struct (immutable) with a mutable `Dict` field, meaning the struct cannot be truly frozen.

---

## Module Organization

21. `src/Bennett.jl:1-23` -- The module definition uses `include()` for all files, which is idiomatic Julia. The include order matters (types before functions that use them) and is correct.

22. `src/Bennett.jl:24-28` -- Export list is comprehensive but long. Consider grouping exports with comments or using `@reexport` from a submodule. The current flat export is fine for a library this size.

23. `src/Bennett.jl:47-62` -- `register_callee!` calls at module load time mutate the global `_known_callees` dict. This is a side effect during module compilation. It works but means the registry is populated whether or not the user needs soft-float. Lazy registration (register on first use) would be slightly cleaner.

24. `src/softfloat/softfloat.jl` -- The softfloat module is not actually a Julia `module` -- it is just a series of `include()` calls inside the Bennett module. This means all softfloat functions live in the `Bennett` namespace. If namespace pollution becomes a concern, wrapping in a submodule would help.

25. `src/ir_parser.jl` -- Legacy regex parser. The CLAUDE.md says "backward compat". If this is truly unused in the main path, consider gating it behind a compatibility flag or deprecating it. Having two IR parsers (regex and LLVM.jl) increases maintenance surface.

---

## Error Handling Assessment

### `@assert` vs `error()`

The CLAUDE.md is explicit: "FAIL FAST, FAIL LOUD. Assertions, not silent returns. Crashes, not corrupted state. `error()` with a clear message." However, it also notes a critical nuance: `@assert` can be disabled with `--check-bounds=no` in Julia. The project uses `@assert` in several production paths where `error()` would be more robust:

26. `simulator.jl:6` -- `@assert length(circuit.input_widths) == 1`. This guards against calling single-input simulate with multi-input circuits. If assertions are disabled, this silently proceeds to incorrect behavior.

27. `simulator.jl:31` -- `@assert !bits[w] "Ancilla wire $w not zero -- Bennett construction bug"`. This is the core correctness invariant of the entire system. If this assertion is disabled, corrupted results are silently returned. **This must be `error()` or a custom exception.**

28. `controlled.jl:57,82,84,104` -- Same pattern: `@assert` guarding correctness invariants. The ancilla check at line 82 and control wire check at line 84 are especially important.

29. `diagnostics.jl:140` -- `@assert bits == orig "Reversibility check failed"` in `verify_reversibility`. This function exists specifically to verify correctness. Using `@assert` defeats the purpose if assertions are disabled.

30. `lower.jl:582` -- `@assert term isa IRBranch && term.cond !== nothing "Loop header must end with conditional branch"`. This guards a structural invariant of the IR. Should be `error()`.

### Error Messages

31. The error messages are generally informative and include context (e.g., `"Undefined SSA variable: %$(op.name)"` at `lower.jl:45`). This is good practice.

32. `ir_extract.jl:375` -- `cname = try LLVM.name(ops[n_ops]) catch; "" end`. Silent catch-all exception handling. If `LLVM.name` throws for an unexpected reason, this masks the error. Narrow the catch to specific exception types.

---

## Naming & Style

Julia naming conventions are well followed throughout:

33. All types use CamelCase: `IRBinOp`, `ReversibleCircuit`, `WireAllocator`, etc. Good.

34. All functions use snake_case: `lower_add!`, `resolve_phi_predicated!`, `extract_parsed_ir`. Good.

35. Bang convention (`!`) is used correctly: functions that mutate their arguments (`allocate!`, `free!`, `lower_add!`, `resolve!`) are properly marked. The `lower_*!` functions mutate the `gates` vector and `wa` allocator.

36. Single-letter variables in complex logic:
    - `lower.jl:1048-1070` -- `lower_eq!` uses `g, wa, a, b, W, r, diff, or, k`. The `g` (for gates vector) and `W` (width) are used throughout the lowering functions. This is consistent within the codebase but `g` conflicts with the common mathematical meaning. `gates` would be clearer.
    - `lower.jl:924-947` -- Same pattern in `lower_and!`, `lower_or!`, `lower_xor!`. The abbreviated `g` is used for the gate list in all these helpers.

37. `_` prefix for internal functions is consistent: `_auto_name`, `_convert_instruction`, `_module_to_parsed_ir`, `_remap_gate`, etc. This is a common Julia convention for non-exported functions.

38. `ir_extract.jl:53` -- `const _LLVMRef = LLVM.API.LLVMValueRef`. Type alias with underscore prefix. Clear and useful.

---

## Code Organization

### Long Functions

39. `ir_extract.jl:265-841` -- `_convert_instruction` is ~576 lines. This is the longest function in the codebase by far. It handles every LLVM opcode via a chain of `if opc == ...` blocks. While each block is self-contained, the function is extremely hard to navigate. **Refactor into a dispatch table or at minimum break into helper functions** by category (arithmetic, control flow, casts, calls, memory, intrinsics).

40. `lower.jl:171-316` -- `lower()` is ~145 lines. It handles block traversal, predicate computation, loop detection, and multi-return merging. This is complex but each section is well-commented. The function could be split into `_lower_blocks!` and `_merge_returns!`.

41. `lower.jl:546-636` -- `lower_loop!` is ~90 lines. Acceptable for its complexity.

42. `softfloat/fmul.jl:14-270` -- `soft_fmul` is ~256 lines. The widening multiply assembly is inherently complex, but the dead-code comments (lines 98-119) should be removed -- they describe an approach that was abandoned.

### Code Duplication

43. **Softfloat CLZ normalization** -- The six-stage binary-search CLZ block is duplicated verbatim in `fadd.jl:117-139`, `fmul.jl:193-215`, and `fdiv.jl:69-91`. This is ~23 lines copied three times. Extract to a helper function `_normalize_clz!` or similar. The concern about function calls affecting LLVM IR is real for the soft-float library (it must compile to clean IR), but the duplication is still a maintenance risk.

44. **Softfloat rounding block** -- The round-to-nearest-even logic (guard/round/sticky extraction, GRS comparison, mantissa overflow handling) is duplicated in `fadd.jl:163-186`, `fmul.jl:238-258`, and `fdiv.jl:111-127`. Another ~20 lines duplicated three times.

45. **Softfloat subnormal handling** -- The subnormal result block (shift clamp, lost bits, flush-to-zero) is duplicated in `fadd.jl:142-157`, `fmul.jl:218-231`, and `fdiv.jl:94-105`. ~14 lines times three.

46. **Bennett construction ancilla computation** -- The pattern `in_set = Set(lr.input_wires); out_set = Set(copy_wires); ancillae = [w for w in 1:total if !(w in in_set) && !(w in out_set)]` appears in `bennett.jl:22-24`, `eager.jl:108-110`, `value_eager.jl:136-138`, `pebbled_groups.jl:274-275`, `pebbling.jl:133-135`. Extract to a helper.

47. **Copy wire allocation** -- The pattern `n_out = length(lr.output_wires); copy_start = lr.n_wires + 1; copy_wires = collect(copy_start:copy_start + n_out - 1); total = lr.n_wires + n_out` appears in `bennett.jl:8-11`, `eager.jl:91-94`, `value_eager.jl:87-90`, `pebbling.jl:113-117`. Extract to a helper.

### Dispatch Chain in `lower_block_insts!`

48. `lower.jl:424-459` -- The `if inst isa IRPhi ... elseif inst isa IRBinOp ...` chain tests 12 instruction types sequentially. This is a classic antipattern in Julia. **Use multiple dispatch**: define `lower_inst!(gates, wa, vw, inst::IRBinOp, ...) = lower_binop!(...)` etc. The Julia compiler can then generate an efficient jump table. The current chain forces N type checks per instruction.

### Dead Code

49. `ir_parser.jl` -- The entire legacy regex parser is still included. If `parse_ir` is only used in tests for backward compatibility, consider removing it from the main module or marking it deprecated.

50. `fmul.jl:96-119` -- Long commented-out section describing an assembly approach. Remove dead comments.

---

## Documentation Gaps

51. `lower.jl` -- The `lower()` function has no docstring despite being the central function in the pipeline.

52. `lower.jl:418` -- `lower_block_insts!` has no docstring.

53. `lower.jl:780-799` -- `has_ancestor` and `on_branch_side` have single-line docstrings but the algorithm they implement (reachability-based phi resolution) is not documented at the function level. The CLAUDE.md mentions this is "the most complex and bug-prone part" but the code lacks detailed inline documentation.

54. `gates.jl` -- No docstrings on any gate type or `ReversibleCircuit`. These are exported types.

55. `wire_allocator.jl` -- `allocate!` has no docstring. `free!` has a brief one. `WireAllocator` itself has none.

56. `dep_dag.jl` -- Good module-level comment but `DAGNode` and `DepDAG` lack docstrings.

57. `ir_types.jl` -- None of the IR instruction types have docstrings. Since these define the core data model, they should be documented.

---

## Specific Findings

### F1 -- HIGH: `@assert` used for correctness invariants that must never be disabled

**Files:** `src/simulator.jl:31`, `src/controlled.jl:82,84`, `src/diagnostics.jl:140`
**Issue:** `@assert` can be disabled by Julia's `--check-bounds=no` flag. These guard the core correctness invariant (ancillae return to zero). If disabled, Bennett's construction violations would silently produce wrong results.
**Fix:**
```julia
# Before (simulator.jl:31):
@assert !bits[w] "Ancilla wire $w not zero -- Bennett construction bug"

# After:
bits[w] && error("Ancilla wire $w not zero -- Bennett construction bug")
```
Apply same pattern to all correctness-critical assertions.

---

### F2 -- HIGH: `vals = []` creates `Vector{Any}` in simulator

**File:** `src/simulator.jl:42`
**Issue:** Untyped `[]` literal creates `Vector{Any}`. Every `push!` boxes the integer value. This is on the simulation path for multi-output circuits.
**Fix:**
```julia
# Before:
vals = []
off = 0
for ew in elem_widths
    push!(vals, _read_int(bits, output_wires, off + 1, ew))
    off += ew
end
return Tuple(vals)

# After:
vals = Vector{Int64}(undef, length(elem_widths))
off = 0
for (k, ew) in enumerate(elem_widths)
    vals[k] = _read_int(bits, output_wires, off + 1, ew)
    off += ew
end
return Tuple(vals)
```

---

### F3 -- HIGH: `phi_info = []` creates `Vector{Any}` in loop lowering

**File:** `src/lower.jl:555`
**Issue:** Untyped `[]` creates `Vector{Any}`. Elements are `(Symbol, Int, IROperand, IROperand)` tuples that get boxed.
**Fix:**
```julia
phi_info = Tuple{Symbol, Int, IROperand, IROperand}[]
```

---

### F4 -- HIGH: `_convert_instruction` is 576 lines with sequential type checks

**File:** `src/ir_extract.jl:265-841`
**Issue:** Single function handling all LLVM opcodes via `if opc == ...` chain. Hard to navigate, test, and extend.
**Fix:** Refactor into a dispatch table:
```julia
const _OPCODE_HANDLERS = Dict{LLVM.API.LLVMOpcode, Function}(
    LLVM.API.LLVMAdd => _convert_binop,
    LLVM.API.LLVMICmp => _convert_icmp,
    # ...
)

function _convert_instruction(inst, names)
    handler = get(_OPCODE_HANDLERS, LLVM.opcode(inst), nothing)
    handler === nothing && return nothing
    return handler(inst, names)
end
```
Alternatively, use multiple dispatch on a wrapper type for the opcode.

---

### F5 -- HIGH: `lower_block_insts!` uses sequential `isa` chain instead of dispatch

**File:** `src/lower.jl:424-459`
**Issue:** 12 sequential `elseif inst isa IRFoo` checks. Julia's dispatch system can handle this more efficiently.
**Fix:** Define dispatched methods:
```julia
_lower_inst!(gates, wa, vw, inst::IRBinOp; kw...) = lower_binop!(gates, wa, vw, inst; kw...)
_lower_inst!(gates, wa, vw, inst::IRICmp; kw...) = lower_icmp!(gates, wa, vw, inst)
_lower_inst!(gates, wa, vw, inst::IRSelect; kw...) = lower_select!(gates, wa, vw, inst)
# ... etc
```
Then the loop body becomes:
```julia
_lower_inst!(gates, wa, vw, inst; block_pred, ssa_liveness, inst_counter, gate_groups, use_karatsuba)
```

---

### F6 -- HIGH: `_read_output` is type-unstable

**File:** `src/simulator.jl:37-50`
**Issue:** Returns `Int8|Int16|Int32|Int64|Int` for single element, `Tuple` for multi-element. The caller cannot infer the return type.
**Fix:** Keep the current behavior (it is inherently type-unstable due to width-dependent types) but document it with a return type annotation and consider using `@nospecialize` on paths that don't need specialization. For performance-critical simulation loops, callers should use the typed `_read_int` directly.

---

### F7 -- HIGH: Duplicated softfloat code blocks (CLZ, rounding, subnormal)

**Files:** `src/softfloat/fadd.jl`, `fmul.jl`, `fdiv.jl`
**Issue:** ~60 lines of identical code duplicated across three files. A bug fix in one must be manually propagated to the others.
**Fix:** Extract shared logic into helper functions in a `softfloat_common.jl`:
```julia
# CLZ normalization: normalize wr so leading 1 is at bit 55
function _normalize_clz(wr::UInt64, result_exp::Int64)
    need32 = (wr & (UInt64(0xFFFFFFFF) << 24)) == UInt64(0)
    wr = ifelse(need32, wr << 32, wr)
    result_exp = ifelse(need32, result_exp - Int64(32), result_exp)
    # ... remaining stages
    return (wr, result_exp)
end
```
**Note:** Verify that Julia inlines these helpers when compiling to LLVM IR for the reversible circuit path. If not, the duplication may be intentional.

---

### F8 -- MEDIUM: `popfirst!` on sorted Vector in WireAllocator

**File:** `src/wire_allocator.jl:12`
**Issue:** `popfirst!` is O(n) on `Vector`. The free list is maintained sorted, but extraction from the front shifts all elements.
**Fix:** Use a `BinaryMinHeap` from DataStructures.jl, or reverse the sort order and use `pop!` (O(1)) instead. Alternatively, if the free list is typically short (<100 elements), document the design choice:
```julia
# O(n) popfirst! is acceptable: free_list is typically small (<100 wires)
```

---

### F9 -- MEDIUM: `bennett.jl:20` allocates reversed copy of gate vector

**File:** `src/bennett.jl:20`
**Issue:** `append!(all_gates, reverse(lr.gates))` creates a temporary reversed array.
**Fix:**
```julia
for i in length(lr.gates):-1:1
    push!(all_gates, lr.gates[i])
end
```

---

### F10 -- MEDIUM: `hasproperty` used for duck-typing IR instructions

**File:** `src/lower.jl:151,454`
**Issue:** `hasproperty(inst, :dest)` is used to check if an instruction has a `:dest` field. This is reflection-based and slow. It also breaks if a field is renamed.
**Fix:** Define a trait function:
```julia
has_dest(::IRBinOp) = true
has_dest(::IRICmp) = true
has_dest(::IRSelect) = true
# ... etc
has_dest(::IRRet) = false
has_dest(::IRBranch) = false

dest_name(inst) = inst.dest  # only call when has_dest is true
```
Or use `applicable(getfield, inst, :dest)` -- though this is equally reflective.

---

### F11 -- MEDIUM: `ir_types.jl:134-145` overloads `getproperty` for backward compat

**File:** `src/ir_types.jl:134-145`
**Issue:** `Base.getproperty(p::ParsedIR, name::Symbol)` allocates a new `Vector{IRInst}` every time `parsed.instructions` is accessed. This is a hidden allocation that callers may not expect.
**Fix:** Either cache the flattened instructions (add a field), or remove the backward-compat property and update all callers to iterate blocks directly. The property is only used in the legacy parser tests.

---

### F12 -- MEDIUM: Global callee registry iteration in `_lookup_callee`

**File:** `src/ir_extract.jl:42-49`
**Issue:** Linear scan with `occursin` on every LLVM call instruction. With 15 registered callees, this is 15 substring searches per call.
**Fix:** Pre-compute a lookup. Since LLVM names follow `j_funcname_NNN` pattern:
```julia
function _lookup_callee(llvm_name::String)
    # Extract the function name part: "j_soft_fadd_1234" -> "soft_fadd"
    for (jname, f) in _known_callees
        if occursin(jname, lowercase(llvm_name))
            return f
        end
    end
    return nothing
end
```
The current implementation is correct but could be improved with a trie or prefix map for larger registries.

---

### F13 -- MEDIUM: Thread-unsafe global state

**Files:** `src/ir_extract.jl:33,56`
**Issue:** `_known_callees` and `_name_counter` are global mutable state with no synchronization. If two threads call `reversible_compile` simultaneously, name counter corruption will occur.
**Fix:** For now, document that `reversible_compile` is not thread-safe. Long-term, pass a compilation context object instead of using globals:
```julia
struct CompileContext
    name_counter::Ref{Int}
    known_callees::Dict{String, Function}
end
```

---

### F14 -- MEDIUM: Missing `@inline` on hot small functions

**Files:** `src/simulator.jl:1-3`, `src/dep_dag.jl:90-96`
**Issue:** `apply!(b, g::NOTGate)`, `apply!(b, g::CNOTGate)`, `apply!(b, g::ToffoliGate)` are the innermost loop of simulation. They are one-line functions that Julia may or may not inline. `_gate_target` and `_gate_controls` are similarly tiny.
**Fix:**
```julia
@inline apply!(b::Vector{Bool}, g::NOTGate) = (b[g.target] ^= true; nothing)
@inline apply!(b::Vector{Bool}, g::CNOTGate) = (b[g.target] ^= b[g.control]; nothing)
@inline apply!(b::Vector{Bool}, g::ToffoliGate) = (b[g.target] ^= b[g.control1] & b[g.control2]; nothing)
```
Julia will likely inline these anyway due to their size, but `@inline` makes the intent explicit and guarantees it.

---

### F15 -- MEDIUM: `collect(LLVM.parameters(func))` allocates unnecessarily

**File:** `src/ir_extract.jl:848`
**Issue:** `collect(LLVM.parameters(func))` in `_get_deref_bytes` materializes the parameter iterator into an array just to call `findfirst`. Use the iterator directly.
**Fix:**
```julia
idx = 0
for p in LLVM.parameters(func)
    idx += 1
    p.ref == param.ref && break
end
```

---

### F16 -- MEDIUM: `ir_extract.jl:856-860` bare `catch` swallows all exceptions

**File:** `src/ir_extract.jl:856-860`
**Issue:** `try ... catch ... end` with no exception type filter. This catches `InterruptException`, `OutOfMemoryError`, etc.
**Fix:**
```julia
try
    for attr in LLVM.parameter_attributes(func, idx)
        # ...
    end
catch e
    e isa MethodError || rethrow()  # only catch expected failures
end
```

---

### F17 -- MEDIUM: Cuccaro adder `lower_add_cuccaro!` returns input vector

**File:** `src/adder.jl:79`
**Issue:** `return b` returns the caller's input wire vector. This means the result aliases the input, which is intentional (in-place) but could surprise callers who expect a fresh allocation. Document this clearly.
**Fix:** Add a docstring note:
```julia
"""
...
Returns `b` (in-place: the result overwrites b's wires). The caller
must ensure b's wires are not needed elsewhere after this call.
"""
```

---

### F18 -- MEDIUM: `diagnostics.jl:131` uses `for (_, w) in enumerate(c.input_widths)`

**File:** `src/diagnostics.jl:131`
**Issue:** Unused loop variable from `enumerate`. Should use `for w in c.input_widths` since the index is not needed (the offset is computed manually).
**Fix:**
```julia
for w in c.input_widths
    for i in 1:w
        bits[c.input_wires[offset + i]] = rand(Bool)
    end
    offset += w
end
```
Same pattern at `simulator.jl:18`, `controlled.jl:71`, `controlled.jl:95`.

---

### F19 -- LOW: Inconsistent function signature styles

**Files:** Various in `lower.jl`
**Issue:** Some lowering functions have full type annotations (`lower_add!(gates::Vector{ReversibleGate}, wa::WireAllocator, ...)`) while others use bare names (`lower_and!(g, wa, a, b, W)`). The short names (`g` for gates, `W` for width) are used in the bitwise/shift/comparison helpers but not in the main lowering functions.
**Fix:** Standardize. Either annotate all or none. For internal functions, bare names are fine if consistent.

---

### F20 -- LOW: `Tuple(vals)` in `_read_output` creates untyped tuple

**File:** `src/simulator.jl:48`
**Issue:** `Tuple(vals)` on a `Vector{Any}` creates a `Tuple{Any, Any, ...}` rather than a concretely-typed tuple. If fixed to `Vector{Int64}`, the tuple would be `NTuple{N, Int64}`.
**Fix:** Address with F2 fix.

---

### F21 -- LOW: `ir_types.jl:126-131` -- `ParsedIR` has `ret_elem_widths::Vector{Int}`

**File:** `src/ir_types.jl:130`
**Issue:** This is typically 1-2 elements. A `Tuple` or `SVector` would avoid heap allocation. However, the size is dynamic (depends on return type), so `Vector` is correct. Low priority.

---

### F22 -- LOW: Missing `sizehint!` on frequently-grown vectors

**Files:** `src/lower.jl:174`, `src/ir_extract.jl:132`
**Issue:** `gates = ReversibleGate[]` and `blocks = IRBasicBlock[]` grow by `push!` during lowering/extraction. For large functions, pre-sizing would avoid repeated reallocations.
**Fix:**
```julia
gates = ReversibleGate[]
sizehint!(gates, 1000)  # typical circuit has 100-10000 gates
```

---

### F23 -- LOW: `lower.jl:1380` -- `Tuple{(UInt64 for _ in inst.args)...}` generator trick

**File:** `src/lower.jl:1380`
**Issue:** The generator `(UInt64 for _ in inst.args)...` splatted into `Tuple{}` is idiomatic but obscure. `ntuple(_ -> UInt64, length(inst.args))` is more conventional for creating type tuples... except that actually produces an `NTuple` of values, not types. The current code is actually correct for constructing a `Type{Tuple{UInt64, UInt64, ...}}`.
**Fix:** Add a comment explaining what this does:
```julia
# Construct Tuple{UInt64, UInt64, ...} with one UInt64 per argument
arg_types = Tuple{(UInt64 for _ in inst.args)...}
```

---

### F24 -- LOW: Tests use `println` for diagnostic output

**Files:** 34 test files, 104 `println` calls
**Issue:** Test files print diagnostic information (gate counts, IR, etc.) to stdout. This clutters test output. Use `@info` for optional diagnostics or suppress in CI.
**Fix:** Replace `println("  Increment: ", gate_count(circuit))` with `@info "Increment" gate_count(circuit)` or remove entirely. Test assertions should be the primary signal, not printed output.

---

### F25 -- LOW: `test_branch.jl:15-18` prints raw IR in tests

**File:** `test/test_branch.jl:15-18`
**Issue:** `println("  q(x) IR:\n", ir)` dumps raw LLVM IR to test output. This is useful for debugging but noisy in CI.
**Fix:** Remove or gate behind an environment variable.

---

### F26 -- LOW: `test_softfloat.jl:14,40` defines `check_fadd` twice in different testsets

**File:** `test/test_softfloat.jl:14,40`
**Issue:** The helper function `check_fadd` is defined identically in two nested `@testset` blocks. This is technically fine (each closure captures its own scope) but is unnecessary duplication.
**Fix:** Define `check_fadd` once before the testsets, or factor into a test utility file.

---

### F27 -- LOW: `lower.jl:49` `val = op.value & ((1 << width) - 1)` may overflow for width=64

**File:** `src/lower.jl:49`
**Issue:** `1 << 64` overflows `Int64`. For width=64, this expression produces 0 (since `1 << 64 == 0` in Int64), making the mask 0xFFFFFFFFFFFFFFFF... actually, `1 << 64` in Julia wraps to 0, so `(1 << 64) - 1 = -1` which as a bit pattern is all ones. This works correctly by accident due to two's complement, but is fragile and non-obvious.
**Fix:**
```julia
val = width >= 64 ? op.value : op.value & ((1 << width) - 1)
```
Or use `UInt64`:
```julia
mask = width >= 64 ? typemax(UInt64) : (UInt64(1) << width) - UInt64(1)
val = op.value & Int(mask)
```

---

### F28 -- LOW: `ir_types.jl:109` `IRSwitch.cases` has non-parametric element type

**File:** `src/ir_types.jl:109`
**Issue:** `cases::Vector{Tuple{IROperand, Symbol}}`. This is concretely typed and correct. No issue.

---

### F29 -- MEDIUM: `_ssa_operands` defined as 14 separate methods without a fallback

**Files:** `src/lower.jl:68-125`
**Issue:** 14 method definitions for `_ssa_operands`, one per IR instruction type. If a new `IRInst` subtype is added without a corresponding `_ssa_operands` method, this will throw a `MethodError` at runtime rather than at definition time. Add a fallback:
```julia
_ssa_operands(::IRInst) = Symbol[]  # default: no SSA operands
```

---

### F30 -- MEDIUM: `ir_extract.jl:139` checks `ir_inst isa Vector` for multi-instruction expansion

**File:** `src/ir_extract.jl:139-146`
**Issue:** The instruction converter returns `Union{Nothing, IRInst, Vector{IRInst}}`. The caller checks `isa Vector` at line 139. This is a runtime type check that could be eliminated by always returning a vector.
**Fix:** Normalize the return type:
```julia
# In _convert_instruction: always return Vector{IRInst}
# Single instruction: return [inst]
# Skip: return IRInst[]
# Multi: return [inst1, inst2, ...]
```
Then the loop simplifies to `append!(insts, ir_insts)`.

---

## Recommendations

### Priority 1 (High impact, low effort)

1. **Replace `@assert` with `error()` in all production paths** (F1). This is a one-line change per site and aligns with the project's own CLAUDE.md principle "FAIL FAST, FAIL LOUD."

2. **Type the `[]` literals** (F2, F3). Change `vals = []` to `vals = Int64[]` and `phi_info = []` to the correct tuple type. Two-line fixes.

3. **Add `@inline` to `apply!` methods** (F14). One annotation per method, guaranteed to help simulation performance.

### Priority 2 (Medium impact, medium effort)

4. **Extract duplicated softfloat code** (F7). Create `_normalize_clz`, `_round_to_nearest_even`, `_handle_subnormal` helper functions. Test that they still produce clean LLVM IR for circuit compilation.

5. **Extract duplicated Bennett construction helpers** (F46, F47). Create `_compute_ancillae(input_wires, output_wires, total)` and `_allocate_copy_wires(lr)`.

6. **Use multiple dispatch for lowering** (F5). Replace the `isa` chain with dispatched methods. This is a larger refactor but improves extensibility.

### Priority 3 (Maintenance and cleanliness)

7. **Break up `_convert_instruction`** (F4). Split into category handlers. Largest single-function technical debt.

8. **Add docstrings to exported types and key functions** (F51-F57). Especially `ReversibleCircuit`, `lower()`, and the gate types.

9. **Fix thread-safety of global state** (F13). Either document the limitation or pass a context object.

10. **Address `WireAllocator` heap semantics** (F8). Either use a real heap or document the O(n) cost.
