# Bennett-doih proposal — Proposer A

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposer A and B worked independently — neither saw the other's output.)

## Verification of bead claims

I verified the bead's claims against source before designing. Findings:

**Claim 1 — "doih's lowering reduces to per-byte constants like 9nwt case C."**
PARTIALLY TRUE post-ixiz, but the bead's framing is now stale. After Bennett-ixiz (closed 2026-05-16), `_handle_memcpy_arm` emits K **element-granular** chunks at `width = dst_ew`, not byte-granular (see `src/extract/instructions.jl:217-232`). Likewise `_handle_memset_arm` emits element-granular `IRStore(iconst(c_broadcast), dst_ew)` (lines 499-514). So "case C pattern" today is "K IRPtrOffset + IRStore(iconst, dst_ew)" not "N IRPtrOffset + IRStore(iconst, 8)" as the bead implies.

**Claim 2 — "globals dict already carries `Vector{UInt64}` packed."**
The bead is AMBIGUOUS here. Inspecting `src/extract/module_walk.jl:244-287`: `data` is **per-element packed, not per-byte packed**. For a global typed `[24 x i8]`, `data` is `Vector{UInt64}` of length 24 with one byte per UInt64 entry. For `[4 x i64]`, `data` is length 4 with one i64 per entry. The element width is recorded separately in the tuple's second `Int`. **The second `Int` is `elem_width` in bits, not byte-count.**

**Claim 3 — t5_tr2_hashmap.ll:153's `@anon.7665…` appears in `_extract_const_globals`'s output.**
**FALSE.** Read `build/t5_tr2_hashmap.ll:15`:
```
@anon.7665023084100688a96add9323205da2.0 = private unnamed_addr constant <{ ptr, [24 x i8] }> ...
```
This is a packed struct of `{ptr, [24 x i8]}` — not an `ArrayType`. `_extract_const_globals` (module_walk.jl:271) does `ty isa LLVM.ArrayType || continue` — so this global is silently dropped during extraction. **`doih` cannot reach acceptance just by relaxing predicate 5 in `_handle_memcpy_arm`.** It must ALSO extend `_extract_const_globals` to handle (at minimum) `ConstantStruct` initializers whose fields flatten to a byte stream.

**Side effect:** the acceptance fixture has a `ptr` field in the struct (a pointer to another global, `@alloc_d0776666182ad032bd1011cf266e2f3a`). The first 8 bytes are pointer-typed — Bennett.jl has no semantics for runtime pointer values in a wire stream. The remaining 24 bytes are `zeroinitializer`. **The acceptance fixture is harder than the bead implies.**

**Claim 4 — "the dst alloca shape needs to be `[N x i8]` extracted" (Bennett-munq dep).**
Verified true and already satisfied; munq closed 2026-05-03.

## Design

### Threading approach

**Recommendation: extend `_handle_memcpy_arm`'s signature with an extra `globals` parameter, thread it through `_handle_intrinsic`, and pass it from the one `_convert_instruction` call site in `_module_to_parsed_ir_on_func` (module_walk.jl:190).**

Justification:

1. **Inline extraction from the LLVM.GlobalVariable would duplicate logic.** `_extract_const_globals` already handles InterruptException re-raise, the "Unknown value kind" / "LLVMGlobalAlias" benign-catch, and the `LLVMGetElementAsConstant` extraction loop. Re-implementing inline in `_handle_memcpy_arm` would either duplicate ~30 LOC or refactor `_extract_const_globals` into a per-global helper — both ugly.

2. **Threading globals via parameter is the established pattern.** `lower_var_gep!` (`src/lowering/aggregate.jl:269`) already takes `globals` as a kwarg. Mirroring this in the extract layer is consistent.

3. **The contract test at `test/test_q04a_convert_instruction_contract.jl` IS at risk.** It pins `_convert_instruction`'s signature as `(LLVM.Instruction, Dict{_LLVMRef, Symbol}, Ref{Int}, Dict{_LLVMRef, Vector{IROperand}})` at lines 58-61. Adding a `globals` parameter to `_convert_instruction` would break this. **Mitigation:** make `globals` a kwarg with a sensible empty-dict default, AND update the q04a contract test to include the new kwarg in its expected signature. This is a 1-line tuple-extension in the test, which is acceptable per CLAUDE.md §1 (the test pins a real contract, not an arbitrary surface — the contract growing by one kwarg is honest).

   Alternative considered: thread `globals` only through `_handle_intrinsic` → `_handle_memcpy_arm`, leaving `_convert_instruction`'s positional signature unchanged. This is preferable. The intrinsic dispatch already gets `dest, ops` extras vs `_convert_instruction`; adding `globals` to the intrinsic-only path costs nothing in the contract test. **Pick this variant.**

4. **The data structure is already correctly shaped.** `parsed.globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}` has exactly what `_handle_memcpy_arm` needs once we look up the global by `Symbol(LLVM.name(global_ref))`.

**Concrete signature changes:**
- `_handle_memcpy_arm(cname, inst, names, counter, ops, globals)` — add `globals` as 6th positional arg (no kwarg; intrinsic handlers are internal helpers).
- `_handle_intrinsic(cname, inst, names, counter, dest, ops, globals)` — add `globals` as 7th positional arg.
- `_convert_instruction(inst, names, counter, lanes; globals=Dict())` — add `globals` as kwarg with empty default.
- `_module_to_parsed_ir_on_func` (module_walk.jl:190) — pass `globals` keyword.

### Predicate cascade changes

Current cascade in `_handle_memcpy_arm` (instructions.jl:91-234):
| # | Line | Check |
|---|------|-------|
| 1 | 94 | addrspace 0 |
| 2 | 111-120 | volatile == 0 |
| 3 | 123-127 | N is ConstantInt |
| 4 | 135 | N == 0 → return [] |
| **5** | **142-151** | **neither op is global** |
| 6 | 154-166 | both ops trace to alloca |
| 7 | 169-173 | distinct alloca roots |
| 8 | 180-189 | both elem_w are integers |
| 8b | 194-197 | dst_ew == src_ew |
| 8c | 202-205 | N is multiple of ew_bytes |

**Restructure for doih:** predicate 5 splits into 5a (DST cannot be global — keep rejecting) and 5b (SRC may be global, take a different lowering branch).

New cascade:
| # | Description |
|---|-------------|
| 1-4 | unchanged |
| **5a** | DST is not global (keep existing reject; "global-pointer dst memset/memcpy" is out of scope and a writable target makes no sense for a constant). |
| **5b** | If SRC is global → branch to **global-src arm**. If SRC is not global → fall through to predicate 6. |
| 6-8c | unchanged (only fires on non-global src) |

**New failure modes (all fail loud per §1):**

a. **Global src is not in `parsed.globals`.** Either (i) extraction skipped it (struct, GlobalAlias, non-integer-array initializer) or (ii) the global is `external` (declaration-only, no initializer). Error message: `"global @<name> is not extractable as a constant byte stream (likely <reason>); tracked in Bennett-8bys."`

b. **Global src elem_w ≠ dst alloca elem_w.** doih's MVP scope should restrict to **dst_ew == src_global_ew**, mirroring predicate 8b's same-width invariant.

c. **N (byte count) is not a multiple of `src_global_ew/8`.** Mirror predicate 8c on the global side.

d. **N exceeds available bytes in the global.** `length(data) * (gw/8) < N` — would read past the global's end. Fail loud.

### Lowering shape (with example IR)

**Reuse the Bennett-9nwt case C pattern (post-ixiz form):** K element-granular `IRPtrOffset + IRStore(iconst, dst_ew)` pairs where each `iconst` is the static byte/element value from `parsed.globals[gname].data`.

**Why this works:** the global's bytes are compile-time-known constants. We don't need to do anything QROM-shaped (despite the bead title) because there's no index — memcpy reads bytes 0..N-1 sequentially. The "QROM fan-out" framing in the bead title is a misnomer; QROM is for runtime-indexed lookup. For constant-offset reads we just emit static stores.

For a wider-element global (e.g., dst is `alloca i64` and global is `[4 x i64]` with values `[0x0102…08, …]`):

```
IRPtrOffset(_auto_1, ssa(:dst), 0)
IRStore(ssa(_auto_1), iconst(0x0102030405060708), 64)
IRPtrOffset(_auto_2, ssa(:dst), 8)
IRStore(ssa(_auto_2), iconst(0x090A0B0C0D0E0F10), 64)
... etc ...
```

Reuse the freshness predicate `_alloca_is_fresh` from `_handle_memset_arm` for the dst. The fresh-dst invariant matters here for the same §1 reason as 9nwt: non-fresh dst would XOR-overlay the global's bytes onto existing data and produce wrong results that `verify_reversibility` does NOT catch.

### Element-width policy

**Decision: FORCE `dst_ew == src_global_ew` for doih's MVP.** Do NOT pack bytes into wider elements.

Reasoning:
1. The post-ixiz invariant for `_handle_memcpy_arm` is uniform element-width on both sides (predicate 8b). The global-src path should inherit the same invariant.
2. The `Vector{UInt64}` returned by `_extract_const_globals` is INHERENTLY per-element-packed.
3. The acceptance fixture's `[24 x i8]` field naturally extracts as elem_w=8, matching a `[24 x i8]` dst alloca.

### Test plan

**Acceptance fixture deferred:** the literal `@anon.7665…` is a struct-typed global. doih's MVP ships synthetic-array fixtures and files `Bennett-doih-struct` for the ConstantStruct follow-up.

**Synthetic fixtures (positive):**
1. `doih_global_src_n4_i8.ll` — minimal
2. `doih_global_src_n8_i8.ll` — N>4
3. `doih_global_src_n32_i8.ll` — matches t5 byte count
4. `doih_global_src_n4_i64.ll` — wider element path

**Reject fixtures:**
5. `doih_global_dst_reject.ll` — global as dst (5a)
6. `doih_global_src_struct_reject.ll` — struct-typed global (G5 with `Bennett-doih-struct` reference)
7. `doih_global_src_external_reject.ll` — external-declaration global
8. `doih_global_src_cross_width_reject.ll` — width mismatch
9. `doih_global_src_oversize_reject.ll` — N exceeds global bytes
10. `doih_global_src_non_fresh_dst_reject.ll` — non-fresh dst

**Test file:** `test/test_doih_global_src_memcpy.jl`, ~150-200 lines.

**Peer regression sweep (MUST run):**
- test_37mt_memcpy_const_aligned.jl
- test_9nwt_memset_const.jl
- test_ixiz_wider_alloca.jl
- test_munq_arr_i8_alloca.jl
- test_lqif_memcpy_memmove_reject.jl
- test_q04a_convert_instruction_contract.jl
- test_8kno_extract_const_globals_narrowing.jl
- test_gate_count_regression.jl

### Risk register

**R1: Acceptance fixture mismatch.** The bead's literal acceptance can't be met by doih's narrow scope. File `Bennett-doih-struct` follow-up.
**R2: q04a contract test breakage.** Threading globals through `_handle_intrinsic` (not `_convert_instruction`) avoids breaking the positional-tuple check.
**R3: `_extract_const_globals` extension scope creep.** ConstantStruct support belongs in a separate bead.
**R4: Freshness check on dst.** Reuse `_alloca_is_fresh` (already-tested helper).
**R5: Element-width policy creep.** Reject byte-packing wider globals into i64 chunks; out-of-scope.
**R6: Cross-reference closed beads.** ixiz lesson: bead descriptions can be wrong; both proposers must verify.
**R7: Constraint test.** All existing 37mt positive tests must pass byte-for-byte. Branch on src-is-global BEFORE predicate 6.

## Implementation sketch

**File 1: `src/extract/instructions.jl`**
- New helper `_global_ref_or_nothing(val) -> Union{Nothing, _LLVMRef}` (~5 LOC).
- New helper `_global_name(ref) -> Symbol` (~3 LOC).
- Modify `_handle_memcpy_arm` signature (line 91) — add `globals`.
- Modify predicate 5 (lines 137-151) — split 5a/5b.
- New helper `_handle_memcpy_arm_global_src(...)` — implements the global-src arm.
- Modify `_handle_intrinsic` signature — add `globals` as 7th positional arg.

**File 2: `src/extract/module_walk.jl`**
- Modify line 190: pass `globals` kwarg.

**File 3: `src/extract/instructions.jl` (`_convert_instruction`)**
- Add kwarg `globals=Dict{Symbol,Tuple{Vector{UInt64},Int}}()`. Pass to `_handle_intrinsic`.

**File 4: `test/test_doih_global_src_memcpy.jl`** (new) ~180 LOC.

**File 5: `test/runtests.jl`** — register after ixiz.

**File 6: `test/fixtures/ll/doih_*.ll`** — 10 fixtures.

**File 7: `test/test_q04a_convert_instruction_contract.jl`** — likely update.

**Estimated footprint:** ~120 LOC src + ~180 LOC test + 10 fixtures (~150 LOC). Well within 3+1 sub-bead scope.
