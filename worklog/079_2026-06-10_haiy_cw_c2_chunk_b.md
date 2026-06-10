# 079 — 2026-06-10 — Bennett-haiy — CW-C2 chunk B (BVM ADR 0020 D3+D4)

**Bead:** `Bennett-haiy` (P1, feature; depends-on `Bennett-k3ej`).
**Design:** BennettVM `docs/adr/0020-c-track-frontend-contract.md`
Decisions 3+4. Orchestrated from BennettVM (Opus 4.8). Predecessor:
chunk A (`Bennett-k3ej`, commit `b91f91c`; worklog 078). Scope = ADR
D3 (ptr store/load + ptr return) + D4 (two-index struct GEP) ONLY; call
emission + multi-function producer are chunk C.

### The mode gate (the critical design constraint)

The existing fail-louds — `store ptr` (U114 / Bennett-lgzx), silent-nothing
`load ptr`, the two-index GEP U16 reject (Bennett-qal5), and the ptr/void
return-width walls (U81 / Bennett-dq8l, U82 / Bennett-qmk6) — protect the
Julia circuit / `mem=:heap` models. They MUST keep firing byte-identically
for those paths. Chunk B introduces ONE explicit switch:

- **kwarg `ptr_cells::Bool=false`** on `extract_parsed_ir_from_ll` (and
  `_from_bc`, for parity).
- **Threading path:** `extract_parsed_ir_from_ll` → `_extract_from_module`
  → `_module_to_parsed_ir` → `_module_to_parsed_ir_on_func` →
  `_convert_instruction`. Five hops, all defaulting `false`. The two other
  `_convert_instruction` callers (`vector_vm_cfg.jl`, `heap.jl`) get the
  default unchanged.
- The C track flips `ptr_cells=true`; the Julia paths never set it, so the
  default extraction is byte-identical. ALL chunk-B acceptance is gated on
  it. Documented at each site + in the `extract_parsed_ir_from_ll` docstring.

### What landed (all gated on `ptr_cells=true`)

- **D3 — `store ptr` → 64-bit IRStore** (`instructions.jl` store arm). A
  `store ptr %v, ptr %p` stores a pointer VALUE = one Int64 VM cell (ADR
  0018 §A). Width 64, not `LLVM.width(vt)` (PointerType has no integer
  width). Same registered-SSA-target guard as the U114 path. Gate-off: the
  U114 fail-loud fires unchanged.
- **D3 — `load ptr` → 64-bit IRLoad** (`instructions.jl` load arm). A
  non-integer `PointerType` load returns a 64-bit IRLoad under the gate;
  gate-off keeps the pre-existing silent-skip (`return nothing`).
- **D3 — `ptr` RETURN → ret_width 64** (`module_walk.jl` return-width
  derivation). Handled at the derivation site, NOT in `_type_width`
  (which stays byte-identical — its ptr/void/struct/vector error messages
  are pinned by `test_qmk6_dq8l`). Gate-off: the `_type_width`
  "unsupported LLVM type" PointerType wall fires unchanged.
- **D3 — `ret ptr %p` TERMINATOR → IRRet width 64** (`instructions.jl` ret
  arm). REQUIRED in addition to the return-WIDTH derivation: the `IRRet`
  terminator queries `_iwidth(ops[1])` on the returned ptr value, which
  also hits `_type_width(PointerType)`. The standalone `ptr`-return probe
  (no body wall before the ret) surfaced this; `ht_new` masks it because it
  dies at `malloc` first. (Rule 2: all bugs are deep — the IRRet operand
  width is part of D3, not a separate concern.)
- **D4 — two-index struct GEP → IRPtrOffset** (`instructions.jl` GEP arm).
  `getelementptr %struct.T, ptr %p, i32 0, i32 K` (named SSA base, exactly
  3 ops) → `IRPtrOffset(dest, base, offset_bytes, elem_width=64)`. Byte
  offset from `LLVM.offsetof(dl, struct_ty, K)` (= `LLVMOffsetOfElement`),
  NEVER IR-text parsing (Rule 5/8). Datalayout reached via
  `LLVM.parent(LLVM.parent(LLVM.parent(inst)))`. FAIL LOUD (still) on:
  first index ≠ 0, non-struct pointee, non-constant member index, and
  member offset not 8-byte aligned (the BVM cell discipline,
  `offset_bytes % 8 == 0` per ADR 0018 — a packed / i32-member struct fails
  loud). > 2 indices fall through to U16. Gate-off: the U16 reject fires
  unchanged, including for the `qal5` array-GEP case (non-struct pointee).

### The void-return scope decision (D5 stays in chunk C)

The prompt asked whether void-return-width is a one-line `width=0/no-ret`
case that belongs HERE (return handling) rather than chunk C. **It is NOT.**
The void wall IS in the return-width derivation (`module_walk.jl:88`,
`_type_width(VoidType)`), as worklog 078 said — but handling it entangles
with the `IRRet` IR SHAPE: `IRRet` requires `op::IROperand` AND
`width >= 1` (`ir_types.jl`). A `ret void` carries no operand and no width,
so representing "no return value" needs a void-return terminator FORM — a
new IR-shape decision. Void CALLS have the identical no-dest modelling
problem and are chunk C's job (D5). So void-return belongs WITH chunk C's
call-emission work, not split off into return-WIDTH derivation. Left as-is:
`ht_free`/`ht_put` (`ret void`) stay at the existing VoidType (Bennett-dq8l
/ U81) wall even with the gate on. Documented at the return-width site.

### Frontier (probed live vs BVM `test/reference/c/hashtable.O0.ll`)

Gate ON (`ptr_cells=true`) — the new frontier is ONLY the chunk-C
call/void-return walls:

| fn | chunk-A wall | chunk-B frontier (gate on) |
|----|--------------|----------------------------|
| `ht_new` | ptr-return (U82) | `malloc` call (U15) — chunk C |
| `ht_get` | store-ptr (U114) | `ht_hash` call (U15) — chunk C |
| `ht_del` | store-ptr (U114) | `ht_hash` call (U15) — chunk C |
| `ht_free` | void-return (U81) | void-return (U81) — chunk C (D5) |
| `ht_put` | void-return (U81) | void-return (U81) — chunk C (D5) |
| `ht_demo_basic` | `ht_new` call (U15) | `ht_new` call (U15) — chunk C |

NOTE on `ht_new`: the `malloc` call (line 142) precedes the struct GEPs
(lines 148+) in the body, so `ht_new`'s IRPtrOffset {0,8,16,24} are NOT
reached end-to-end under O0 (the walk dies at malloc first). The
struct-GEP lowering producing exactly {0,8,16,24} with elem_width 64 is
verified by a dedicated minimal-`.ll` D4 testset instead.

Gate OFF: byte-identical to chunk A (ht_new at ptr-return, ht_get at
store-ptr, ht_free at void-return).

### Tests — `test_haiy_ptr_cells_store_load_gep.jl` (NEW), wired into runtests

- (a) gate-off: U114 store reject, U16 GEP reject, ptr-return reject — exact
  substrings pinned.
- (b) gate-on: store/load ptr widths == 64; ptr return ret_width == 64;
  struct GEP → IRPtrOffset {0,8,16,24} elem_width 64; five D4 fail-loud edge
  cases (first idx≠0, non-struct pointee, >2 idx, packed struct, i32
  members).
- (c) fixture frontier pins for ht_new/ht_get/ht_del (advance to call walls)
  + ht_free/ht_put (stay at VoidType) + gate-off byte-identical.

### Gates (all at `--check-bounds=yes`, serial — one Julia process)

- new `test_haiy_ptr_cells_store_load_gep.jl`: **45/45**.
- `test_gate_count_regression.jl`: **39/39** byte-identical (i8 58/i16 114/
  i32 226/i64 450; Toffoli 12/28/60/124).
- `test_5ikt_heap_m3.jl`: **529/529** (highest `mem=:heap` regression risk).
- `test_k3ej_ircall_symbol_c_ptr_param.jl`: **29/29** (chunk-A frontier
  byte-identical under default gate).
- `test_zyjn_deref_bytes_distinct_failures.jl`: **5/5**.
- Pinned-message gates: `test_lgzx_store_fail_loud` **4/4**,
  `test_qal5_multi_index_gep` **2/2**, `test_qmk6_dq8l_type_width_errors`
  **21/21** (confirms `_type_width` byte-identical — void/ptr messages
  unchanged). [qmk6_dq8l needs `using Test;using Bennett` preload to run
  standalone — pre-existing file quirk, not chunk-B-induced.]
- Integer-path GEP/store regressions (the arms I edited, default gate):
  `test_store_alloca_extract` **279/279**, `test_vz5n_gep_offset_bytes`
  +`xv0u` **16/16**, `test_plb7_irvargep_elem_width` **3/3**,
  `test_var_gep` **9/9**.
- T5 corpus reject (C/Rust): C **6/6**, Rust **6/6** still throw.
- `test_g27k_cc03_catch_narrow` **5/5** (the catch path threaded through).

Did NOT run full Bennett.jl `Pkg.test` (~65 min) per orchestration
directive; HANDOFF says the full suite runs once before any Bennett.jl push,
after chunks B+C.

### Chunk-C handoff notes

- The new frontier is ONLY call emission (U15: malloc/calloc/realloc/free +
  in-module ht_hash/ht_put/ht_new) and void return/void call (D5). Both are
  the no-dest / no-value modelling problem; solve them together.
- The chunk-A precondition still stands: BVM `src/ir/ingest_body.jl` has 8x
  `nameof(inst.callee)` sites that need a `callee isa Symbol ? callee :
  nameof(callee)` branch before any Symbol-callee IRCall reaches BVM
  `lower_vm`. That is the first BVM-side step of chunk C.
- `ht_new`'s struct GEPs sit after the first `malloc`, so end-to-end
  `ht_new` IRPtrOffset coverage only appears once chunk C emits the malloc
  IRCall and lets the walk continue.
