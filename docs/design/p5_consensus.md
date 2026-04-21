# T5-P5a + T5-P5b — Consensus (orchestrator synthesis)

Proposers A (`p5_proposer_A.md`, 1,098 lines) and B (`p5_proposer_B.md`, 780 lines)
converged on the same architecture. This doc records the tie-breakers.

## Shared design

1. **Refactor `_module_to_parsed_ir(mod)` into two pieces.** A core walker
   `_module_to_parsed_ir_on_func(mod, func)` that does all the existing work,
   and a thin dispatcher `_module_to_parsed_ir(mod; entry_function=nothing)`
   that picks the function. Default `nothing` preserves the julia_ heuristic
   byte-for-byte.
2. **New helper `_find_entry_function(mod, name)`** — exact LLVM-level name
   match. Fail loud on miss (with a list of candidates), declaration-only,
   multiple matches.
3. **P5a `extract_parsed_ir_from_ll`** — `read(path, String) |> parse(Module, ...)`
   then walker on selected entry.
4. **P5b `extract_parsed_ir_from_bc`** — `MemoryBufferFile(path)` then
   `parse(Module, ::MemoryBuffer)` (bitcode-only overload). Same walker.
5. **`reversible_compile(parsed::ParsedIR; ...)` overload** in `src/Bennett.jl`
   — shim around `lower + bennett`. Drops `optimize` / `bit_width` / `strategy`
   kwargs (PRD §11 — not in scope for a pre-extracted ParsedIR). Keeps
   `max_loop_iterations`, `compact_calls`, `add`, `mul`.

## Tie-breakers

| Question | A | B | Chosen | Why |
|---|---|---|---|---|
| Refactor shape | kwarg `entry_function=nothing` on dispatcher | Separate sibling function | **A** (kwarg) | One name, one call site — simpler. |
| Rust mangling | `#[no_mangle]` already used in fixtures; exact match only | Fail loud with near-match hint; no auto-fallback | **both** — exact match only; error lists candidates. |
| Bitcode API | `MemoryBufferFile(path)` + `parse(Module, ::MemoryBuffer)` | Same | **both converged** |
| `use_memory_ssa` for bc path | Error with `llvm-dis` workaround hint | Round-trip to text then run pass | **A** (fail loud); user can convert to `.ll` for memssa. Simpler, avoids hidden cost. |
| Fixture compile | Harness already runs clang/rustc per-test | Same | **both converged** |

## Critical gotcha (Proposer B flagged)

`parse(Module, ::MemoryBuffer)` is **bitcode-only**. There is no textual
overload on `MemoryBuffer`. Consequence:
- `.ll` path: `read(path, String)` then `parse(Module, ::String)` → `LLVMParseIRInContext`.
- `.bc` path: `MemoryBufferFile(path)` then `parse(Module, ::MemoryBuffer)` → `LLVMParseBitcodeInContext2`.

## LLVM.jl symbols (verified by Proposer B)

- `Base.parse(::Type{Module}, ::String)` — `core/module.jl:188`
- `Base.parse(::Type{Module}, ::MemoryBuffer)` — `core/module.jl:220`
- `MemoryBufferFile(path::String)` — `buffer.jl:51`
- `isdeclaration` — `core/value/constant.jl:779`
- `linkage` — `core/value/constant.jl:790`

## Test plan

1. `test/test_p5a_ll_ingest.jl` — hand-written `.ll` fixture defining
   `foo(i8) -> i8` that adds 3. Parse via new entry, exhaustive i8 test.
2. `test/test_p5a_equivalence.jl` — for 3 existing test programs, capture
   `code_llvm(f, T; dump_module=true)` to temp, parse via new entry,
   assert ParsedIR equality vs `extract_parsed_ir(f, T)`.
3. `test/test_p5b_bc_ingest.jl` — P5a fixture as bitcode (compiled from
   the .ll via LLVM.jl or `llvm-as`).
4. `test/test_p5_fail_loud.jl` — file not found, entry missing,
   entry is declaration-only.
5. Corpus flip: `test_t5_corpus_c.jl` + `test_t5_corpus_rust.jl` —
   replace `@test_throws UndefVarError` with two asserts: `@test parsed isa
   ParsedIR` (extraction GREEN) + `@test_throws ErrorException
   reversible_compile(parsed)` (lowering still RED until P6).

## Regression argument

Walker body is unchanged; dispatcher adds one kwarg with
zero-behaviour-change default. All WORKLOG baselines remain byte-identical
(soft_fptrunc 36,474; popcount32 2,782; HAMT 96,788; CF 11,078; CF+Feistel
65,198; i8/i16/i32/i64 add 98/202/410/826; TJ3 180; ls_demo_16 5,218).

## Implementer's checklist

1. Write hand-written `.ll` fixture + `test_p5a_ll_ingest.jl` — RED.
2. Refactor `_module_to_parsed_ir` per §shared design.
3. Add `_find_entry_function`, `extract_parsed_ir_from_ll`, `extract_parsed_ir_from_bc`.
4. Add `reversible_compile(::ParsedIR)` overload in `Bennett.jl`; export.
5. Equivalence test GREEN.
6. Fail-loud contracts + tests.
7. Flip corpus tests.
8. Full suite + baselines.
9. WORKLOG + close both beads + push.
