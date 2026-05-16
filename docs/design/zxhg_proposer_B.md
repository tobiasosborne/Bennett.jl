# Bennett-zxhg proposal — Proposer B

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposers A and B worked independently — neither saw the other's output.)

## Verification of bead claims

**Claim 1 — ConstantStruct flattening:** PARTIALLY true. Padding insertion is needed for non-packed structs. **Either (a) restrict to packed (`<{...}>`), or (b) use `LLVM.offsetof(dl, struct_ty, field_idx)` to compute each field's offset including padding.** t5 corpus uses ONLY packed structs. Recommend (b) via `offsetof` so we don't ship a packed-only handler that has to be revisited.

**Claim 2 — ptr is 8 bytes:** TRUE on x86_64 per t5 datalayout `e-m:e-...-i64:64-...` (no `p:` clause = default 64-bit ptr). **Don't hardcode — use `LLVM.pointersize(dl, addrspace=0)`.**

**Claim 3 — hard-reject is no information loss:** VERIFIED. The two memcpy-with-global-src sites in t5_tr2_hashmap.ll (lines 153 + 4183) reference the same `@anon.7665…0` and feed memcpy → memcpy → sret return slot. Zero-substituted ptr bytes would silently produce wrong outputs. **Hard-reject is correct.**

**Claim 4 — G6 same-width interaction:** TRUE and load-bearing. Heterogeneous-width structs cannot have a single `elem_width`. **Forced byte-granular normalization.**

**Surface survey of t5_tr2 (lines 11-52):**
- 24 pure `[N x i8]` arrays (pre-zxhg supported)
- 14 `<{ ptr, [16 x i8] }>` instances — direct ptr args to panic, NEVER memcpy src
- 1 `<{ ptr, [24 x i8] }>` (`@anon.7665…0`) — the acceptance fixture, used at lines 153 + 4183 as memcpy src
- 2 `<{ [24 x i8], ptr, ptr }>` + 1 `<{ [24 x i8], ptr, ptr, ptr }>` — vtable shapes, NOT memcpy src
- 2 `<{ [8 x i8], [8 x i8] }>` — pure-integer struct, consumed by direct `load i64`, NOT memcpy

**Take-home:** for t5 acceptance, only `<{ ptr, ... }>` matters as memcpy src — exactly the hard-reject case. No t5 fixture requires positive struct extraction for memcpy. Pure-integer struct extraction lands in `lower_var_gep!` consumer, NOT `_handle_memcpy_global_src`.

## Design

### Ptr-field policy: HARD-REJECT, breadcrumb naming `Bennett-zxhg-ptrfield`

Reasoning:
1. **No silent miscompile risk (CLAUDE.md §1).** Zero-substitution produces wrong outputs that `verify_reversibility` does not catch.
2. **T5 acceptance fixture genuinely needs the breadcrumb path, NOT the extraction path.** Bead's "compiles end-to-end OR fails loud" explicitly admits both branches.
3. **Option 3 (file sub-bead) IS what hard-reject does** — option 1 IS the breadcrumb that names option 3's bead.
4. **Surface bounded.** Covers one well-defined shape.
5. **Forward-compatible.** Future bead can flip hard-reject to materialization without test churn.

**Rejected option 2 (zero-substitute):** even if downstream never reads ptr bytes, we can't prove this at extraction time.

### `_extract_const_globals` extension

At line 269, replace single `init isa LLVM.ConstantDataArray || continue` with dispatch:

```julia
if init isa LLVM.ConstantDataArray
    # existing code
elseif init isa LLVM.ConstantStruct
    ty = LLVM.value_type(init)
    ty isa LLVM.StructType || continue
    bytes = _flatten_struct_to_bytes(init, ty, dl, 0)
    bytes === nothing && continue
    out[Symbol(LLVM.name(g))] = (UInt64.(bytes), 8)
elseif init isa LLVM.ConstantAggregateZero
    ty = LLVM.value_type(init)
    (ty isa LLVM.StructType || ty isa LLVM.ArrayType) || continue
    total_bytes = LLVM.abi_size(dl, ty)
    out[Symbol(LLVM.name(g))] = (zeros(UInt64, total_bytes), 8)
else
    continue
end
```

**New helper `_flatten_struct_to_bytes(init, struct_ty, dl, depth) -> Union{Nothing, Vector{UInt8}}`** (~80-100 LOC):

a. `total_bytes = LLVM.abi_size(dl, struct_ty)`.
b. `bytes = zeros(UInt8, total_bytes)`.
c. For each field index i:
   - `field_off = LLVM.offsetof(dl, struct_ty, i)` (HONORS ABI PADDING for non-packed!)
   - `field_val = LLVM.operands(init)[i + 1]`
   - `field_ty = LLVM.elements(struct_ty)[i + 1]`
   - Dispatch on field_ty:
     - `IntegerType` (8/16/32/64): LSB-first byte pack
     - `ArrayType<IntegerType>`: walk via `LLVMGetElementAsConstant`, LSB-first pack each element
     - `ConstantAggregateZero` on sub-field: bytes already zero — nothing to do
     - `ConstantStruct` (nested): recurse, splice at field_off; if recursion returns nothing, propagate
     - Anything else (PointerType, FloatType, VectorType, undef): return `nothing`
d. Sanity check via `LLVM.ispacked` belt-and-braces.

**Pre-extraction datalayout:** `dl = LLVM.datalayout(mod)` at top of `_extract_const_globals` (line 245). Pass into helper. Single LLVM C-API call per module.

**Endianness assertion:** at top of `_flatten_struct_to_bytes`, assert `LLVM.byteorder(dl) == LLVM.API.LLVMLittleEndian`. Cheap insurance.

### Element-width policy: byte-granular `elem_width=8`

Heterogeneous-width structs cannot normalize to any single non-byte width. Byte-granular preserves dict shape. doih's G6 then requires `dst_ew==8` for struct-derived globals — exactly the dominant shape.

`lower_var_gep!` consumer: existing same-width check at aggregate.jl:273 throws `DimensionMismatch` for cross-width access — correct loud rejection.

### Naming / downstream

**No special naming.** `Symbol(LLVM.name(g))` as today.

**Downstream audit:**
- `_handle_memcpy_global_src` G5 check `haskey(globals, gname)` flips FAIL→PASS for pure-integer structs. G6's `dst_ew==gw` enforces `dst_ew==8`. G7's `ew_bytes=1` makes alignment checks trivial. **No code change** in `_handle_memcpy_global_src`.
- **CONSEQUENCE:** the doih G5 message at instructions.jl:483-493 needs a 4-line WORDING tweak — the "(a) ConstantStruct" case should now read "ConstantStruct with non-integer field (e.g. ptr-typed), tracked in `Bennett-zxhg-ptrfield`."
- `lower_var_gep!` (aggregate.jl:273): existing check handles correctly — no code change.
- ParsedIR.globals dict shape unchanged.
- **Q04a contract test unchanged.** Zxhg touches `_extract_const_globals` only.

### Test plan

**Positive fixtures (extraction + lowering succeeds, verify_reversibility passes):**

1. `zxhg_struct_int_field.ll` — REQUIRED acceptance. `<{ i8, [3 x i8] }>`. memcpy 4 bytes to `alloca [4 x i8]`, load `dst[2]`.
2. `zxhg_struct_two_i8_arrays.ll` — `<{ [8 x i8], [8 x i8] }>` (mirrors t5_tr2 @anon.7665…1). 16 bytes.
3. `zxhg_struct_mixed_widths.ll` — `<{ i64, i32, [4 x i8] }>` (16 bytes). Validates LSB-first packing + offset computation.
4. `zxhg_struct_aggregate_zero.ll` — `<{ [4 x i8], [4 x i8] }> zeroinitializer`. ConstantAggregateZero arm.
5. `zxhg_struct_non_packed.ll` — `{ i8, i32 }` (non-packed). ABI-padding insertion path.

**Reject fixtures:**

6. `zxhg_struct_ptr_field_reject.ll` — MIRRORS t5_tr2_hashmap.ll:153: `<{ ptr, [24 x i8] }>`. G5 message names `Bennett-zxhg-ptrfield`.
7. `zxhg_struct_nested_struct_reject.ll` — `<{ <{ i8, ptr }>, i8 }>`. Verifies recursive rejection propagates.
8. `zxhg_struct_float_field_reject.ll` — `<{ i8, float }>`. FloatType reject.
9. `zxhg_struct_too_wide_int_reject.ll` — `<{ i128, i8 }>`. Verifies the 64-bit-max policy.

**T5 end-to-end smoke (NEW):**

10. Compile t5_tr2_hashmap.ll's `HashMap::new` function (line 145+). EXPECT fail-loud with `Bennett-zxhg-ptrfield` naming `@anon.7665…0`. Pin via `@test_throws` substring.

**Existing test flip:** rename `doih_global_src_struct_reject.ll` → `doih_global_src_struct.ll` (drop `_reject`). Flip `test_doih_memcpy_global_src.jl:133` to positive. (Pick option α — rename + flip, mirrors ixiz pattern.)

**Peer regression sweep:** doih (77), 8kno, 37mt (86), 9nwt (87), ixiz (53), munq (69), lqif (12), q04a (9), gate-count-regression (39).

### Risk register

**R1 — Silent miscompile via zero-substitution.** Mitigation: hard-reject is the chosen policy.
**R2 — ABI padding for non-packed.** Mitigation: use `LLVM.offsetof` (datalayout-aware) rather than running-sum.
**R3 — Endianness.** Mitigation: assert little-endian at helper entry.
**R4 — `_extract_const_globals` swallow regression.** Mitigation: new arm lives INSIDE existing try/catch.
**R5 — ConstantAggregateZero polymorphism.** Mitigation: explicit dispatch arm (case 3) + fixture #4.
**R6 — Nested struct recursion depth.** Mitigation: depth=8 limit.
**R7 — ConstantArray vs ConstantDataArray ambiguity.** Mitigation: factor a `_flatten_const_array_to_bytes(arr, dl)` helper handling both.
**R8 — Bead-vs-source drift (CLAUDE.md §10).** Bead says "per-element packed"; honest interpretation is "byte-granular `elem_width=8`".
**R9 — Drive-by ptr-typed global initializer kinds.** Out of scope; future sibling bead.

## Implementation sketch

**File 1: `src/extract/module_walk.jl`** — primary surface
- Line 244 signature unchanged.
- Line 245: add `dl = LLVM.datalayout(mod)` + endianness assert.
- Lines 268-269: restructure into if/elseif/else dispatch on initializer kind (3 arms).
- After 287: new helpers `_flatten_struct_to_bytes` + `_flatten_const_array_to_bytes` (~80-100 LOC each).

**File 2: `src/extract/instructions.jl`** — MESSAGE-ONLY edit
- Lines 483-493 (G5 wording): "(a) ConstantStruct with non-integer field — tracked in `Bennett-zxhg-ptrfield`".
- **No logic change.** G5 check is still `haskey(globals, gname)`.

**File 3: `test/fixtures/ll/zxhg_*.ll`** (NEW, 9 fixtures)

**File 4: `test/fixtures/ll/doih_global_src_struct_reject.ll`** — RENAME to `doih_global_src_struct.ll`.

**File 5: `test/test_doih_memcpy_global_src.jl:133-145`** — flip testset to positive (~25 line edit).

**File 6: `test/test_zxhg_struct_global.jl`** (NEW, ~200 LOC, 9 testsets).

**File 7: `test/runtests.jl`** — register after doih.

**File 8: `test/test_8kno_extract_const_globals_narrowing.jl`** — VERIFY (don't edit) static substring inspection still passes. Keep helper SEPARATE so 8kno is stable.

**Estimated footprint:** ~110 LOC src + ~25 LOC test edit + ~200 LOC new test + ~150 LOC fixtures.

**Sequencing (RED-GREEN per CLAUDE.md §3):**
1. Write test + 9 fixtures. RED: positives fail (silently skipped), rejects wrong-breadcrumb.
2. Implement `_flatten_struct_to_bytes` + dispatch arm. Positives green; rejects still wrong-breadcrumb.
3. Edit G5 message. All zxhg green.
4. Rename fixture + flip doih testset. doih 77/77.
5. Peer regression sweep.
6. T5 smoke.

## Summary

Pick option 1 (hard-reject ptr fields), justified by silent-miscompile risk per CLAUDE.md §1 and the t5 corpus survey. Extend `_extract_const_globals` with three dispatch arms (existing ConstantDataArray + new ConstantStruct + new ConstantAggregateZero-of-struct). New helper `_flatten_struct_to_bytes` uses `LLVM.offsetof` and `LLVM.abi_size` to honor ABI padding (covering both packed AND non-packed in one design) and uses `LLVM.pointersize(dl)` rather than hardcoding 8. Normalize ALL struct-derived dict entries to byte-granular `elem_width=8`. Pure G5 message refinement at instructions.jl:483-493 — no logic change, no new threading. The existing `doih_global_src_struct_reject.ll` (pure-integer `<{ i8, [3 x i8] }>`) renames to `doih_global_src_struct.ll`; the doih testset flips to positive (mirrors ixiz pattern). New test file with 9 fixtures + 1 t5 smoke test asserting precise `Bennett-zxhg-ptrfield` breadcrumb fires for the acceptance fixture.

## Blockers / assumptions

- **ASSUMPTION (ptr-field policy):** acceptance fixture goes through fail-loud branch by design. Bead text explicitly admits both branches.
- **ASSUMPTION (byte-granular dict):** pure-i64-field struct + cross-width var-GEP hits DimensionMismatch — follow-up bead, not zxhg blocker.
- **ASSUMPTION (little-endian only):** runtime assert; big-endian out of scope per current `Project.toml`.
- **ASSUMPTION (q04a contract):** unchanged — `_extract_const_globals` only touched.
- **NO BLOCKERS** — all required LLVM.jl APIs verified to exist.
