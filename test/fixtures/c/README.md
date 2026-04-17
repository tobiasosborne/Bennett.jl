# T5 C Fixture Files

Part of the Bennett.jl T5 multi-language test corpus (T5-P2b).
See `Bennett-Memory-T5-PRD.md` §7.2 for corpus specification.

## Toolchain

```
Ubuntu clang version 18.1.3 (1ubuntu1)
Target: x86_64-pc-linux-gnu
```

## Compile Commands

Each file is compiled with `-O0` (no optimisation) per CLAUDE.md §5: "always
use optimize=false for predictable IR". This keeps the LLVM IR stable across
clang invocations and makes the call sites for `@malloc`/`@realloc`/`@free`
clearly visible as direct external-function calls.

### t5_tc1_malloc_idx.c → malloc + dynamic-index array

```bash
clang -O0 -emit-llvm -S -o /tmp/t5_tc1_malloc_idx.ll t5_tc1_malloc_idx.c
```

Entry function: `malloc_idx_inc` (symbol `@malloc_idx_inc` in .ll)
LLVM IR line count: **103 lines**

Pattern: `int8_t* v = malloc(8)` + `v[i & 7]` where `i` is a runtime argument.
The dynamic index `i & 7` is the T5 trigger: it forces a runtime GEP that no
static-idx tier (T3b shadow, T4 shadow-checkpoint) can handle.

### t5_tc2_realloc.c → growing buffer via realloc

```bash
clang -O0 -emit-llvm -S -o /tmp/t5_tc2_realloc.ll t5_tc2_realloc.c
```

Entry function: `realloc_buf` (symbol `@realloc_buf` in .ll)
LLVM IR line count: **94 lines**

Pattern: `malloc(2)` + `realloc(v, 4)` — the realloc call produces a new pointer
value; the old pointer becomes invalid. This exercises the resize-semantics path
that no T0–T4 tier covers.

### t5_tc3_malloc_list.c → malloc-based singly-linked list

```bash
clang -O0 -emit-llvm -S -o /tmp/t5_tc3_malloc_list.ll t5_tc3_malloc_list.c
```

Entry function: `malloc_list` (symbol `@malloc_list` in .ll)
LLVM IR line count: **97 lines**

Pattern: 3 × `malloc(sizeof(Node))` where `Node` = `{i8, ptr}`. Pointer chaining
(`a->next = b; b->next = c`) exercises mutable recursive types on the heap.

## LLVM IR Line Count Summary

| File | Entry function | Lines |
|---|---|---|
| t5_tc1_malloc_idx.c | `malloc_idx_inc` | 103 |
| t5_tc2_realloc.c | `realloc_buf` | 94 |
| t5_tc3_malloc_list.c | `malloc_list` | 97 |

## External Call Patterns in .ll

All three fixtures use `@malloc`, `@realloc`, and `@free` as **standard
external function calls** — plain `call` instructions with no special
attributes beyond `noalias` / `noundef` on the return pointer:

```llvm
%7  = call noalias ptr @malloc(i64 noundef 8) #3        ; TC1
%5  = call noalias ptr @malloc(i64 noundef 2) #4        ; TC2
%16 = call ptr @realloc(ptr noundef %15, i64 noundef 4) #5  ; TC2
%7  = call noalias ptr @malloc(i64 noundef 16) #3       ; TC3
call void @free(ptr noundef %60) #4                     ; TC1
```

**Key contrast with the Julia corpus**: the Julia fixtures (T5-P2a) emit
`jl_array_push`, `jl_dict_setindex_r`, and similar Julia-runtime calls that
pass through `LLVMGlobalAliasValueKind` operands — a separate handling problem.
The C fixtures emit bare `@malloc`/`@realloc`/`@free` with no Julia runtime
involvement. This difference is load-bearing for the T5-P5a implementation.

## TODOs for Downstream Beads

### T5-P5a (`extract_parsed_ir_from_ll` — Bennett-lmkb)

- `@malloc`, `@realloc`, and `@free` are **undeclared external functions** in
  the .ll files (declared implicitly by clang via `declare` stubs appended at
  the bottom of each .ll). T5-P5a must handle implicit declarations and not
  crash when it encounters these names.
- The `noalias` return attribute and function attribute groups (`#3`, `#4`, …)
  must be tolerated even if they are not semantically interpreted.

### T5-P6 (dispatcher — Bennett-z2dj)

- `@malloc` / `@realloc` / `@free` should be recognised as the **malloc
  family** in `_pick_alloca_strategy`. They are the C-level analogues of Julia's
  `jl_array_push` / `jl_alloc_array_1d`. The `:persistent_tree` arm must fire
  for any call to one of these symbols, just as it will for Julia's allocator
  calls.
- `@realloc` is not the same as `@free` + `@malloc` from the reversible-circuit
  perspective: the version chain must record the old pointer → new pointer
  mapping to support uncompute. Document this in the `:persistent_tree` arm
  implementation notes when T5-P6 lands.

## Current Status (2026-04-17)

All three fixtures compile cleanly with clang 18.1.3 (no errors, no warnings).
The Julia harness (`test/test_t5_corpus_c.jl`) is RED: all three tests throw
`UndefVarError` because `Bennett.extract_parsed_ir_from_ll` (T5-P5a) is not
yet implemented.

Blocking beads:
- **T5-P5a** (Bennett-lmkb): `extract_parsed_ir_from_ll` — required before tests can reach the lowering pipeline
- **T5-P6** (Bennett-z2dj): `:persistent_tree` dispatcher arm — required for tests to go GREEN
