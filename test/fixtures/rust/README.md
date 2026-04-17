# T5 Rust Fixture Files

Part of the Bennett.jl T5 multi-language test corpus (T5-P2c).
See `Bennett-Memory-T5-PRD.md` §7.3 for corpus specification.

## Toolchain

```
rustc 1.95.0 (59807616e 2026-04-14)
```

## Compile Commands

Each file is compiled with:

```bash
rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
      -o <output>.ll <source>.rs
```

### t5_tr1_vec_push.rs → Vec<i8> push×3 + iter sum

```bash
rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
      -o /tmp/t5_tr1_vec_push.ll t5_tr1_vec_push.rs
```

Entry function: `vec_push_sum` (symbol `@vec_push_sum` in .ll)
LLVM IR line count: **582 lines**

### t5_tr2_hashmap.rs → HashMap<i8,i8> insert + get

```bash
rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
      -o /tmp/t5_tr2_hashmap.ll t5_tr2_hashmap.rs
```

Entry function: `hashmap_roundtrip` (symbol `@hashmap_roundtrip` in .ll)
LLVM IR line count: **6,113 lines**

**TR2 fallback decision**: The PRD (§7.3) and bead description specify a
fallback to a hand-rolled hash table if std HashMap produces >10k LLVM lines.
Measured at 6,113 lines (rustc 1.95.0, opt-level=0) — under the 10k threshold.
The standard `std::collections::HashMap` is used directly; no fallback needed.

Note: 6,113 lines is ~10× larger than TR1/TR3 (~580 lines each) because
HashMap pulls in its full std library implementation, including SipHash,
RawTable (hashbrown), and alloc/memory management. This is expected — the
T5-P5a ingest layer (extract_parsed_ir_from_ll) will locate the entry
function by symbol name and extract only the reachable call graph.

### t5_tr3_box_list.rs → Box<Node> singly-linked list

```bash
rustc --emit=llvm-ir -C opt-level=0 --crate-type lib --edition 2021 \
      -o /tmp/t5_tr3_box_list.ll t5_tr3_box_list.rs
```

Entry function: `box_list` (symbol `@box_list` in .ll)
LLVM IR line count: **578 lines**

## LLVM Line Count Summary

| File | Entry function | Lines | Fallback? |
|---|---|---|---|
| t5_tr1_vec_push.rs | `vec_push_sum` | 582 | N/A |
| t5_tr2_hashmap.rs | `hashmap_roundtrip` | 6,113 | No (under 10k threshold) |
| t5_tr3_box_list.rs | `box_list` | 578 | N/A |

## Current Status (2026-04-17)

All three fixtures compile cleanly (no errors, no warnings with `#[allow(dead_code)]`
on the `Node` struct in TR3). The Julia harness (`test/test_t5_corpus_rust.jl`) is
RED: all three tests throw `UndefVarError` because `Bennett.extract_parsed_ir_from_ll`
(T5-P5a) is not yet implemented.

Blocking beads:
- **T5-P5a** (Bennett-lmkb): `extract_parsed_ir_from_ll` — required before tests can reach the lowering pipeline
- **T5-P6** (Bennett-z2dj): `:persistent_tree` dispatcher arm — required for tests to go GREEN
