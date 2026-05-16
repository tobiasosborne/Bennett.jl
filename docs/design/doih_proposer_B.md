# Bennett-doih proposal — Proposer B

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposer A and B worked independently — neither saw the other's output.)

## Verification of bead claims

I read CLAUDE.md, worklog/069 (rjk7+ixiz close — the ixiz lesson is loud and clear: verify bead descriptions against source), worklog/056 (37mt/9nwt cascade origins), `bd show` for doih/37mt/9nwt/ixiz/munq, and traced the relevant source. Three of the bead's claims are wrong or imprecise:

**Claim 1 — "doih reduces to per-byte constants like 9nwt case C."**
PARTIALLY true. 9nwt case-C emits **per-element constants** at `dst_ew` width with a SINGLE broadcast byte `c · 0x0101…01` packed into one `iconst` via `_broadcast_byte_to_width` (src/extract/instructions.jl:319–342, called at :505). It's NOT per-byte after Bennett-ixiz lifted it to wider element widths. For doih, the bytes are **non-uniform** (they come from the global), so the broadcast trick doesn't apply: each element-sized chunk needs its own packed `iconst` assembled from `ew_bytes` consecutive bytes of the global.

**Claim 2 — "globals dict already carries `Vector{UInt64}` packed."**
TRUE, but the packing is **per-element of the ConstantDataArray's element width**, NOT byte-packed. Reading src/extract/module_walk.jl:244–287, `_extract_const_globals` only handles initializers that are **`LLVM.ConstantDataArray`** wrapping an **`LLVM.ArrayType`** of **integer** elements ≤64 bits (lines 269–275). For `[N x i8]`, `data[i+1]` IS the i-th byte. For `[K x i64]`, `data[i+1]` is the i-th 8-byte word. So to read "byte k" of a global, doih has to know `gw` and unpack: `byte_k = (data[k÷(gw÷8) + 1] >> ((k % (gw÷8)) * 8)) & 0xff`.

**Claim 3 — "t5_tr2_hashmap.ll line 153's `@anon.7665…0` appears in `_extract_const_globals`'s output."**
FALSE — most important finding. t5_tr2_hashmap.ll:15:
```
@anon.7665023084100688a96add9323205da2.0 = private unnamed_addr constant
    <{ ptr, [24 x i8] }> <{ ptr @alloc_d077..., [24 x i8] zeroinitializer }>, align 8
```
This is a **`ConstantStruct`** (packed `<{ ptr, [N x i8] }>`), NOT a `ConstantDataArray`. `_extract_const_globals` filters at module_walk.jl:269 (`init isa LLVM.ConstantDataArray || continue`) — silently skipped today. **doih's nominal acceptance criterion is unreachable without extending `_extract_const_globals` to handle `ConstantStruct` initializers OR a separate inline path that materializes struct bytes.**

Secondary: struct field at offset 0 is a `ptr` (pointer to another global). Pointers are not Bennett wires. Even if struct extraction worked, byte 0 is a ptr that can't be materialized as a constant. **Either doih's acceptance fixture is wrong, or doih must scope-reject struct globals whose bytes are non-integer.**

## Design

### Threading approach

**Recommendation: Pass `globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}` into `_handle_memcpy_arm` via a new function parameter**, threaded through `_convert_instruction` → call-site at `instructions.jl:1104`.

Justification:
- `_extract_const_globals(mod)` already runs once at `module_walk.jl:58`. The `globals` dict is in scope at `_module_to_parsed_ir_on_func` body. Passing it down costs one extra function arg.
- The alternative (extract inline per memcpy invocation) duplicates extraction logic and runs it potentially many times.
- The `lower_var_gep!` precedent (aggregate.jl:265–277) consumes `parsed.globals` at lowering time — same dict, same shape.
- Threading cost: `_convert_instruction`'s signature gets one more arg, the `q04a` contract test needs `Tuple{...}` updated. That test is doc-only / non-load-bearing per its own comment.

**Extension required for ConstantStruct globals:** `_extract_const_globals` (module_walk.jl:244–287) needs a new arm accepting `LLVM.ConstantStruct` initializers whose fields are all integer-typed or `[N x iM]`-typed, recursively materialized into a flat byte stream. Pointer-typed fields must be hard-rejected.

If the implementer judges the ConstantStruct extension out of scope for doih (per ixiz's "scope it tight" lesson), then doih only handles `[N x iM]` ArrayType globals as src, and t5_tr2:153 gets a precise fail-loud naming `Bennett-doih-struct`.

### Predicate cascade changes

Current cascade unchanged from Proposer A's enumeration.

**Proposed restructure:**

Step A — at line 142, split the global check into separate dst-global and src-global branches:
- **`if LLVMIsAGlobalVariable(dst_v.ref) != C_NULL`** → fail loud immediately.
- **`if LLVMIsAGlobalVariable(src_v.ref) != C_NULL`** → enter `_handle_memcpy_global_src(...)` and return. This bypasses predicates 7–9 — not meaningful for a global source.

Step B — in the new `_handle_memcpy_global_src` arm, run a NEW cascade:

- **G1 (dst-side reuse):** dst must be a named SSA value (existing predicate 12).
- **G2:** dst must NOT be a global (defensive no-op).
- **G3:** dst must trace to an alloca.
- **G4:** dst alloca elem_w must be non-zero integer. **For doih Phase 1, narrow to `dst_ew == 8`.**
- **G5 (NEW — global lookup):** the LLVM global referenced by `src_v` must have an entry in `globals`. If missing → fail-loud naming `Bennett-doih-struct` for the ConstantStruct case, `Bennett-doih-opaque` for unknown-kind initializers.
- **G6 (NEW — N bounds):** `N * 8 ≤ length(data) * gw`. Fail-loud with "memcpy reads $N bytes past the global's $byte_len-byte initializer".
- **G7 (NEW — src GEP offset):** if src_v is a const-GEP of a global, the GEP byte offset must be a `ConstantInt`. Compute `src_byte_off` and add to byte index. Reject variable GEPs.

### Lowering shape (with example IR)

Mirror 9nwt case-C precisely. For `memcpy(dst, @global+src_off, N, false)` with dst_ew == 8:

```
# K = N (one IRStore per byte at width=8)
for k in 0..N-1:
    byte_k = (data[(src_off + k) ÷ ew_bytes + 1] >> (((src_off + k) % ew_bytes) * 8)) & 0xff
    IRPtrOffset(_auto, dst_op, k)
    IRStore(ssa(_auto), iconst(byte_k), 8)
```

Where `ew_bytes = gw ÷ 8` is the global's per-element byte stride.

Example: `@gtab = [4 x i8] [0x11, 0x22, 0x33, 0x44]` memcpy'd into `alloca i8, i32 4`:

```
%off0 = ptr_offset %dst, 0    ; IRPtrOffset(:off0, ssa(:dst), 0)
store i8 0x11, ptr %off0       ; IRStore(ssa(:off0), iconst(0x11), 8)
%off1 = ptr_offset %dst, 1
store i8 0x22, ptr %off1
...
```

### Element-width policy

**Option α (recommended for doih Phase 1): force `dst_ew == 8` (byte-granular only).** Reasoning:
- doih's data source (the global's byte array) is naturally byte-indexed.
- If `dst_ew > 8`, we'd need to pack `ew_bytes` consecutive global bytes into a single `iconst` per IRStore. Adds endianness assumptions. Defer to follow-up `Bennett-doih-wide`.
- Most t5 corpus globals consumed by memcpy are `[N x i8]`.

**Option β (deferred):** allow `dst_ew ∈ {8,16,32,64}` — pack `ew_bytes` source bytes per element. Worth filing as `Bennett-doih-wide`.

### Test plan

Fixtures under `test/fixtures/ll/doih_*.ll`:

**Positive:**
1. `doih_memcpy_global_n4_i8.ll` — minimal: 4-byte `[4 x i8]` const, memcpy 4, load `dst[2]`, return 0x33.
2. `doih_memcpy_global_n8_i8.ll` — 8-byte const, memcpy 8.
3. `doih_memcpy_global_n32_i8.ll` — 32-byte const (matches t5 byte count).
4. `doih_memcpy_global_iN_to_alloca_i8.ll` — `[4 x i32]` global, memcpy 16 bytes into `alloca i8` (byte-unpacking).
5. `doih_memcpy_global_const_gep_src.ll` — memcpy from `getelementptr i8, ptr @gtab, i32 4` (positive offset) — exercises G7.

**Reject:**
6. `doih_memcpy_global_dst_reject.ll` — fail loud at Step A.
7. `doih_memcpy_global_unknown_reject.ll` — `ConstantStruct` global → G5 names `Bennett-doih-struct`.
8. `doih_memcpy_global_oob_reject.ll` — N > available bytes → G6.
9. `doih_memcpy_global_dst_iN_reject.ll` — `alloca i64` dst (Phase 1 narrow) → names `Bennett-doih-wide`.
10. `doih_memcpy_var_gep_src_reject.ll` — variable GEP → G7.

**Acceptance fixture:** t5_tr2_hashmap.ll:153 ships as the reject fixture (#7 above) given the struct-typed global. To compile t5_tr2:153 specifically, file follow-up `Bennett-doih-struct` for ConstantStruct extension.

Julia test file: `test/test_doih_memcpy_global_src.jl`. Register in `test/runtests.jl` after `test_9nwt_memset_const.jl`.

Per `worklog/069` (ixiz lesson 1): grep for any existing test asserting the pre-doih reject contract that would need flipping (test_37mt, test_lqif).

### Risk register

**R1 — Bead-description-vs-source mismatch (ixiz pattern).** Bead claims globals dict is byte-packed; it's element-packed. Bead claims t5_tr2:153's global is in the dict; it isn't. Recommend honest scope: narrow doih to `[N x iM]` ArrayType globals + file `Bennett-doih-struct` follow-up.

**R2 — Pointer-typed struct fields.** If struct extension is added, t5_tr2's global has a `ptr` first field that's not representable. Must reject loudly.

**R3 — Non-fresh dst alloca (inherited from 37mt).** doih inherits implicit "fresh dst" assumption. Reuse 9nwt's `_alloca_is_fresh` as a new predicate. 37mt didn't have this check because it predates 9nwt; doih can be the first memcpy variant that applies it consistently.

**R4 — Constant table size blowup.** A 256-byte global memcpy emits 256 IRPtrOffset + 256 IRStore. Tractable for t5 (N≤48) but kilobyte tables would dominate. Mitigation in `Bennett-doih-wide`.

**R5 — `_extract_const_globals` swallow.** Existing try/catch swallows `Unknown value kind` / `LLVMGlobalAlias`. New ConstantStruct arm must NOT swallow real bugs.

**R6 — q04a contract test.** Update `Tuple{...}` to include `globals` arg type.

**R7 — Endianness (Option β only).** Stitching `ew_bytes` bytes into iN integer should follow little-endian per x86 convention.

**R8 — Inherited munq dependency.** munq closed. Good.

## Implementation sketch

1. **`src/extract/module_walk.jl:58`** — pass `globals` into call to per-instruction loop.
2. **`src/extract/instructions.jl:1452`** — extend `_convert_instruction` signature with `globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=Dict{Symbol, Tuple{Vector{UInt64}, Int}}()`.
3. **`src/extract/instructions.jl:1104`** — call site change.
4. **`src/extract/instructions.jl:91`** — extend `_handle_memcpy_arm` signature.
5. **`src/extract/instructions.jl:137–151`** — restructure predicate 5: split dst-global rejection from src-global dispatch.
6. **`src/extract/instructions.jl` (new function, ~120 LOC):** `_handle_memcpy_global_src(...)`. Implements G1–G7 cascade + lowering loop. Add helper `_global_byte_at(data, gw, byte_off)` for bit-shift unpacking.
7. **`src/extract/instructions.jl:265`** — reuse `_alloca_is_fresh`.
8. **`src/extract/module_walk.jl:244–287`** — IF scope includes ConstantStruct: add new arm. Otherwise leave untouched.
9. **`test/test_q04a_convert_instruction_contract.jl:60–61`** — update `Tuple{...}`.
10. **`test/fixtures/ll/doih_*.ll`** — 10 new fixtures.
11. **`test/test_doih_memcpy_global_src.jl`** (NEW).
12. **`test/runtests.jl`** — register after `test_9nwt_memset_const.jl`.
13. **`git grep "@test_throws.*global"` AND `git grep "8bys.*global"`** — find existing tests asserting pre-doih reject contract.

## Summary

doih relaxes `_handle_memcpy_arm`'s predicate 5 to dispatch global-src memcpy to a new arm `_handle_memcpy_global_src`. The arm reuses 9nwt case-C's per-element IRPtrOffset+IRStore(iconst) shape, with per-byte constants unpacked from the `parsed.globals` dict (threaded down through a new `_convert_instruction` parameter). Phase 1 narrows to `dst_ew==8` (byte-granular) and `[N x iM]` ArrayType globals only. Reuse `_alloca_is_fresh` to close 37mt's inherited non-fresh hazard. File `Bennett-doih-struct` (ConstantStruct globals) and `Bennett-doih-wide` (wider dst) as follow-ups.

## Blockers / assumptions flagged

- **BLOCKER (acceptance fixture):** t5_tr2_hashmap.ll:153's global is a `ConstantStruct` with a pointer-typed first field, NOT a `ConstantDataArray`. The literal bead acceptance criterion cannot be met by doih's narrow scope. Recommend (a) ship doih narrow + downgrade t5_tr2:153 to "fails loud with `Bennett-doih-struct` reference" (honest), per worklog/069's ixiz lesson.
- **ASSUMPTION (Option α):** Phase 1 is byte-granular dst (`dst_ew == 8`). Wider dst is `Bennett-doih-wide`.
- **ASSUMPTION (q04a contract):** the q04a test pin is doc-only and can be updated.
