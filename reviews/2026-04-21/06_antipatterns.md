# Bennett.jl — Antipatterns, Code Smells, Style Drift

Reviewer: code-smell hunter (independent, skeptical, harsh).
Scope: ~13,300 LOC across `src/*.jl`, `src/softfloat/*.jl`, `src/persistent/*.jl`.
Date: 2026-04-21.

This is not a structural review, a correctness review, or an architecture review —
those are other people's jobs. This is about bad taste, flag accretion, god
functions, silent fallbacks, primitive obsession, and violations of the
project's own non-negotiable principles. If the same mechanism was added six
times by hand and then a seventh time via `@eval`, that goes here. If a
function has eleven constructor overloads because nobody wanted to update
callers, that goes here too.

---

## Executive summary (top systemic smells)

1. **`ir_extract.jl::_convert_instruction` is a 649-line god function.** One
   top-level `if/elseif` cascade for every LLVM opcode + every `llvm.*`
   intrinsic expansion inlined in the arm. It is the single most concentrated
   piece of bad taste in the codebase. Dispatch-on-type or a handler table
   would cut this by 10x. See CRITICAL-1.
2. **`lower.jl` and `ir_extract.jl` are both near 2500 lines** (2662 and
   2394). Together they are 38% of all source. They are god modules by any
   objective metric.
3. **CLAUDE.md §5 violation — `src/ir_parser.jl` is dead live-code.** A
   168-line regex parser for LLVM IR, explicitly forbidden by "LLVM IR is
   not stable; the LLVM.jl C API walker is the source of truth." Still
   `include`d in the module and still `export`ed as `parse_ir`.
4. **CLAUDE.md §12 violation — three distinct codepaths for the same op.**
   Integer division is emitted three different ways: `lower_divrem!` which
   routes to `soft_udiv/soft_urem` callees, the `soft_udiv/soft_urem`
   themselves, and the `_lookup_callee` path for user-registered callees
   with the same name. Similar for mul (3 impls: `lower_mul!`,
   `lower_mul_karatsuba!`, `lower_mul_qcla_tree!`) and add (3 impls).
5. **Stringly-typed strategy dispatch, pervasive.** `add::Symbol`,
   `mul::Symbol`, `strategy::Symbol`, `decomp::Symbol`, and a dozen
   `if strategy == :shadow elseif strategy == :mux_exch_2x8 elseif ...`
   ladders. No `@enum`, no `Val{}` dispatch, no sealed set anywhere.
   45 call sites compare `.kind == :ssa` / `.kind == :const` on
   `IROperand`; 14 sites compare `inst.op == :xxx`. These are free
   functions' worth of type safety being discarded at every use.
6. **Primitive obsession: `IROperand` uses a Symbol discriminator plus
   two always-populated fields.** `IROperand(kind::Symbol, name::Symbol,
   value::Int)` where kind is either `:ssa` (name meaningful, value=0) or
   `:const` (name=Symbol(""), value meaningful). Julia has union types.
   This should be `IROperand = Union{SSAVar, IntConst}` with two structs.
   Downstream code would stop doing `.kind == :ssa` runtime dispatch and
   start doing method dispatch. See HIGH-1.
7. **`LoweringCtx` has 18 fields, 4 constructors, and three fields typed
   `::Any`** (`preds`, `branch_info`, `block_order`). The comment says
   "typed Any to accept any dict shape from caller." That's a god struct
   with a note saying "we gave up on types."
8. **`ParsedIR` has one `::Any` field** (`memssa`) to "avoid circular type
   dependency with src/memssa.jl" — addressable by moving the type
   definition or forward-declaring.
9. **Five `bennett_*` entry points with no discriminated-union dispatch.**
   `bennett`, `eager_bennett`, `value_eager_bennett`, `pebbled_bennett`,
   `pebbled_group_bennett`, `checkpoint_bennett`. Each is a separate
   exported function. No `Strategy` type, no single dispatch point.
   Each variant reimplements the same Phase 1/2/3 scaffolding with
   subtle differences.
10. **`reversible_compile` has three overloads with accreted kwargs.**
    Six `::Bool` kwargs (`optimize`, `compact_calls`, `preprocess`,
    `use_memory_ssa`, `use_inplace`, `use_karatsuba`, `fold_constants`),
    plus three `::Symbol` kwargs (`add`, `mul`, `strategy`). Boolean
    blindness; `optimize` is not the same axis as `compact_calls`.
11. **Backward-compat constructor graveyard.** `LoweringCtx` has 4
    constructors. `LoweringResult` has 3 constructors (7-arg, 8-arg,
    10-arg). `ParsedIR` has 3 constructors (4-, 5-, 7-arg). Comments
    like `# 8-arg constructor (legacy, pre-P1)` are admissions. Nobody
    ever dropped the old ones.
12. **`try; ... catch; "" end` and `try; ... catch; nothing end` in
    ir_extract.jl** — nine instances. Several swallow real iterator
    exceptions from LLVM.jl's operand iterator. This is the
    error-swallowing pattern that CLAUDE.md §1 forbids. Understandable
    for LLVM GlobalAlias, but not justified as broadly as it's used.
13. **Massive copy-pasted softmem.jl.** Seven `soft_mux_load_NxW` and
    seven `soft_mux_store_NxW` pairs, each a hand-written N-slot
    shift+mask+ifelse ladder. The (4,8) and (8,8) are hand-written;
    the rest are generated via `@eval` at module load. So the code
    is half-duplicated and half-generated — worst of both worlds.
14. **Matching dispatcher duplication in lower.jl.** `_lower_load_via_mux_*`
    and `_lower_store_via_mux_*` generated helpers coexist with
    hand-written `_lower_load_via_mux_4x8!` / `_8x8!` variants that do
    the *exact same thing*. Same for stores.
15. **`memssa.jl` parses LLVM's text output with regex** — a softer §5
    violation. Justified by LLVM.jl not exposing MemorySSA via C API,
    but the textual format is not a stable API either. The file uses
    `^\s*;\s*(\d+)\s*=\s*MemoryDef\(...)` etc., 4 regexes total.
16. **Silent skip in `_module_to_parsed_ir_on_func`**
    (`ir_extract.jl:841`): "pgcstack and other non-dereferenceable ptrs
    are silently skipped." Mild §1 violation — probably fine in
    practice, but deserves a positive enumeration of what's
    acceptable to skip.
17. **`lower_call!` body is duplicated** almost verbatim across the
    `compact=true` / `compact=false` arms (25 lines each, only the
    gate source and destination differ). The `compact` boolean is a
    flag that changes which list of gates to splice — factor the splice.
18. **Global mutable module state in `_known_callees`.** Populated at
    module-load by ~45 `register_callee!` calls in Bennett.jl top-level.
    Not thread-safe. Tests that need callee isolation would have to
    snapshot/restore it.
19. **Export list is a kitchen sink (13 lines, ~90 names).** Exports
    include `soft_popcount32`, `soft_jenkins96`, `HAMT_IMPL`,
    `OkasakiState`, `cf_reroot` — internal primitives of experimental
    memory tiers, promiscuously exposed.
20. **Naming inconsistency: `lower_X!`, `_lower_X!`, `emit_X!`.** Nothing
    distinguishes "private helper" from "lowering entry point" other
    than the author's mood on the day. `lower_add!`, `lower_add_cuccaro!`,
    `lower_add_qcla!` are peer lowerers, but `_lower_load_via_shadow!`
    and `_lower_store_via_mux_4x8!` are private with underscore. Then
    there's `emit_shadow_store!` and `emit_feistel!` for the same role.

---

## CRITICAL

### CRITICAL-1 — `_convert_instruction` is a 649-line god function dispatching on opcode symbol

- File: `src/ir_extract.jl:1086–1734`
- This one function has the same shape repeated for: `add/sub/mul/and/or/xor/shl/lshr/ashr`, `icmp`, `select`, `phi`, `udiv/sdiv/urem/srem`, `sext/zext/trunc`, `br`, `ret`, `extractvalue`, `insertvalue`, `unreachable`, `call` (with an inner 80-line cascade over `llvm.umax/umin/smax/smin/abs/ctpop/ctlz/cttz/bitreverse/bswap/fshl/fshr/fabs/copysign/floor/ceil/trunc/rint/round/minnum/maxnum/minimum/maximum`, then user-registered callees), `GetElementPtr`, `load`, `switch`, `freeze`, `fptosi/fptoui`, `sitofp/uitofp`, `fcmp`, `bitcast`, `fneg`, `store`, `alloca`.
- The `llvm.ctpop/ctlz/cttz/bitreverse/bswap` arms each inline a 15-line IRInst-emission loop, all variations on the same "iterate the bits, emit IRBinOp(:shl)/IRBinOp(:and)/etc." pattern.

```julia
if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul, ...)
    ...
end
if opc == LLVM.API.LLVMICmp ... end
if opc == LLVM.API.LLVMSelect ... end
# ... 17 more top-level `if` arms
if opc == LLVM.API.LLVMCall
    # 80-line cascade over 22 intrinsic name prefixes
    if startswith(cname, "llvm.umax") ...
    if startswith(cname, "llvm.umin") ...
    # ... 20 more
end
```

- **Why bad:** unreadable, untestable, untouchable. Any opcode change is
  buried at arbitrary depth. The cascade is 22 `if startswith(cname, ...)`
  checks — a Dict-of-handlers would cut it to O(1) dispatch plus a
  per-intrinsic function.
- **Fix:** dispatch on opcode via `_OPCODE_HANDLERS::Dict{Opcode, Function}`
  (opcodes are already enumerated in `_LLVM_OPCODE_NAMES`); dispatch
  intrinsics via `_INTRINSIC_HANDLERS::Dict{String, Function}` matched on
  prefix OR exact-name (do the prefix extraction once, before dispatch).
  Each handler is ~10-20 lines and can be unit-tested in isolation.
  `_convert_instruction` becomes ~30 lines of routing.

### CRITICAL-2 — `src/ir_parser.jl` is live dead code; explicit CLAUDE.md §5 violation

- File: `src/ir_parser.jl` (168 lines, regex-only parser)
- `src/Bennett.jl:5` — `include("ir_parser.jl")`
- `src/Bennett.jl:36` — `export … parse_ir …`
- Used only by `test/test_branch.jl`, `test/test_loop.jl`, `test/test_parse.jl`.

CLAUDE.md §5 says: "LLVM IR is not stable. The LLVM.jl C API walker
(`ir_extract.jl`) is the source of truth — not regex parsing."

Yet `ir_parser.jl` contains regex like `RE_BINOP = r"^(add|sub|mul|and|or|xor|shl|lshr|ashr)(?:\s+(?:nsw|nuw|exact))*\s+i(\d+)\s+(.+?),\s*(.+)$"` — which is exactly what CLAUDE.md forbids, including the "nsw|nuw|exact" fragility.

- **Why bad:** the file is structurally misleading. Anyone reading
  `Bennett.jl` top-level sees `include("ir_parser.jl")` and assumes it's
  part of the live pipeline. Any LLVM textual-format drift (which
  happens) silently breaks a live-loaded production dependency even
  though it's used only in tests. Every agent that reads the repo has
  to be told "don't use parse_ir" by a senior.
- **Fix:** either delete `parse_ir` + port `test/test_branch.jl`,
  `test/test_loop.jl`, `test/test_parse.jl` to IR fixtures that use
  `extract_parsed_ir`/`extract_parsed_ir_from_ll`; or move
  `ir_parser.jl` to `test/helpers/` and stop `export`ing `parse_ir`.
  Prior reviews (Torvalds, Julia, Architecture) flagged this — nothing
  has happened.

### CRITICAL-3 — Strategy-symbol ladders in `lower.jl` duplicated between load and store

- File: `src/lower.jl:1706-1727` (load dispatch)
- File: `src/lower.jl:2171-2191` (store dispatch)

Same 8-arm ladder twice:

```julia
if strategy == :shadow
    return _lower_load_via_shadow!(ctx, inst, alloca_dest, info, idx_op)
elseif strategy == :mux_exch_2x8
    return _lower_load_via_mux_2x8!(ctx, inst, alloca_dest, info, idx_op)
elseif strategy == :mux_exch_4x8
    return _lower_load_via_mux_4x8!(ctx, inst, alloca_dest, info, idx_op)
elseif strategy == :mux_exch_8x8 ...
elseif strategy == :mux_exch_2x16 ...
elseif strategy == :mux_exch_4x16 ...
elseif strategy == :mux_exch_2x32 ...
elseif strategy == :shadow_checkpoint ...
else error(...)
end
```

- **Why bad:** (a) CLAUDE.md §12 *explicit* violation — duplicated lowering. If someone adds a `:mux_exch_2x64` strategy, they must remember to add it to two identical ladders. (b) "strategy" is a `Symbol`. If you typo it you get an `error("unsupported ...")` at runtime, not a `MethodError` at compile time. (c) The picker function `_pick_alloca_strategy` (2084–2107) produces the symbol; the ladders consume it — this is a sealed set that wants an `@enum` or parametric singleton.
- **Fix:** replace the symbol with an `abstract type AllocaStrategy` + concrete singletons `ShadowStrategy`, `MuxExch2x8Strategy`, ..., `ShadowCheckpointStrategy`. Dispatch one generic function `lower_via_strategy!(::Strategy, ctx, inst, ...)`. Each handler is a separate short method. One ladder for the picker, zero ladders for the dispatch.

### CRITICAL-4 — Duplicated arithmetic lowering code paths (§12 violation)

Four widely-duplicated `lower_*!` pairs:

- Load via MUX: `_lower_load_via_mux_4x8!` (`lower.jl:1748`) and
  `_lower_load_via_mux_8x8!` (`lower.jl:1773`) are hand-written.
  `_lower_load_via_mux_2x8!`, `_lower_load_via_mux_2x16!`,
  `_lower_load_via_mux_4x16!`, `_lower_load_via_mux_2x32!` are
  generated by `@eval` at `lower.jl:2530-2606`. Every one does:
  `tag = _next_mux_tag!(ctx,"ld", inst.dest); arr_sym=…; idx_sym=…; tmp_sym=…; ctx.vw[arr_sym]=_wires_to_u64!(…); ctx.vw[idx_sym]=_operand_to_u64!(…); call=IRCall(…, soft_mux_load_NxW, …); lower_call!(…); ctx.vw[inst.dest]=ctx.vw[tmp_sym][1:W]`.

  Six bodies for one algorithm. Drop the hand-written 4x8 and 8x8 — the
  `@eval` block already handles the general case.

- Store via MUX: same duplication between hand-written
  `_lower_store_via_mux_4x8!` / `_8x8!` (`lower.jl:2453-2521`) and the
  `@eval`-generated `_lower_store_via_mux_2x8!` / `_2x16!` / `_4x16!`
  / `_2x32!`.

- `softmem.jl` has the same split: hand-written `soft_mux_load_4x8`,
  `soft_mux_store_4x8`, `soft_mux_load_8x8`, `soft_mux_store_8x8`
  (lines 19–100); `@eval`-generated guarded variants for all six shapes
  (lines 275–305). The unguarded load/stores for `2x8`, `2x16`, `4x16`,
  `2x32` are also hand-written, 100 lines of identical shift+mask+ifelse
  ladders.

- **Fix:** generate all shapes with `@eval`; keep the code ~60 lines instead
  of ~300. Cross-check gate-count baselines to ensure byte-identical
  emission.

### CRITICAL-5 — `reversible_compile` option explosion

- File: `src/Bennett.jl:58–95` + `src/Bennett.jl:105–111` +
  `src/Bennett.jl:268–295`
- Axes that the entry point mixes: `optimize::Bool`,
  `max_loop_iterations::Int`, `compact_calls::Bool`, `bit_width::Int`,
  `add::Symbol`, `mul::Symbol`, `strategy::Symbol`.
- The Float64 overload adds nothing new but still has its own copy of
  the kwarg list.
- `lower()` has its own: `use_inplace::Bool`, `use_karatsuba::Bool`,
  `fold_constants::Bool`, plus `add`, `mul`, `compact_calls`,
  `max_loop_iterations`.
- `extract_parsed_ir` has: `optimize`, `preprocess`, `passes`,
  `use_memory_ssa`.
- **Why bad:** 10+ boolean-ish flags passed alongside each other are a
  missing struct. A user calling `reversible_compile(f, Int8;
  optimize=true, compact_calls=false, bit_width=0, add=:auto,
  mul=:auto, strategy=:auto)` has no way to know which options are
  orthogonal and which interact. `strategy=:tabulate` with
  `bit_width=17` is a runtime error, not a compile error.
- **Fix:** `struct CompileOptions` with defaults. Reduce signatures to
  `reversible_compile(f, arg_types; opts::CompileOptions=…)`. Group:
  `IRExtraction` (optimize, preprocess, passes, use_memory_ssa);
  `Lowering` (max_loop_iterations, compact_calls, add, mul, bit_width,
  use_inplace, use_karatsuba, fold_constants); `Strategy` (tabulate vs
  expression).

---

## HIGH

### HIGH-1 — `IROperand` is primitive-obsession for what should be a tagged union

- File: `src/ir_types.jl:1-10`

```julia
struct IROperand
    kind::Symbol       # :ssa or :const
    name::Symbol       # SSA name (if :ssa)
    value::Int         # constant value (if :const)
end

ssa(name::Symbol)    = IROperand(:ssa, name, 0)
iconst(value::Int)   = IROperand(:const, Symbol(""), value)
```

45 sites across the codebase check `.kind == :ssa` or `.kind == :const`
and then read the "live" field. A typo (`:Ssa`) is a runtime bug.
Constant-operand consumers must know the `name` field is a meaningless
`Symbol("")` and not read it.

- **Fix:**
  ```julia
  abstract type IROperand end
  struct SSAVar <: IROperand; name::Symbol; end
  struct IntConst <: IROperand; value::Int; end
  ```
  Replace `op.kind == :ssa` with `op isa SSAVar` (compile-time
  MethodError on typo). Replace `_ssa_operands` cascades with
  multi-dispatch. `lower.jl:195-261` would collapse to ~20 lines.

### HIGH-2 — `LoweringCtx` has 18 fields, 4 constructors, and 3 `::Any` fields

- File: `src/lower.jl:49-119`

```julia
struct LoweringCtx
    gates::Vector{ReversibleGate}
    wa::WireAllocator
    vw::Dict{Symbol,Vector{Int}}
    preds::Any    # Dict{Symbol,Vector{Symbol}} — typed Any to accept any dict shape from caller
    branch_info::Any
    block_order::Any
    block_pred::Dict{Symbol,Vector{Int}}
    ssa_liveness::Dict{Symbol,Int}
    inst_counter::Ref{Int}
    use_karatsuba::Bool
    compact_calls::Bool
    alloca_info::Dict{Symbol, Tuple{Int,Int}}
    ptr_provenance::Dict{Symbol, Vector{PtrOrigin}}
    mux_counter::Ref{Int}
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}
    add::Symbol
    mul::Symbol
    entry_label::Symbol
end
```

- The `# typed Any to accept any dict shape from caller` comment is an
  admission. If callers pass different dict shapes, you have a type
  problem, not an `Any` problem.
- Four constructors (`lower.jl:85-119`) each with subtly different
  defaults. Comments tag them `# Backward-compatible`, `# 12-arg`,
  `# 13-arg`. Nobody has ever dropped an old one.
- **Fix:** Pick the real type (`Dict{Symbol,Vector{Symbol}}` etc.) —
  it is actually always the same. Consolidate to one constructor with
  all kwarg defaults. Delete the legacy constructors. Any call site
  that breaks is fixable in ~10 minutes.

### HIGH-3 — Five `*_bennett` variants are siblings with no unified dispatch

- `src/bennett_transform.jl:23` — `bennett(lr)` (baseline)
- `src/eager.jl:56` — `eager_bennett(lr)`
- `src/value_eager.jl:29` — `value_eager_bennett(lr)`
- `src/pebbling.jl:112` — `pebbled_bennett(lr; max_pebbles)`
- `src/pebbled_groups.jl:273` — `pebbled_group_bennett(lr; max_pebbles)`
- `src/pebbled_groups.jl:351` — `checkpoint_bennett(lr)`

All six are exported. All share the same "forward → copy-out → reverse"
scaffolding with minor tweaks. All call a common `_build_circuit`.
Three of them fall back to `bennett(lr)` on edge cases (`if
isempty(groups) return bennett(lr) end`).

- **Why bad:** no single Strategy type means no systematic way to test
  orthogonality ("does value_eager commute with pebbled_group?"). Each
  is an orphan function. The user has to know which to call when.
- **Fix:** `abstract type BennettStrategy end` with concrete
  singletons; one generic `bennett(lr; strategy=DefaultStrategy())`
  method dispatching internally. Keep the specialised names as
  convenience shorthands. Centralise the Phase 1/2/3 scaffold.

### HIGH-4 — `_convert_vector_instruction` is a parallel 237-line god function mirroring `_convert_instruction`

- File: `src/ir_extract.jl:2063-2300`

This is `_convert_instruction`'s younger brother — same shape, same
opcode cascade, same intrinsic tail, but for `<N x iM>` vector ops. It
has arms for `InsertElement`, `ShuffleVector`, `ExtractElement`,
vector arithmetic, vector ICmp, vector select, vector cast, and more.

- **Why bad:** the scalar and vector paths share 80% of the logic but
  diverge at every arm. Any new opcode must be added in both places.
  This is a §12 violation waiting to bite ("lowered `:and` on scalar
  but not vector").
- **Fix:** unify by defining a "lane count" trait: scalars are 1-lane
  vectors. Emit N IRInsts once. Or, more conservatively, share
  per-opcode helpers so both dispatchers call a common `_binop_ir(dest,
  opc, operands, width)`.

### HIGH-5 — `_collect_sret_writes` is 173 lines of nested special-case soup

- File: `src/ir_extract.jl:467–640`

Single function that: (a) detects llvm.memcpy into sret and errors, (b)
chases constant-offset GEPs off the sret pointer maintaining a
`gep_byte` map, (c) handles scalar stores to sret, (d) handles vector
stores to sret with a "pending" mechanism deferred to pass 2. Four
distinct responsibilities, three shared maps, one accumulator set.
Paired with `_resolve_pending_vec_for_val!`, `_assert_no_pending_vec_stores!`,
`_synthesize_sret_chain`, `_find_entry_function` — all for sret.

- **Why bad:** 173-line body with 6 nested `if`/`continue` tiers, three
  `_ir_error` raises in the vector case alone, all sharing mutable
  accumulators by capture. Splitting by responsibility (GEP-chase /
  scalar-store / vector-store / final-validation) would let each piece
  be ~30 lines.

### HIGH-6 — Exported internals and experimental namespaces

- File: `src/Bennett.jl:36–48` (13 export lines)

Exports include:
- `soft_popcount32` — an implementation detail of the HAMT branch's
  bit-counting layer.
- `soft_jenkins96`, `soft_jenkins_int8`, `soft_feistel32`,
  `soft_feistel_int8` — experimental hashcons primitives.
- `HAMT_IMPL`, `OKASAKI_IMPL`, `LINEAR_SCAN_IMPL`, `CF_IMPL` —
  per-impl module-level constants for the persistent-map
  benchmarking harness. These should be in a sub-module.
- `OkasakiState`, `cf_reroot` — type name + cf-specific helper.
- `checkpoint_bennett`, `pebbled_group_bennett` — research-quality
  alternatives.

- **Why bad:** public surface area is larger than useful. Anyone doing
  `using Bennett` gets the whole zoo. Tests become coupled to
  non-contract exports.
- **Fix:** move persistent impls into `Bennett.Persistent` sub-module.
  Experimental bennett variants into `Bennett.Experimental`. Main
  `Bennett` exports `reversible_compile`, `simulate`,
  `ReversibleCircuit`, `ControlledCircuit`, `gate_count`,
  `verify_reversibility`, maybe `bennett`. That's it.

### HIGH-7 — Nine `try; ... catch; nothing end` / `catch; "" end` in `ir_extract.jl`

- Lines: `ir_extract.jl:335, 338, 343, 491, 957, 1218, 1794, 1980, 1990`

Most-egregious examples:

```julia
cname = try LLVM.name(ops[n_ops]) catch; "" end
```

- `_ir_error_msg` (`ir_extract.jl:332-345`) has FOUR such
  `try/catch/default-string` blocks — excusable for an error-reporter
  that must never itself throw, but the defensive scope creeps beyond
  error reporting.
- `_safe_operands` (`ir_extract.jl:1786-1799`) quietly swallows
  `LLVM.Value` wrapping failures — documented as a cc0.3 GlobalAlias
  workaround, but the `catch` is unscoped (`catch _; nothing`).
- **Why bad:** swallowing LLVM iteration exceptions *anywhere* is a
  §1 violation (fail-loud). It's justified for `_safe_operands` and
  `_any_vector_operand`, but the `_extract_const_globals`
  `try LLVM.initializer(g) catch; nothing end` (`ir_extract.jl:955-959`)
  is broader than the GlobalAlias workaround — any future `initializer`
  regression goes undetected.
- **Fix:** narrow the catch to `catch e; e isa LLVM.JuliaException ||
  rethrow() ; … end`, or enumerate the expected exception type.

### HIGH-8 — `lower_call!` has 2 near-identical 25-line code paths behind `compact::Bool`

- File: `src/lower.jl:1928-1990`
- Lines 1938-1964 (compact=true) and 1965-1988 (compact=false) diverge
  only in: whether they call `bennett(callee_lr)` before splicing
  gates; whether gate source is `callee_circuit.gates` vs
  `callee_lr.gates`; and the output-wire list. The CNOT-copy loop for
  connecting caller args → callee inputs is written twice, character-
  identical.
- **Fix:** factor out `_splice_callee_gates!(gates, wa, vw, inst,
  callee_parsed, callee_lr, gate_src::Vector{…}, input_wires::…,
  output_wires::…)`. The `compact` kwarg becomes `compact ?
  bennett_spliced(...) : forward_only_spliced(...)`.

### HIGH-9 — Triple-redundant integer division lowering

- Same operation reachable by three paths:
  1. User code calls `a ÷ b` → LLVM `udiv`/`sdiv` → `IRBinOp` →
     `lower_binop!` → `lower_divrem!` (`lower.jl:1422`) → widens to 64
     bits, calls `soft_udiv`/`soft_urem` via `IRCall` → `lower_call!`
     re-extracts the callee's IR → schoolbook restoring division.
  2. User code calls `soft_udiv(...)` directly → callee registry picks
     it up → gate-level inline.
  3. If a callee is named `soft_udiv` but **not** registered, LLVM's
     `call` instruction gets `return nothing` from `_convert_instruction`
     (`ir_extract.jl:1508`) — silent skip.
- **Why bad:** three code paths for one semantic. Path 1 is the
  canonical path; path 2 exists because path 1 uses it internally;
  path 3 exists by accident. §12 violation exactly as CLAUDE.md
  defines it.
- **Fix:** canonicalise. Decide whether division is always a callee
  (then `lower_binop!` shouldn't have a udiv/sdiv/urem/srem arm at all
  — let ir_extract emit `IRCall` directly for these opcodes) or always
  inline (drop `soft_udiv` / `soft_urem`). Current setup is the worst
  of both.

---

## MEDIUM

### MEDIUM-1 — `resolve_phi_muxes!` is a recursive closure with an ambiguous-branch special case buried in it

- File: `src/lower.jl:1010-1060`

Heavy recursive function that repeatedly re-partitions `incoming`
against each known branch. The diamond-CFG handling (lines 1044-1053)
is done by calling the function three times recursively (on the
`ambig`, `true_set ∪ ambig`, `false_set ∪ ambig`). Per CLAUDE.md the
phi resolver is the most bug-prone part of the compiler. This form
makes correctness hard to reason about.

- **Fix:** separate "find partitioning branch" and "apply MUX at this
  branch" into two functions; return an explicit datatype
  (`PartitionResult`) rather than depending on implicit recursion
  structure.

### MEDIUM-2 — `ParsedIR::memssa::Any`

- File: `src/ir_types.jl:180`
- The comment is honest: "Forward-declared as Any to avoid circular
  type dependency with src/memssa.jl." That's the symptom of the
  include-order in `src/Bennett.jl` being IR → MemSSA, not the
  reverse.
- **Fix:** move `MemSSAInfo` definition to `ir_types.jl` (or a new
  `memssa_types.jl`), have `memssa.jl` include it.

### MEDIUM-3 — `_narrow_inst` is a 12-method cascade that hardcodes every IR type

- File: `src/Bennett.jl:139-160`
- Every new `IRInst` subtype requires a new `_narrow_inst` method, with
  no way to enforce that. There's also a fall-through default at line
  160: `_narrow_inst(inst::IRInst, W::Int) = inst` — silently passes
  through unknown types, defeating CLAUDE.md §1.
- **Fix:** make the fallback error; enumerate supported types, make
  unsupported types a hard-error caught at narrow time. Or, move
  narrowing to a `width(inst)` + `with_width(inst, W)` pattern on each
  concrete type (method-dispatch replaces the cascade).

### MEDIUM-4 — `lower_block_insts!` has 15 keyword arguments

- File: `src/lower.jl:568-587`

Seven Dict defaults, two Bool flags, two Symbols, one Ref, one Vector,
a Symbol sentinel for "entry block." All have default values, so they
all must be passed through at every call site.

- **Why bad:** missing struct. The caller at `lower.jl:405` has to name
  each one explicitly.
- **Fix:** the function is the body of `lower()`; most of these are
  derivable from a single `LoweringState`. Pass that struct in.

### MEDIUM-5 — `WireAllocator.free_list` is hand-managed sorted-descending vector

- File: `src/wire_allocator.jl:25-28`

`searchsortedlast(wa.free_list, w; rev=true) + 1; insert!(wa.free_list, idx, w)` — O(N) insert for every free. If wires are freed eagerly
during a compile with thousands of wires, this is a quadratic spot. No
`DataStructures.jl` here; that would be fine, but `Heap`-backed
allocator is a cleaner fit.

- **Why bad:** not justified in the docstring, no test for
  large-allocation scaling. Potential hot-path issue.

### MEDIUM-6 — Naming drift: `emit_`, `lower_`, `_lower_`, `lower_X_Y!`

- `emit_shadow_store!`, `emit_shadow_load!`, `emit_feistel!`,
  `emit_shadow_store_guarded!`, `emit_fast_copy!` — all in modules
  that also define `lower_*!` functions.
- `lower_add!`, `lower_add_cuccaro!`, `lower_add_qcla!` live at
  top-level as peers.
- `_lower_store_via_shadow!`, `_lower_store_via_mux_4x8!`,
  `_lower_store_via_shadow_checkpoint!` live alongside them with the
  underscore prefix.
- There's no stated convention for `emit_` vs `lower_`. Reader-hostile.
- **Fix:** pick one. Roughly: `emit_*` = primitive gate emission (takes
  wires); `lower_*` = IR instruction dispatcher (takes IRInst and
  LoweringCtx); `_lower_*` = private helper.

### MEDIUM-7 — `_pick_alloca_strategy` encodes shape-table by `if`/`elseif` not data

- File: `src/lower.jl:2084-2107`

```julia
if elem_w == 8
    n == 2 && return :mux_exch_2x8
    n == 4 && return :mux_exch_4x8
    n == 8 && return :mux_exch_8x8
elseif elem_w == 16
    n == 2 && return :mux_exch_2x16
    n == 4 && return :mux_exch_4x16
elseif elem_w == 32
    n == 2 && return :mux_exch_2x32
end
```

- **Why bad:** the set `{(8,2),(8,4),(8,8),(16,2),(16,4),(32,2)}` is
  data. The `@eval` loop at `lower.jl:2530` generates a handler for
  exactly these shapes. Duplicating them as `if/elseif` means "add
  a new shape" is two places.
- **Fix:** one `const MUX_SHAPES = [(8,2),(8,4),...]`. The `@eval`
  loop generates handlers; the picker looks up the shape in the same
  set.

### MEDIUM-8 — `SoftFloat` is a user-facing wrapper type mixed into `Bennett.jl` main module

- File: `src/Bennett.jl:220-249`

`struct SoftFloat` with ~25 inlined operator overloads directly in the
package entry file. It's not internal — it's part of how users reach
Float64 compile. But it's not exported either, so users can't actually
use it directly.

- **Why bad:** package entry-file bloat. User-facing wrapper type
  without export (so users must duplicate it to extend).
- **Fix:** move to `src/softfloat/dispatch.jl`; export it. Users who
  want to extend Float64 semantics can import and add methods.

### MEDIUM-9 — `lower()` is 160 lines; several distinct phases crammed in

- File: `src/lower.jl:307-467`
- Phases: kwarg validation, LoweringCtx construction, per-arg wire
  allocation, back-edge detection, topological sort, per-block
  predicate computation, per-block instruction lowering or loop
  unrolling, terminator handling, return-value synthesis.
- **Fix:** break into `_lower_init(parsed)`, `_lower_cfg(blocks)`,
  `_lower_blocks!(state, order, ...)`, `_lower_returns!(state, ret_values)`.

### MEDIUM-10 — `Base.getproperty(::ParsedIR, ...)` override for backward compat

- File: `src/ir_types.jl:212-218`
- Overrides `Base.getproperty` to synthesize a `:instructions` field on
  an immutable struct. This is a virtual field for an old API
  (`parsed.instructions`), now delegated to `getfield(p, :_instructions_cache)`.
  Overloading Base.getproperty silently defeats introspection tools
  (`fieldnames` shows one thing, `propertynames` another).
- **Fix:** either drop the flattened-instructions convenience
  (`for b in parsed.blocks for i in b.instructions …`) or compute it
  lazily as a pure function `flat_instructions(parsed)`.

---

## LOW

### LOW-1 — Magic numbers in `softmem.jl` and `softfloat/*`

- `softmem.jl:26` etc. — `UInt64(0xff)`, `UInt64(0xffff)`,
  `UInt64(0xffffffff)` scattered; no `const BYTE_MASK = 0xff`, etc.
- `ir_extract.jl:1437`, `:1443` — `w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)`
  and `sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))` — the
  magic "if w==64 we'd overflow so use typemax/typemin" pattern is
  duplicated between `llvm.fabs` and `llvm.copysign` and `fneg`.
  Candidate helper `_width_mask(w)`, `_sign_bit(w)`.
- Width tests: `1 <= elem_width <= 64` (`ir_extract.jl:967`), `packed_bits = N * W` with assertion `N·W ≤ 64` in multiple places —
  `const MAX_PACKED_BITS = 64` would be clearer.

### LOW-2 — `_auto_name` generates `Symbol("__v$(counter[])")` by string interpolation

- File: `src/ir_extract.jl:249-252`
- `Symbol("__v42")` every call is a fresh Symbol lookup + interning.
  Hot path; probably fine, but `Symbol(string("__v", counter[]))` is
  identical and sometimes faster. Also: the `__v` prefix has no
  structured guard — any user with an SSA name `__v7` collides.

### LOW-3 — `_reset_names!() end` (no-op for backward compat)

- File: `src/ir_extract.jl:255`
- An empty function kept only "for backward compatibility" (per comment
  line 254). Dead code. Delete; fix any caller.

### LOW-4 — `_narrow_inst(inst::IRInst, W::Int) = inst # fallback: pass through`

- File: `src/Bennett.jl:160`
- The fallback silently no-ops any unseen IRInst subtype. Violates §1.
  Should `error("_narrow_inst: unhandled $(typeof(inst))")`.

### LOW-5 — `WORKLOG.md` is 414939 bytes

- File: `WORKLOG.md`
- Institutional memory is fine, but a ~400KB plain-text log can't
  realistically be read cover-to-cover. Consider a rolling archive
  every M-release and a concise latest-N-sessions view.

### LOW-6 — `_gate_target`, `_gate_controls` defined at the bottom of `dep_dag.jl`

- File: `src/dep_dag.jl:90-96`
- They are used from `eager.jl`, `pebbling.jl`, `diagnostics.jl` —
  cross-file dependency through a bare include-ordering. Should live
  in `gates.jl` next to the gate types.

### LOW-7 — `SoftFloat(x::Int) = SoftFloat(reinterpret(UInt64, Float64(x)))`

- File: `src/Bennett.jl:225`
- Takes any `Int` (not just Int64). On a 32-bit host `reinterpret(UInt64, Float64(x))` is fine but the intent is unclear. Use `Int64` explicitly.

### LOW-8 — `lower_binop!` has `else error("Unknown binop: $(inst.op)")` as the only fail-loud

- File: `src/lower.jl:1149`
- Good instinct, but buried at the bottom of a 54-line function.
  Extracting the dispatch via method-dispatch (e.g. `lower_binop!(..., ::Val{:add}, ...)`) would let Julia's `MethodError` be the failure and let an invariant check live up front.

### LOW-9 — `_ir_error_msg` uses nested `try/catch/default-string`

- File: `src/ir_extract.jl:333-344`
- Four separate try/catch wrappers for what should be one
  error-reporter. Factor into `_safe(x, default="<unknown>")`.

### LOW-10 — `memssa.jl` parses LLVM text with regex

- File: `src/memssa.jl:44-47`, `src/memssa.jl:57-`
- Four regex constants over `print<memoryssa>` stderr output. The
  decision to go textual is defensible (LLVM.jl doesn't expose a C
  API for MemorySSA queries), but the choice should be called out
  in CLAUDE.md's §5 exception list. As-written, it's a soft §5
  violation without acknowledgement.

### LOW-11 — `lower_phi!` docstring describes ptr-phi as first-class

- File: `src/lower.jl:928-968`
- The function has two wholly separate bodies (width=0 ptr-phi, width>0
  value-phi). The docstring would make a reader think width=0 is a
  minor variant. It's 50% of the body.
- **Fix:** split into `lower_phi_value!` and `lower_phi_ptr!`;
  dispatch on `inst.width == 0`.

### LOW-12 — `pebbled_group_bennett` has four separate fallbacks to `bennett(lr)`

- File: `src/pebbled_groups.jl:275, 286, 291, 296`

```julia
if isempty(groups) return bennett(lr) end
if has_inplace return bennett(lr) end
if all(g -> g.wire_start > 0, groups) return checkpoint_bennett(lr) end
if max_pebbles <= 0 || max_pebbles >= n_groups return bennett(lr) end
```

- Not quite a smell on its own (graceful degradation is fine) but the
  stacked fallbacks mean "the function pebbles only in the narrow case
  where all prerequisites are met." A single up-front precondition
  check with an informative message (or a dedicated
  `is_pebble_applicable(lr, max_pebbles)` predicate) would be clearer.

### LOW-13 — `print_circuit` / `Base.show` in `diagnostics.jl`

- File: `src/diagnostics.jl:26-37`
- `Base.show(io::IO, ::MIME"text/plain", c::ReversibleCircuit) = print_circuit(io, c)` — standard type piracy avoidance
  (`ReversibleCircuit` is ours). Fine; noted for completeness.
  Not a smell.

### LOW-14 — `const _T_LAYERS_PER_TOFFOLI = Dict{Symbol,Int}(...)` instead of NamedTuple

- File: `src/diagnostics.jl:67`
- Two entries. NamedTuple `(ammr=1, nc_7t=3)` gives compile-time key
  checking; Dict gives runtime-only. `t_depth(:ammer)` (typo) errors
  at runtime. Dict would be justified if the key set were extensible
  at user level; it isn't.

### LOW-15 — `collect(copy_start:copy_start + n_out - 1)` pattern

- Files: `src/bennett_transform.jl:34`, `src/eager.jl:93`,
  `src/value_eager.jl:89`, `src/pebbling.jl:127` (approx)
- `copy_wires = collect(copy_start:copy_start + n_out - 1)`
  allocates an explicit Vector from a `UnitRange`. Downstream uses are
  `for (j, w) in enumerate(copy_wires)` and `copy_wires[i]` — both
  work on `UnitRange` directly. Unnecessary allocation in a
  hot-adjacent function called once per compile.

### LOW-16 — No consistent convention for `::Symbol=:auto` default sentinels

- `add::Symbol=:auto`, `mul::Symbol=:auto`, `strategy::Symbol=:auto`
  scattered. Not validated at a single entry point — `lower()` checks
  its own `add`/`mul`; `reversible_compile` checks `strategy`; no
  central registry of valid values.
- **Fix:** `@enum AddStrategy AUTO RIPPLE CUCCARO QCLA` with `tryparse`
  from Symbol at the API boundary.

---

## NIT

- `src/Bennett.jl:169-181` — `register_callee!(soft_floor)` etc. 44
  consecutive registrations. Could be `for fn in (:soft_floor, …);
  register_callee!(@eval($fn)); end`. Taste.
- `src/ir_extract.jl:1890` — `inner_val isa LLVM.ConstantInt || return nothing` — silent skip on unexpected inner-cast kind.
- `src/Bennett.jl:46` — `export ReversibleCircuit, ControlledCircuit, controlled` — the export line is shorter than most. Not a problem, but the grouping of exports (13 export lines over 10 files of exportables) has no visible rationale.
- `src/lower.jl:473` (`_fold_constants`) is a 94-line forward-dataflow pass guarded by `fold_constants::Bool=false` and never called by default. Probably dead — worth confirming and, if so, deleting.
- `src/ir_extract.jl:215, 241` — `return nothing` at top of `_reset_names!` / `_lookup_callee`. `_lookup_callee` returning nothing on miss is fine (caller handles it); `_reset_names!` is the no-op of LOW-3.

---

## Categorical roll-up (which smells were observed where)

| Category | Observed? | Notable sites |
|---|---|---|
| 1. God functions (>150 lines / >8 nesting) | **YES, multiple** | `_convert_instruction` (649), `_convert_vector_instruction` (237), `_collect_sret_writes` (173), `_module_to_parsed_ir_on_func` (159), `lower` (160), `_fold_constants` (94), `lower_loop!` (91) |
| 2. God modules | **YES** | `lower.jl` (2662), `ir_extract.jl` (2394) |
| 3. Copy-pasted code | **YES, extensive** | `softmem.jl` load/store pairs, `lower.jl` mux-exch dispatchers, `lower_call!` compact/non-compact arms, `lower_add!`/`lower_sub!` ripple skeletons |
| 4. Flag-driven branching | **YES** | `_pick_alloca_strategy` ladder + ~8 `strategy == :X` elseif ladders; `lower_binop!` has 3 nested layers of binop symbol dispatch |
| 5. Boolean blindness | **YES** | `reversible_compile` (6 Bool kwargs), `lower` (4 Bool kwargs), `extract_parsed_ir` (3 Bool kwargs), `lower_call!` (`compact::Bool`) |
| 6. Primitive obsession | **YES** | `IROperand` (§HIGH-1), width `Int` with `:i1 sentinel` width==0, width==1 semantics everywhere |
| 7. Stringly-typed APIs | **YES, pervasive** | 45 sites comparing `op.kind`, 14 sites comparing `inst.op`, strategies-as-Symbol throughout |
| 8. Mutable global state | **YES** | `_known_callees` (ir_extract.jl:220) populated at module load |
| 9. Broad catch / empty body | **YES** | 9 `try; ...; catch; nothing end` / `catch; ""` in ir_extract.jl |
| 10. Silent fallbacks | **YES, minor** | `_narrow_inst` pass-through fallback; `pgcstack ptr silently skipped`; GEP-unknown-base returning `nothing`; alloca-non-integer returning nothing |
| 11. Assertion-free hot paths | **Partial** | Most hot paths do have asserts, but `_module_to_parsed_ir_on_func` has several `get(..., nothing)` silently absorbed |
| 12. Comment code smells (TODO/FIXME) | **No** | Zero TODO/FIXME/HACK/XXX markers anywhere in src/. Impressive — but the compensating pattern is long docstrings that sometimes contradict code |
| 13. `@generated`/`@eval`/macro overuse | **Moderate** | Two `@eval` loops (`softmem.jl:283`, `lower.jl:2540`) for parametric MUX generation. Justifiable, but partially-generated / partially-hand-written makes the pattern inconsistent |
| 14. Type piracy | **No** | `Base.show` on owned type (OK), `Base.+` on `SoftFloat` (owned type, OK). No piracy |
| 15. Leaky iterator / memory patterns | **Minor** | `collect(UnitRange)` in Bennett transforms (LOW-15), otherwise clean |
| 16. Incorrect abstractions | **YES** | `IROperand` (HIGH-1), five `*_bennett` variants without Strategy type (HIGH-3), `LoweringCtx` (HIGH-2) |
| 17. Magic numbers | **Minor** | `UInt64(0xff)`, `w==64 ? typemax : ...` duplicated (LOW-1) |
| 18. Inconsistent naming | **YES** | `emit_` vs `lower_` vs `_lower_` (MEDIUM-6) |
| 19. Exported internals | **YES** | ~30 exports that should be internal / sub-module (HIGH-6) |
| 20. CLAUDE.md §5 (regex vs C API) | **YES** | `ir_parser.jl` (CRITICAL-2), `memssa.jl` (softer, LOW-10) |
| 21. Docstring / code mismatch | **Minor** | `lower_phi!` docstring (LOW-11), `_narrow_inst` silent pass-through contradicts "fail-loud" stance |
| 22. Long parameter lists | **YES** | `lower_block_insts!` (15 kwargs, MEDIUM-4) |
| 23. Nested lambdas / closures | **Minor** | `find_back_edges` has inner `dfs` closure (OK); `_fold_constants` has data-flow state captured (OK). No egregious cases |
| 24. `Any` leakage | **YES** | `LoweringCtx::preds/branch_info/block_order`, `ParsedIR::memssa` (HIGH-2, MEDIUM-2) |
| 25. Duplicated lowering (§12 violation) | **YES** | MUX load/store dispatchers (CRITICAL-4), divrem triple-path (HIGH-9), CRITICAL-3 load/store ladders |

---

## What I'd fix first (ordered by impact/effort ratio)

1. **Delete `ir_parser.jl` or move it to `test/helpers/`** (CRITICAL-2).
   One-day fix. Aligns with CLAUDE.md §5. Reduces module surface.
2. **Tighten `IROperand` to a tagged union** (HIGH-1). Two-day fix.
   Kills 45 call sites of primitive-Symbol dispatch; makes typos fail at
   compile.
3. **Collapse the MUX-EXCH hand-written/generated split** (CRITICAL-4).
   Keep only the `@eval` path; verify gate counts unchanged. Cuts
   ~300 lines from `lower.jl` and `softmem.jl`.
4. **Factor `_convert_instruction`** (CRITICAL-1). Even a modest split
   (one function per opcode group, plus an intrinsic-dispatch dict)
   cuts it from 649 to ~80.
5. **Unify the `*_bennett` family under one Strategy type** (HIGH-3).
   Reduces export surface; makes orthogonality testable.
6. **Move `memssa` type into `ir_types.jl`** (MEDIUM-2). Removes the
   last `::Any` field from `ParsedIR`.

None of these are architecturally risky. All are achievable with the
existing test suite as a regression net.

