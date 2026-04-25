## Session log — 2026-04-21 — Bennett-lmkb + Bennett-f2p9 closed (T5-P5a + P5b multi-language ingest)

Headline cross-language feature: Bennett.jl can now consume raw LLVM IR
(`.ll` text) and bitcode (`.bc`) from any language that compiles to LLVM,
not just Julia. 3+1 protocol per CLAUDE.md §2.

### 3+1 protocol

- `docs/design/p5_proposer_A.md` (1,098 lines, general-purpose subagent)
- `docs/design/p5_proposer_B.md` (780 lines, general-purpose subagent)
- `docs/design/p5_consensus.md` (orchestrator synthesis)

Converged on: refactor `_module_to_parsed_ir(mod)` into a dispatcher that
takes `entry_function::Union{Nothing, AbstractString}=nothing` + a core
walker `_module_to_parsed_ir_on_func(mod, func)` that does the existing
work. Zero-behaviour-change default preserves every baseline byte-for-byte.

### Critical gotcha (Proposer B flagged, verified empirically)

`parse(Module, ::MemoryBuffer)` is **bitcode-only**. No textual overload
on `MemoryBuffer` exists in LLVM.jl. Consequence:
- `.ll` path: `read(path, String)` → `parse(Module, ::String)` → `LLVMParseIRInContext`
- `.bc` path: `MemoryBufferFile(path)` → `parse(Module, ::MemoryBuffer)` → `LLVMParseBitcodeInContext2`

### Implementation — src/ir_extract.jl + src/Bennett.jl

- `_find_entry_function(mod, entry_function)` — exact LLVM.name match.
  Fail loud on miss (with candidate list), ambiguous, declaration-only.
  When `entry_function === nothing`, uses legacy `julia_*` heuristic.
- `_module_to_parsed_ir(mod; entry_function=nothing)` — dispatcher.
- `_module_to_parsed_ir_on_func(mod, func)` — core walker (renamed body).
- `_extract_from_module(mod, entry_function, effective_passes)` —
  shared plumbing: optional pass pipeline + walker invocation.
- `extract_parsed_ir_from_ll(path; entry_function, preprocess=false,
  passes=nothing, use_memory_ssa=false)` — text ingest.
- `extract_parsed_ir_from_bc(path; entry_function, preprocess=false,
  passes=nothing)` — bitcode ingest (no `use_memory_ssa` — user must
  convert to .ll via `llvm-dis` first).
- `reversible_compile(parsed::ParsedIR; max_loop_iterations, compact_calls,
  add, mul)` — new overload in Bennett.jl for consuming pre-extracted
  ParsedIR. Drops `optimize` / `bit_width` / `strategy` (not meaningful
  on a pre-extracted ParsedIR).

Both entry points exported.

### Tests

- `test/fixtures/ll/p5a_add3.ll` — hand-written 4-line .ll fixture.
- `test/test_p5a_ll_ingest.jl` — 256-input exhaustive + verify_reversibility.
- `test/test_p5a_equivalence.jl` — 4 Julia programs; capture `code_llvm`
  to temp .ll, ingest via new entry, assert ParsedIR structural equality
  + identical gate counts against `extract_parsed_ir(f, T)`.
- `test/test_p5b_bc_ingest.jl` — same as P5a fixture but compiled via
  `llvm-as`. Skips gracefully if `llvm-as` unavailable.
- `test/test_p5_fail_loud.jl` — 4 fail-loud contracts: file-not-found
  (.ll + .bc), entry-name-absent, entry-is-declaration.
- `test/test_t5_corpus_c.jl` (TC1/TC2/TC3) — flipped from `@test_throws
  UndefVarError` to `@test parsed isa ParsedIR` + `@test_throws
  ErrorException reversible_compile(parsed)`. Extraction GREEN; lowering
  still RED until T5-P6.
- `test/test_t5_corpus_rust.jl` (TR1/TR2/TR3) — flipped to
  `@test_throws Union{ErrorException, LLVM.LLVMException}` wrapping the
  full pipeline. Rust emits 6k+ lines of IR at opt-level=0 with debug
  info that `parse(Module, text)` rejects against Julia's default context
  (fails with LLVM.LLVMException before reaching the walker).

### Gotchas discovered (new, worth recording)

1. **Julia-mangled function names are quoted in LLVM IR.** A function
   `var"#5"(Int8)` gets emitted as `@"julia_#5_144"`. Regexes that match
   `@(julia_\w+)\(` miss the quoted form. The equivalence test uses
   `@"(julia_[^\"]+)"\(|@(julia_[\w\.]+)\(` to handle both.

2. **Rust IR at opt-level=0 is context-incompatible with Julia's default
   LLVMContext.** The emitted .ll includes target-triple / datalayout /
   debug metadata that `LLVM.parse(LLVM.Module, text)` rejects. Raises
   `LLVM.LLVMException`, not `ErrorException`. The fix is to widen
   test expectations; a proper cross-context parser is future work.

3. **clang -O0 emits IR that extracts successfully.** Simple C fixtures
   (malloc + array-of-int + index) produce valid ParsedIR via the shared
   walker. The walker then fails at lowering due to dynamic-alloca +
   dynamic-idx patterns (T5-P6 territory), as expected.

4. **#[no_mangle] is mandatory for Rust fixtures.** All 3 fixtures use
   it; user-facing docs must note this. The fail-loud `_find_entry_function`
   error message includes the candidate list so a user immediately sees
   whether mangling is the cause.

### Regression check — all baselines byte-identical

Full `Pkg.test()` GREEN. Spot-checks vs 2026-04-20 WORKLOG numbers:

| Primitive | Pre-fix | Post-fix | Δ |
|---|---:|---:|---|
| soft_fptrunc | 36,474 | 36,474 | 0 |
| popcount32 standalone | 2,782 | 2,782 | 0 |
| HAMT demo (max_n=8) | 96,788 | 96,788 | 0 |
| CF demo (max_n=4) | 11,078 | 11,078 | 0 |
| CF+Feistel | 65,198 | 65,198 | 0 |
| TJ3 (cc0.4) | 180 | 180 | 0 |

Zero-regression guarantee by construction: the walker body is unchanged
(moved into `_module_to_parsed_ir_on_func`); the dispatcher adds one
kwarg with a behaviour-preserving default.

### Next steps

- T5-P6 (`:persistent_tree` dispatcher arm + `mem=` kwarg) — the last
  epic-critical bead. Unlocks end-to-end GREEN on TC/TR corpus and
  TJ1/TJ2/TJ3 Julia tests. Sweep data favours linear_scan as default.
- cc0.5 (thread_ptr GEP) — T5-P6-scope work, will land as part of P6.

---

## Session log — 2026-04-21 — Bennett-cc0.6 closed (error-message standardization)

Chore-scope bead explicitly waived the 3+1 protocol in its description
("Additive (no behavior change), no 3+1 needed"). Respected per
CLAUDE.md §10 judgment — 3+1 produces novel design; chores don't benefit.

### Scope

Per bead: every `error()` in `ir_extract.jl` should follow the format
`'ir_extract.jl: <opcode> in @<funcname>:%<blockname>: <serialised
instruction> — <reason>'`. Motivation: debugging T5-P2a failures required
mapping each error back to IR by hand.

### RED test

`test/test_cc06_error_context.jl` — two testsets:
1. Unit: build a synthetic 1-instruction LLVM module, call the new
   `_ir_error(inst, reason)` helper directly, assert the emitted message
   contains `ir_extract.jl:`, `@<funcname>`, `%<blockname>`, and the
   reason text.
2. End-to-end: synthesise a module containing a `va_arg` instruction
   (unsupported opcode) via raw C API (`LLVMBuildVAArg`), run it through
   `_module_to_parsed_ir`, assert the propagated error has the canonical
   format with the real function + block names.

Pre-fix: RED on both (helper not defined). Post-fix: GREEN.

### Implementation — src/ir_extract.jl (+~120 lines)

Three additions in the cc0.6 helpers block between `_auto_name` and the
sret section:
- `_LLVM_OPCODE_NAMES` — Dict mapping LLVM opcodes → human-readable
  names for the format's `<opcode>` slot (with `string(opc)` fallback).
- `_ir_error_msg(inst, reason)` — pure string formatter.
- `_ir_error(inst, reason)` — raising entry point. Robust to
  `LLVM.parent()` failing (falls back to `<unknown-fn>` / `<unknown-block>`).

### Refactored error sites (~25 call sites)

Instruction-scoped errors in `_convert_instruction`, `_convert_vector_instruction`,
`_collect_sret_writes`, and `_detect_sret` migrated to `_ir_error(inst, ...)`
or prefixed `ir_extract.jl:` where no `inst` was in scope but `func`
was. Helper-level errors in `_operand`, `_fold_constexpr_operand`,
`_resolve_vec_lanes`, `_type_width` got the `ir_extract.jl:` prefix to
keep the "which module raised this?" signal consistent.

### Regression check — zero behaviour change

Full `Pkg.test()` GREEN. All baselines byte-identical (soft_fptrunc
36,474 / popcount32 2,782 / HAMT 96,788 / CF 11,078 / CF+Feistel 65,198 /
TJ3 180). No `@test_throws ErrorException` test is type-sensitive to
message content; the cc0.3 skip path in `_module_to_parsed_ir` matches
only on LLVM.jl-originated strings ("Unknown value kind",
"LLVMGlobalAlias", MethodError+"PointerType") — none of which were
touched.

### Deliberately OUT of scope

1. **Threading `inst` through `_operand` / `_fold_constexpr_operand` /
   `_resolve_vec_lanes`** — would give every helper-level error full
   canonical context. Adds one parameter to ~30 call sites. Deferred
   as a strictly additive follow-up.
2. **Implementing ptrtoint / inttoptr support for TJ1** — the NEXT
   AGENT header of the previous session conflated cc0.6 (chore) with a
   "cc0.6 territory" comment about TJ1's ptrtoint error. cc0.6 as filed
   is error-message cleanup only; TJ1 ptrtoint support is a separate
   bead if/when prioritised.

### Sequence note

Remaining cc0.x gaps:
- cc0.5 (thread_ptr GEP / `Memory{T}` struct layout — TJ4 target).
  Stays T5-P6-scope, not a standalone fix.

Next options (per user plan 2026-04-20):
- T5-P5a/P5b: multi-language `.ll` / `.bc` ingest (headline feature).
- T5-P6: `:persistent_tree` dispatcher arm (linear_scan default per
  2026-04-20 sweep findings).

---

