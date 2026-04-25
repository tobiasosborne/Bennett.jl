## Session log — 2026-04-21 — Bennett-cc0.4 closed (ConstantExpr icmp folding)

User plan: "ok get to work. red green tdd, read ground trutj always before
coding" — third cc0.x bead in the ir_extract chain. Small, isolated fix;
3+1 protocol per CLAUDE.md §2. Full suite GREEN post-fix; all baselines
byte-identical.

### RED test + ground truth

- `test/test_cc04_repro.jl` — minimal repro using an in-test `mutable
  struct CC04Node{T}` with `Union{CC04Node{T},Nothing}`, a 3-node linked
  list, two isnothing checks in the predicate. Exhaustive i8 (256
  inputs) + `verify_reversibility(c; n_tests=3)`. Pre-fix: "Unknown
  operand ref for: i1 icmp eq (ptr @..., ptr @...)". Post-fix: GREEN.
- IR extracted via `InteractiveUtils.code_llvm(... optimize=true)` →
  the whole function reduces to `select i1 icmp eq (ptr @TJ3Node,
  ptr @Nothing), i8 -1, i8 %2`. Condition is a `LLVM.ConstantExpr`
  (value kind `LLVMConstantExprValueKind`), opcode `LLVMICmp`, predicate
  `LLVMIntEQ`, two operands both `LLVMGlobalAliasValueKind`.
- **Critical empirical detail discovered mid-implementation**: the
  alias's aliasee is NOT a GlobalVariable — it is a `ConstantExpr`
  of shape `inttoptr (i64 <absolute_addr> to ptr)`. Julia's JIT bakes
  literal runtime addresses of type descriptors as inttoptr-of-const
  under GlobalAliases. Any design that only traces aliases to named
  globals (first draft of `_ptr_addresses_equal` per both proposers)
  returns "undecidable" and fails loud on exactly this pattern. The
  probe that surfaced this: read the aliasee ref, call
  `LLVM.Value(aliasee)`, inspect the string.

### 3+1 protocol

- `docs/design/cc04_proposer_A.md` (1,160 lines, general-purpose subagent)
- `docs/design/cc04_proposer_B.md` (927 lines, general-purpose subagent)
- `docs/design/cc04_consensus.md` (orchestrator synthesis + tie-breakers)

Both converged on: one `elseif val isa LLVM.ConstantExpr` branch in
`_operand` dispatching to a file-private helper. MVP scope: icmp eq/ne on
pointer operands, fold to iconst(0/1). Everything else fails loud with a
cc0.4 breadcrumb.

Tie-breakers picked:
- Helper name `_fold_constexpr_operand` (B, more descriptive).
- Trivial-ptrcast peeling included (A; real IR wraps globals).
- Separate `_ptr_identity` / `_ptr_addresses_equal` helpers (A-style).
- cc0.6 hint on `ptrtoint`/`inttoptr` operand opcodes (B).

### Implementation — src/ir_extract.jl (+123 lines, one new branch)

Added ~123 lines in a new cc0.4 helpers block between the cc0.3 helpers
and the cc0.7 helpers block. Zero other-file changes.

- `_CONSTEXPR_OPCODE_NAMES` — Dict for error-message opcode naming.
- `_constexpr_opcode_name(opc)` — wrapper with `sprint(show, opc)` fallback.
- `_ptr_identity(ref) -> Union{Tuple{Symbol, UInt64}, Tuple{Symbol,
  _LLVMRef}, Nothing}` — canonical identity:
  - `(:named, r)` — Function / GlobalVariable / GlobalIFunc
  - `(:null, 0)` — ConstantPointerNull
  - `(:addr, K::UInt64)` — `inttoptr (i64 K to ptr)` (the Julia-JIT
    typetag pattern)
  - `nothing` — undecidable
  Walks through GlobalAlias (via `LLVMAliasGetAliasee`), peels
  bitcast/addrspacecast wrappers, recognises `inttoptr(ConstantInt)`.
  Depth cap 16.
- `_ptr_addresses_equal(a, b)` — compares identities; returns `nothing`
  on undecidable (caller fails loud).
- `_fold_constexpr_operand(ce, names)` — entry point.

`_operand` gains exactly one `elseif val isa LLVM.ConstantExpr` branch.

### Gate-count deltas (cc0.4 target: TJ3)

| Build | Gates | Toffoli | Note |
|---|---:|---:|---|
| TJ3 (NEW BASELINE) | **180** | **44** | `x + Int8(2)` after ptr-fold + dead-branch elimination |

The function reduces statically to `select false, -1, (x+2)` → `x+2`. The
180 gates come from the select circuit's false-arm wiring for `-1` plus
the add.

### Regression check — all baselines byte-identical

Full `Pkg.test()` GREEN. Spot-checks vs 2026-04-20 WORKLOG numbers:

| Primitive | Pre-fix | Post-fix | Δ |
|---|---:|---:|---|
| soft_fptrunc | 36,474 | 36,474 | 0 |
| popcount32 standalone | 2,782 | 2,782 | 0 |
| HAMT demo (max_n=8) | 96,788 | 96,788 | 0 |
| CF demo (max_n=4) | 11,078 | 11,078 | 0 |
| CF+Feistel | 65,198 | 65,198 | 0 |
| i8/i16/i32/i64 two-arg add | 98/202/410/826 | 98/202/410/826 | 0 |

Zero-regression guarantee by construction: the new `elseif` is only
entered on `LLVM.ConstantExpr` inputs — a type disjoint from
`ConstantInt` / `ConstantAggregateZero` / named SSA. Functions with no
ConstantExpr operands take byte-identical paths.

### Tests changed

- `test/test_cc04_repro.jl` — new RED→GREEN gate (exhaustive i8).
- `test/test_t5_corpus_julia.jl` TJ3 — flipped from `@test_throws
  ErrorException` to exhaustive i8 GREEN (256 inputs + verify).
- `test/runtests.jl` — include `test_cc04_repro.jl` after cc0.7.

### Gotchas (new, worth recording)

1. **Julia JIT baked-address aliasees.** Given `@alias = alias ptr
   <inttoptr (i64 K to ptr)>`, `LLVMAliasGetAliasee` returns a
   `ConstantExpr<inttoptr>` — NOT a named global. Any pointer-identity
   logic that only recognises Function/GlobalVariable/IFunc/null as
   terminals will fail loud on exactly the TJ3 pattern. Both cc0.4
   proposer drafts missed this; surfaced only by running the test and
   re-probing the aliasee.

2. **`_operand` ordering matters.** The new `ConstantExpr` branch must
   appear BEFORE the `haskey(names, r)` fallback: a ConstantExpr is not
   in `names` and would take the existing error path. Put the new
   `elseif` between `ConstantAggregateZero` and the final `else`.

3. **Empirical probe beats proposer assumptions.** Both cc0.4 proposers
   correctly identified `_resolve_aliasee` as the key helper; both
   independently assumed aliasees terminated at named globals. The
   actual Julia-JIT shape was only visible by running a probe that
   wrapped `LLVM.Value(aliasee)` and printed the result. CLAUDE.md §10
   (skepticism) and §5 (LLVM IR not stable) both applied.

4. **ConstantExpr identity recognition is semantic, not syntactic.** A
   canonical-identity tagged union (`:named` / `:null` / `:addr`) is
   the right abstraction. Ref-equality alone is unsound when two
   aliases both point at the same `inttoptr (i64 K)` via distinct
   ConstantExpr wrappers — but tuple equality on `(:addr, K)` catches
   that case correctly.

### Sequence note (from user plan)

Remaining ir_extract gaps:
- cc0.6 (error-report cleanup, ptrtoint/inttoptr in runtime contexts —
  TJ1 target). Next up per user plan.
- cc0.5 (thread_ptr GEP / `Memory{T}` struct layout — TJ4 target).
  Stays T5-P6-scope, not a standalone fix.

---

## Session log — 2026-04-20 — Bennett-cc0.3 closed; Bennett-cc0.5 stays open (new evidence)

User plan: "cc0.3 + cc0.5 together — they form a chain; tackle as one PR."
Empirical evidence reversed that framing. **cc0.3 fixed cleanly; cc0.5's full
fix is substantially larger than the bead suggested** — it requires modeling
Julia's Array/Memory struct layout, which is T5-P6 territory.

### cc0.3 — LLVMGlobalAliasValueKind (closed)

Root cause: LLVM.jl's `identify` function raises on value kind 6 (GlobalAlias)
because no Julia wrapper type exists. Fires during `LLVM.operands(inst)`
iteration whenever an instruction has a GlobalAlias operand — common in
Julia JIT globals (`@"jl_global#NNN.jit"`).

Fix (minimal, 3+1 protocol per CLAUDE.md §2):
- `docs/design/cc03_05_proposer_A.md` (924 lines)
- `docs/design/cc03_05_proposer_B.md` (1303 lines)
- `docs/design/cc03_05_consensus.md` (orchestrator synthesis)

Both proposers converged on raw-C-API `_resolve_aliasee` + `_safe_operands` +
`OPAQUE_PTR_SENTINEL`. Landed as helpers (available for future use by
cc0.4/cc0.6 et al) plus a minimal skip-path in the main dispatch loop:

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
```

Skipped instructions leave their SSA dest un-bound; downstream consumers
raise an `ErrorException` at `_operand` time, satisfying the T5 corpus
`@test_throws`. User arithmetic (which doesn't touch runtime ptrs)
extracts normally.

Behavior post-fix:
- TJ1 (Vector): used to error "Unknown value kind LLVMGlobalAlias". Now
  errors "Unsupported LLVM opcode: LLVMPtrToInt" (cc0.6 territory).
- TJ2 (Dict): used to error same LLVMGlobalAlias. Now errors "Loop
  detected in LLVM IR but max_loop_iterations not specified" — the Dict
  runtime iterator is visible. That's a legitimate downstream signal.
- TJ3 (linked list): unchanged — errors "Unknown operand ref for:
  constant-ptr icmp eq" (cc0.4 territory).
- TJ4 (Array): unchanged — errors "GEP base thread_ptr not found in
  variable wires" (cc0.5 territory).

All existing `@test_throws ErrorException` pass byte-identical behavior
(error message may differ, type still ErrorException).

### cc0.5 — thread_ptr GEP (remains open, evidence filed)

Attempted a pre-walk (`_collect_opaque_tls_chain`) that seeds inline-asm
TLS call results + ptr-typed allocas + scratch arrays-of-int allocas, then
forward-closes. Worked on TJ4 (2,834 gates GREEN with verify=true) — but
broke cond_pair under `--check-bounds=yes`.

**Critical discovery (post-implementation empirical check):**

1. TJ4's "success" was a Julia-optimizer mirage. With optimize=true,
   Julia folds `a[idx] = x; a[idx]` → `x` directly (write-then-read same
   slot). The extracted ParsedIR literally contains `ret i8 %"x::Int8"`
   after a bounds-check diamond — the array doesn't actually flow into
   the circuit. Any cc0.5-style pre-walk could "pass" TJ4 while doing
   nothing useful.

2. **`cond_pair` and `array_even_idx` IR shape depends on
   `--check-bounds`.** With check-bounds=no (Julia REPL default), they
   use a direct static `alloca [3 x i64]` that the existing dispatcher
   handles. With check-bounds=yes (Pkg.test() default), they route
   through the SAME TLS allocator as TJ4, producing a `thread_ptr` chain
   + `@ijl_gc_small_alloc` + `Memory{Int8}` struct + user GEPs/loads.
   Thus any TLS-chain suppression breaks them.

3. The forward-closure approach is structurally wrong: user-level loads
   from `%memory_data` (derived from the allocator result) transitively
   depend on the TLS chain. Marking them opaque skips the user code.
   Marking only the TLS preamble (not reaching into Memory/Array struct
   accesses) requires understanding Julia's heap layout semantically —
   that's T5-P6 dispatcher scope, not "a pre-walk".

**Right fix (for cc0.5) requires:** identify `@ijl_gc_small_alloc` calls
as synthetic allocas of known size (from the i32 size operand), and emit
an IRAlloca keyed on the `%memory_data = getelementptr ptr %alloc, i64 16`
— i.e. teach the extractor about Julia's `Memory{T}` struct layout
(header at offset 0, data pointer at offset 8, size at offset 16, raw
data at offset 24 or wherever). Cross-Julia-version stability and
correctness validation push this toward a dedicated milestone.

**Deferred.** Evidence filed in bd comment on Bennett-cc0.5. New scope
estimate: ~500 LOC extractor + dispatcher work, not "a pre-walk".
Independent of cc0.3 — neither chains to the other.

### Suite status

Full `Pkg.test()` GREEN (with `--check-bounds=yes`, the Pkg.test default).

Gate-count spot checks:
- soft_fptrunc: 36,474 (unchanged)
- popcount32: 2,782 (unchanged)
- HAMT demo: 96,788 (unchanged)
- CF demo: 11,078 (unchanged)
- CF+Feistel: 65,198 (unchanged)

Tests added: none (cc0.3 fix is a skip-path; behavior change already
covered by existing `@test_throws ErrorException` in test_t5_corpus_julia.jl).

### Next (per user sequence)

3. cc0.4 — constant-pointer icmp eq (TJ3 unblock)
4. cc0.6 — error-report cleanup (TJ1 unblock)
5. cc0.5 — filed as scope bump; needs dedicated milestone
6. T5-P5a/P5b — multi-language ingest
7. T5-P6 — dispatcher integration
8. T5-P7 — BennettBench writeup

---

