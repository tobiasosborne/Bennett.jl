# Bennett-cc0.4 — Consensus (orchestrator synthesis)

Proposers A (`cc04_proposer_A.md`, 1,160 lines) and B (`cc04_proposer_B.md`,
927 lines) converged on the same architecture. This doc records the tie-
breakers picked for implementation.

## Problem (one line)

`optimize=true` folds `isnothing()` checks on `Union{T,Nothing}` fields into
`select i1 icmp eq (ptr @A, ptr @B), ..., ...` — where the condition is a
`LLVM.ConstantExpr`. `_operand` in `src/ir_extract.jl` doesn't recognize
ConstantExpr, raising `"Unknown operand ref for: i1 icmp eq (...)"`.

## Shared design (both proposers)

1. **Intervention**: one new `elseif val isa LLVM.ConstantExpr` branch in
   `_operand`, dispatching to a new file-private helper. No other file,
   function, or IR type changes.
2. **MVP scope**: `ConstantExpr<icmp eq/ne>` on pointer operands that
   resolve (via the cc0.3 `_resolve_aliasee`) to distinct named globals or
   `null`. Fold to `iconst(0)` or `iconst(1)`. Width=1 inferred by consumer
   context (already works for `ConstantInt` operands in `lower.jl`'s
   `resolve!`).
3. **Fail-loud for everything else**: ordering predicates, non-ICmp opcodes
   (`ptrtoint` / `inttoptr` / `getelementptr` / arithmetic), unresolvable
   alias chains. Error messages cite cc0.4 and quote `string(ce)`.
4. **Regression guarantee**: the new branch is reached only when
   `val isa LLVM.ConstantExpr`, a disjoint type from `ConstantInt` /
   `ConstantAggregateZero` / SSA. Every currently-GREEN compilation path
   sees byte-identical behaviour. Baselines (soft_fptrunc 36,474,
   popcount32 2,782, HAMT 96,788, CF 11,078, CF+Feistel 65,198, i8/i16/i32/
   i64 add 86/174/350/702, ls_demo_16 5,218) stay byte-identical.

## Tie-breakers picked

| Question | A | B | Chosen | Why |
|---|---|---|---|---|
| Helper name | `_operand_constexpr` | `_fold_constexpr_operand` | **B** | More descriptive (says what it does). |
| Trivial-ptrcast peeling | Yes (`_peel_trivial_ptrcast`) | No | **A** | Real-world Julia IR wraps globals in `addrspacecast`; cheap hardening. |
| Ref-equality decider | Separate `_ptr_addresses_equal` helper | Inlined in main fn | **A** | Cleaner separation; trivially extensible later. |
| Null-ptr operand | Handled (via peel + equal) | Handled (via kind check) | **A** | Uniform with peel. |
| Error message granularity | Per-branch with hint to next-bead | Per-branch with CLAUDE.md cite | **A** for wording, **B** for the cc0.6 hint on ptrtoint/inttoptr — merge both. |
| Extra tests | `test/test_cc04.jl` (3 positive) | `test/test_cc04.jl` (3 positive + 1 fail-loud) | **A+B**: positive-only suffices; fail-loud paths are code-review + error-message granularity. |
| TJ3 flip | Yes, exhaustive i8 GREEN | Yes, exhaustive i8 GREEN + record baseline | **B**: log the new gate count in WORKLOG. |

## Final API surface

Three new file-private helpers in `src/ir_extract.jl`:

- `_CONSTEXPR_OPCODE_NAMES` — Dict for error-message opcode naming.
- `_constexpr_opcode_name(opc)` — wrapper with fallback to `sprint(show,opc)`.
- `_peel_trivial_ptrcast(ref) -> Union{_LLVMRef, Nothing}` — peels
  `bitcast` / `addrspacecast` wrappers; returns `nothing` on non-peelable
  shapes.
- `_ptr_addresses_equal(a, b) -> Union{Bool, Nothing}` — decides equality
  of two peeled ptr refs via alias resolution + named-global ref-equality.
  Returns `nothing` on unresolvable inputs (caller fails loud).
- `_fold_constexpr_operand(ce, names) -> IROperand` — the main entry
  point called from `_operand`'s new branch.

One new branch in `_operand`:

```julia
elseif val isa LLVM.ConstantExpr
    return _fold_constexpr_operand(val, names)
```

## Test plan

1. `test/test_cc04_repro.jl` already written (RED today) — flips GREEN
   post-fix. Exhaustive i8 (256 inputs), `verify_reversibility(c; n_tests=3)`.
2. `test/test_t5_corpus_julia.jl` TJ3 — remove `@test_throws`, enable the
   commented GREEN block, record the gate count as a new baseline in
   WORKLOG.md.
3. Full `Pkg.test()` suite — every currently-GREEN test stays GREEN.
4. Gate-count spot-checks on the 10 baselines above — byte-identical.

## Forward compatibility

- cc0.6 (ptrtoint / inttoptr in runtime contexts) plugs into the
  `_fold_constexpr_operand` dispatch table as one new branch per opcode.
  The `_peel_trivial_ptrcast` helper is directly reusable. The opcode-name
  dict extends with one line per new opcode.
- T5-P5a/P5b (multi-language .ll / .bc ingest) is untouched — the
  ConstantExpr path fires regardless of the IR's origin.

## Implementer's checklist

1. Write `_CONSTEXPR_OPCODE_NAMES` + `_constexpr_opcode_name` near cc0.3 helpers.
2. Write `_peel_trivial_ptrcast` + `_ptr_addresses_equal` + `_fold_constexpr_operand`.
3. Patch `_operand` with the new `elseif` branch.
4. Run `julia --project test/test_cc04_repro.jl` — confirm GREEN.
5. Flip TJ3 `@test_throws` → GREEN block in `test_t5_corpus_julia.jl`.
6. Full suite + baseline spot-checks.
7. WORKLOG session log + commit + push + close bead.
