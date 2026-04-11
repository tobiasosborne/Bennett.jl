# Linus Torvalds Reviews Bennett.jl

Date: 2026-04-11
Codebase: 5,599 lines across 30 source files, 47 test files.

---

## Overall Impression

Let me start with what this project is: a compiler from Julia functions to
reversible circuits. That is a genuinely hard problem, and the code mostly
does it correctly. The test suite is extensive and the core invariant (all
ancillae return to zero) is actually checked. That puts it ahead of 90% of
the "compiler" projects I see.

But there are real problems here, and some of them are structural. The
codebase has the unmistakable smell of incremental growth by AI agents --
each one bolting on more features without ever going back to clean up. The
result is a 1420-line lower.jl that does too many things, massive code
duplication in the soft-float library, global mutable state used for name
generation, and an abstraction layer (GateGroup) that has grown three
different backward-compatible constructors because nobody wanted to fix the
call sites.

The code is not bad. It is messy in the way that working compilers are
messy. But the mess is going to bite you soon if you don't clean it up.

---

## The Good

1. **Bennett construction is clean.** `bennett.jl` is 28 lines. It does
   exactly one thing. Forward, copy, reverse. I can read it and know it's
   correct. This is what good code looks like.

2. **Gates are simple value types.** `gates.jl` is 28 lines of pure data.
   NOTGate, CNOTGate, ToffoliGate. No inheritance hierarchy, no visitor
   pattern, no abstract factory. Just structs with wire indices. Perfect.

3. **The simulator is straightforward.** `simulator.jl` at 63 lines. Three
   `apply!` methods, one simulation loop, one ancilla check. Easy to verify
   correct by inspection.

4. **Testing is thorough.** 47 test files. Int8 functions tested on all 256
   inputs. Soft-float tested against hardware. Reversibility verified on
   every circuit. This is the right approach for a compiler -- exhaustive
   testing where feasible.

5. **Soft-float is branchless.** The decision to make soft_fadd, soft_fmul
   etc. fully branchless (using ifelse throughout) is correct for the
   problem domain. It avoids phi nodes that would create false-path
   sensitization bugs. The code explains WHY it's branchless. Good.

6. **Error messages are specific.** `error("Undefined SSA variable: %$(op.name)")`,
   `error("Block $label has no terminator")` -- these tell you exactly what
   went wrong and where. Not `error("bad state")`.

7. **The Cuccaro in-place adder.** A nice optimization (1 ancilla vs n-1),
   gated by SSA liveness analysis so it only fires when the operand is
   dead. The liveness check is clean and correct.

---

## The Bad

1. **Global mutable state for name generation.** `_name_counter` is a
   module-level `Ref(0)` that gets reset by `_reset_names!()` at the
   start of each compilation. This is thread-unsafe and fragile. The
   `lower_call!` function even has to save/restore it manually (line 1381).
   This is the kind of thing that works until it doesn't, and when it
   doesn't, you'll spend a day debugging why SSA names collide.

2. **lower.jl is 1420 lines.** This file does: operand resolution, SSA
   liveness analysis, the main lowering loop, topological sort, loop
   detection, loop unrolling, path predicate computation, phi resolution
   (two different algorithms), all binary operations, all comparisons,
   shifts (constant AND variable), MUX, casts, aggregate operations,
   pointer operations, variable GEP with MUX trees, function call inlining,
   constant folding, and division via soft integer calls. That is not "one
   file does one thing." That is "one file does everything."

3. **The `_known_callees` registry.** A global `Dict{String, Function}`
   that maps substrings of LLVM function names to Julia functions. The
   lookup (`_lookup_callee`) does `occursin(jname, lowercase(llvm_name))`.
   This is O(n) in the number of registered callees for every single LLVM
   call instruction, and it's substring matching, which means if you
   register a function called "add" it will match "soft_fadd". The fact
   that it works is luck, not design.

4. **Duplicated rounding/normalization code in soft-float.** The subnormal
   CLZ normalization (the six-stage binary search: need32, need16, need8,
   need4, need2, need1) is copy-pasted identically in `fadd.jl` (lines
   117-139), `fmul.jl` (lines 193-215), and `fdiv.jl` (lines 69-91). The
   rounding code (guard/round/sticky, round-to-nearest-even, pack) is
   copy-pasted between all three files. The subnormal result handling is
   copy-pasted between all three files. That is at least 150 lines of
   duplicated logic across three files. When (not if) you find a rounding
   bug, you'll have to fix it in three places and hope you get all three
   right.

5. **The `ir_parser.jl` legacy parser.** 168 lines of regex-based LLVM IR
   parsing that the CLAUDE.md file itself calls "legacy regex parser
   (backward compat)." It's still included, still exported (`parse_ir`),
   and still has a test file (`test_parse.jl`). If you've moved to the
   LLVM.jl C API walker, kill the dead code. Every line of dead code is a
   line someone has to understand and a line that could confuse.

6. **GateGroup has three constructors for backward compatibility.**
   ```julia
   GateGroup(name, gs, ge, rw, ivars) = GateGroup(name, gs, ge, rw, ivars, 0, -1, Int[])
   GateGroup(name, gs, ge, rw, ivars, ws, we) = GateGroup(name, gs, ge, rw, ivars, ws, we, Int[])
   ```
   This means the struct grew twice and nobody updated the call sites. That
   is not backward compatibility. That is technical debt pretending to be a
   feature.

7. **ParsedIR has a `getproperty` hack.** Lines 134-146 of `ir_types.jl`
   override `Base.getproperty` so that `parsed.instructions` dynamically
   flattens all blocks. This is a compatibility hack that hides the actual
   structure of the data. Anyone reading `parsed.instructions` will think
   it's a field. It's not. It's a computed property that allocates a new
   array every time you call it. If someone puts it in a loop, they'll
   wonder why their compiler is slow.

---

## The Ugly

1. **`_convert_instruction` in ir_extract.jl is a 580-line function.**
   Lines 265-840. It handles every LLVM opcode via a chain of
   `if opc == ...` blocks. Some of those blocks (like the intrinsic
   handlers) are 30+ lines each. The function for `llvm.ctpop` alone is
   20 lines of IR construction. `llvm.ctlz` is another 20. The fcmp
   handler is 30 lines of predicate mapping. This function MUST be broken
   up. Each opcode family should be its own function.

2. **The phi resolution has TWO algorithms.** `resolve_phi_predicated!`
   (path predicates, lines 725-759) and `resolve_phi_muxes!` (reachability
   analysis, lines 818-867). `lower_phi!` chooses between them based on
   whether `block_pred` is non-empty. The reachability-based one has the
   known false-path sensitization bug documented in CLAUDE.md. The
   predicated one is the fix. But the old one is still there, still called,
   and the selection logic is implicit. If `block_pred` happens to be empty
   for some code path, you silently fall back to the buggy algorithm. This
   is a correctness hazard.

3. **The `lower` function signature.**
   ```julia
   function lower(parsed::ParsedIR; max_loop_iterations::Int=0, use_inplace::Bool=true,
                  use_karatsuba::Bool=false, fold_constants::Bool=false)
   ```
   Four keyword arguments controlling different optimization passes. This
   function is the entire middle-end of the compiler, controlled by boolean
   flags. That's a sign that it should be decomposed into passes, not
   parameter-ized into a monolith.

4. **Wire allocator's "min-heap" is a sorted array.** `wire_allocator.jl`
   line 24: `insert!(wa.free_list, idx, w)` with `searchsortedfirst`. This
   is O(n) insertion into a sorted vector, not a heap. The comment says
   "min-heap." It is not a min-heap. It is a sorted list with O(n) insert.
   For small circuits this doesn't matter. For the SHA-256 circuits with
   thousands of wires, this could be significant. At least fix the comment
   so it doesn't lie.

5. **The SoftFloat dispatch wrapper in Bennett.jl.** Lines 74-141. This
   defines a `SoftFloat` struct with operator overloading for `+`, `*`,
   `-`, `/`, `<`, `==`, `copysign`, `abs`, `floor`, `ceil`, `trunc`. Then
   the `reversible_compile` method for Float64 manually dispatches on
   argument count (1, 2, or 3) with hardcoded wrapper lambdas. You can't
   compile a float function with 4 arguments. This limit is artificial and
   the code says so (`error("Float64 compile supports up to 3 arguments")`).
   The fix is obvious: generate the wrapper dynamically for any N.

---

## File-by-File Notes (the important ones)

### src/ir_extract.jl (923 lines)

The two-pass name table approach (name everything first, then convert) is
sound. The `_convert_instruction` monster function is the main problem.
The callee registry substring matching is fragile. The `_get_deref_bytes`
function (lines 846-872) has a `try/catch` that swallows all exceptions
(line 859: bare `catch`) -- this hides bugs.

### src/lower.jl (1420 lines)

This is the file that needs the most work. It is doing the job of at least
five files:
- Operand resolution and SSA liveness
- The main lowering dispatch loop
- Control flow (topo sort, loop detection, loop unrolling)
- Phi resolution (two algorithms)
- All instruction lowerings (binops, comparisons, shifts, MUX, casts,
  aggregates, pointers, calls)

The constant folding pass (`_fold_constants`, lines 323-416) is embedded
here too. It should be its own file.

### src/softfloat/ (973 lines total)

The soft-float functions are correct (they have to be, and the tests
verify it). But they are violating DRY so aggressively it hurts.
The normalization, rounding, and packing code should be shared helper
functions. `fsub.jl` is 9 lines (it just calls fadd(a, fneg(b))). Good.
Do the same kind of factoring for the shared internals.

### src/pebbled_groups.jl (402 lines)

The most complex of the Bennett variant files. The `_replay_forward!`
function (lines 35-100) has to handle wire remapping for both newly
allocated wires and in-place results from dependencies. This is inherently
complex, and the code handles it correctly as far as I can tell. But the
fallback chain in `pebbled_group_bennett` (lines 217-279) has THREE
different conditions that fall back to `bennett(lr)`: empty groups,
in-place results, and `checkpoint_bennett` preference. This is defensive
but opaque -- the caller has no idea which strategy was actually used.

### src/diagnostics.jl (143 lines)

Clean. `gate_count` is a named tuple, which is nice. `peak_live_wires`
actually simulates the circuit bit-by-bit to track live wires. That's
correct but O(gates * wires). For large circuits, consider a wire-level
birth/death analysis instead.

### src/eager.jl (124 lines)

The NOTE at the bottom (lines 117-124) is excellent documentation:
"Wire-level EAGER was attempted but FAILS" with a clear explanation of
WHY. This is the kind of institutional knowledge that saves future
developers hours of debugging. More of this everywhere.

---

## Specific Findings

### Severity: CRITICAL

**1. [CRITICAL] src/lower.jl:767-776 -- Silent fallback to buggy phi algorithm**

```julia
if !isempty(block_pred)
    vw[inst.dest] = resolve_phi_predicated!(...)
else
    vw[inst.dest] = resolve_phi_muxes!(...)
end
```

If `block_pred` is empty for ANY reason (a bug, an edge case, a new code
path), you silently fall back to the algorithm that has known false-path
sensitization bugs. This should either (a) always use predicated, or
(b) `error()` when block_pred is missing. Silent fallback to a buggy code
path is how you get security vulnerabilities in compilers.

**Fix:** Remove `resolve_phi_muxes!` entirely, or gate it behind an
explicit `unsafe_legacy_phi=true` flag that defaults to false.

---

**2. [CRITICAL] src/ir_extract.jl:57-63 -- Global mutable name counter**

```julia
const _name_counter = Ref(0)
function _reset_names!()
    _name_counter[] = 0
end
```

This is module-level mutable state. It is reset at the top of
`reversible_compile` AND at the top of `_module_to_parsed_ir`. The
`lower_call!` function saves and restores it manually. If any code path
forgets to reset or restore, SSA names will collide, and the resulting
bug will be somewhere deep in phi resolution, not at the point of the
actual error.

**Fix:** Make the name counter a field on a compilation context struct
that is threaded through all functions. Or at minimum, make it a
parameter of `_module_to_parsed_ir` and `_convert_instruction`.

---

### Severity: HIGH

**3. [HIGH] src/ir_extract.jl:858-859 -- Bare try/catch swallows errors**

```julia
try
    for attr in LLVM.parameter_attributes(func, idx)
        ...
    end
catch
end
```

This catches ALL exceptions, including `MethodError`, `BoundsError`, and
`StackOverflowError`. If the LLVM.jl API changes or has a bug, you'll
silently skip the attribute check and produce wrong dereferenceable byte
counts.

**Fix:** `catch e; e isa MethodError && rethrow()` at minimum, or better,
figure out what specific exception you're guarding against and catch only
that.

---

**4. [HIGH] src/lower.jl:1252 -- Dead code on the same line**

```julia
base_wires = resolve!(gates, wa, vw, inst.base, 0)  # width unknown, use name lookup
if !haskey(vw, inst.base.name)
    error(...)
end
base_wires = vw[inst.base.name]
```

Line 1252 calls `resolve!` with width=0. This will allocate 0 wires for
a constant (returning an empty array) or return the existing SSA wires.
Then line 1256 immediately overwrites `base_wires` with a direct lookup.
The `resolve!` call is dead code AND it has the side effect of potentially
allocating wires. Either the resolve! is needed (in which case use its
result) or it's not (in which case remove it).

**Fix:** Remove line 1252. The direct lookup on 1256 is what you want.

---

**5. [HIGH] src/lower.jl:449-452 -- Silent instruction drop**

```julia
elseif inst isa IRCall
    lower_call!(gates, wa, vw, inst)
end
```

If an instruction type is not handled by any of the `elseif` branches,
the `end` falls through silently. There is no `else error("Unhandled
instruction type: $(typeof(inst))")`. An unrecognized instruction will
be silently ignored, producing a circuit that computes the wrong answer.
The error will manifest far away from the cause.

**Fix:** Add `else error("Unhandled instruction type: $(typeof(inst))")` 
before the final `end`.

---

**6. [HIGH] src/softfloat/ -- ~150 lines of duplicated code**

The CLZ normalization cascade (6 stages, ~24 lines), the rounding code
(~20 lines), the subnormal result handling (~15 lines), and the result
packing (~10 lines) are copy-pasted across `fadd.jl`, `fmul.jl`, and
`fdiv.jl`. This is maintenance poison.

**Fix:** Extract into `_normalize_clz!`, `_round_to_nearest_even`, 
`_handle_subnormal`, `_pack_result` helpers in a shared file. Since 
these must remain branchless, they can still be pure functions taking 
`wr` and `result_exp` and returning the updated values.

---

### Severity: MEDIUM

**7. [MEDIUM] src/ir_extract.jl:42-49 -- O(n) callee lookup via substring**

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

Linear scan with substring matching. If you register "add", it matches
"soft_fadd". Currently works because no registered name is a substring of
another, but this is an accident waiting to happen.

**Fix:** Match on the exact Julia function name, not substring. Extract
the Julia name from the LLVM mangled name first, then do a dict lookup.

---

**8. [MEDIUM] src/ir_types.jl:134-145 -- Computed property masquerading as field**

```julia
function Base.getproperty(p::ParsedIR, name::Symbol)
    if name === :instructions
        insts = IRInst[]
        for block in getfield(p, :blocks)
            append!(insts, block.instructions)
            push!(insts, block.terminator)
        end
        return insts
    ...
```

Every access to `parsed.instructions` allocates a new array. It's used
in `parse_ir` return values and potentially in loops. This is a
performance trap and a readability trap.

**Fix:** Either cache the flattened instructions on construction, or
remove the property override and make callers use an explicit
`flatten_instructions(parsed)` function that communicates the allocation.

---

**9. [MEDIUM] src/wire_allocator.jl:23-28 -- Misleading "min-heap" comment**

```julia
"""Return wires to the allocator for reuse. Wires MUST be in zero state."""
function free!(wa::WireAllocator, wires::Vector{Int})
    for w in wires
        # Insert sorted (maintain min-heap property via sorted list)
        idx = searchsortedfirst(wa.free_list, w)
        insert!(wa.free_list, idx, w)
    end
end
```

The comment says "min-heap." The code is a sorted array with O(n) insert
via `insert!` (which shifts elements). For N free wires, freeing M wires
costs O(M*N). A real min-heap would be O(M*log(N)).

**Fix:** Either use a real heap (`DataStructures.BinaryMinHeap`) or fix
the comment to say "sorted list." Given the circuit sizes you're dealing
with (thousands of wires), a heap would be the right choice.

---

**10. [MEDIUM] src/Bennett.jl:129-141 -- Hardcoded 1/2/3 argument dispatch**

```julia
if N == 1
    w = (x::UInt64) -> (@inline f(SoftFloat(x))).bits
    ...
elseif N == 2
    ...
elseif N == 3
    ...
else
    error("Float64 compile supports up to 3 arguments (got $N)")
end
```

Manual case-split for argument counts 1 through 3. Arbitrary limit that
will cause a confusing error for anyone with a 4-argument float function.

**Fix:** Use `@generated` or `ntuple` to generate the wrapper for
arbitrary N. Julia's type system can handle this generically.

---

**11. [MEDIUM] src/pebbled_groups.jl:223-234 -- Triple fallback chain**

```julia
has_inplace = any(g -> ...)
if has_inplace
    return bennett(lr)
end
if all(g -> g.wire_start > 0, groups)
    return checkpoint_bennett(lr)
end
...
if max_pebbles <= 0 || max_pebbles >= n_groups
    return bennett(lr)
end
```

Three different reasons to fall back, and the caller never knows which
strategy was used. This should at minimum log which path was taken.
Better: separate the strategy selection from the execution so the caller
can inspect the choice.

---

**12. [MEDIUM] src/lower.jl:70-125 -- 13 separate `_ssa_operands` methods**

Thirteen nearly identical functions that extract SSA operand names from
different instruction types. Each one is 2-5 lines and follows the same
pattern: check if each operand is `:ssa`, push its name. This is the kind
of mechanical repetition that screams for a default implementation.

**Fix:** Since all instructions store operands as `IROperand`, define a
generic `_ssa_operands` using reflection over the struct fields, or give
`IRInst` a method that lists all `IROperand` fields. Then override only
for the exceptions.

---

### Severity: LOW

**13. [LOW] src/lower.jl:924-947 -- Single-letter variable names**

```julia
function lower_and!(g, wa, a, b, W)
    r = allocate!(wa, W)
    for i in 1:W; push!(g, ToffoliGate(a[i], b[i], r[i])); end
    return r
end
```

`g` for gates, `r` for result, `W` for width. These are small functions
and the context makes it clear, so this is LOW severity. But the
inconsistency bothers me: `gates` in some functions, `g` in others.
Pick one convention and stick with it.

---

**14. [LOW] src/ir_parser.jl -- Dead code**

168 lines of regex-based LLVM IR parsing that the CLAUDE.md explicitly
labels as "legacy." The LLVM.jl C API walker (`ir_extract.jl`) is the
real implementation. This dead code confuses newcomers and adds to the
maintenance surface.

**Fix:** Remove ir_parser.jl and test_parse.jl. If you need it for
debugging, put it in a separate debugging utility, not the main module.

---

**15. [LOW] src/diagnostics.jl:110-125 -- peak_live_wires simulates entire circuit**

```julia
function peak_live_wires(c::ReversibleCircuit)
    ...
    bits = zeros(Bool, c.n_wires)
    for g in c.gates
        apply!(bits, g)
        ...
```

This simulates every gate to track non-zero wires. For the SHA-256
circuit this is thousands of gates on thousands of wires. A static
analysis based on wire birth/death would be O(gates) without the
bit-vector simulation.

---

**16. [LOW] src/lower.jl:598-603 -- Incomplete instruction dispatch in loop body**

```julia
for inst in body_insts
    if inst isa IRBinOp;    lower_binop!(gates, wa, vw, inst)
    elseif inst isa IRICmp; lower_icmp!(gates, wa, vw, inst)
    elseif inst isa IRSelect; lower_select!(gates, wa, vw, inst)
    elseif inst isa IRCast; lower_cast!(gates, wa, vw, inst)
    end
end
```

The loop body handler only supports 4 instruction types. The main
`lower_block_insts!` handles 11. If a loop body contains a call, load,
GEP, extractvalue, or insertvalue, it will be silently dropped. This
is the same silent-drop bug as finding #5 but in a different code path.

**Fix:** Either call `lower_block_insts!` for loop bodies (refactoring
to share code), or add the missing cases and an `else error(...)`.

---

**17. [LOW] src/fmul.jl:99-132 -- Commentary rewriting the same calculation three times**

The mantissa multiply assembly has three attempts at explaining the
128-bit product assembly:

```julia
# prod_hi = (cross >> 38) + pp_hh + carry_lo + (pp_hh_lo_part)
...
# Actually, we need to add pp_hh*2^52 to the 128-bit product.
...
# Restart assembly more carefully:
```

The code starts one approach, realizes it's wrong, comments "Actually,"
and starts over. Then comments "Restart assembly more carefully:" and
does it a third way. The dead-end approaches should be deleted. Leave only
the final correct version.

---

## Final Verdict

This is a working compiler. It compiles Julia functions into correct
reversible circuits, it has thorough tests, and the core construction
(Bennett's 1973 trick) is implemented beautifully. The soft-float library
is impressive -- bit-exact IEEE 754 in pure integer arithmetic is no small
feat, and the branchless discipline is correctly motivated.

The problems are all maintenance problems: a 1420-line file that should be
five files, duplicated code in soft-float, global mutable state for name
generation, a legacy parser that should be deleted, and two phi resolution
algorithms where only one is correct.

The critical items are:

1. **Fix the silent phi fallback.** This is a correctness hazard. The
   predicated algorithm should be the only path, or the legacy one should
   require an explicit opt-in.

2. **Thread the name counter through a context.** Global mutable state in
   a compiler is asking for trouble, especially when lower_call! does
   recursive compilation.

3. **Break up lower.jl.** The file is doing the work of half the compiler.
   Split it into: lowering_core.jl (dispatch loop, operand resolution),
   lower_control_flow.jl (topo sort, loops, phi), lower_arithmetic.jl
   (binops, comparisons, shifts), lower_memory.jl (GEP, load, aggregates),
   lower_calls.jl (call inlining).

4. **Factor the soft-float common code.** The next rounding bug will be
   fixed in one file and missed in two others.

Everything else is cleanup that makes the code nicer but doesn't risk
correctness.

The project has good bones. The architecture (extract, lower, Bennett,
simulate) is sound. The gate types are right. The testing is right. The
documentation (CLAUDE.md, the WORKLOG requirement) is right. Now stop
adding features and clean up what you have.

*-- Linus*
