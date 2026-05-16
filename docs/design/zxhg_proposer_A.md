# Bennett-zxhg proposal — Proposer A

(Captured 2026-05-16 from Plan-Opus subagent under 3+1 protocol per CLAUDE.md §2.
Proposers A and B worked independently — neither saw the other's output.)

## Verification of bead claims

**Claim A — ConstantStruct flattening:** PARTIAL. Padding matters. Non-packed `{ i8, i64 }` has 7 bytes of padding for i64:64 alignment. Field survey of `build/t5_tr2_hashmap.ll`: 20/20 packed; tr1: 5/5; tr3: 6/6. **Scope-tighten: zxhg accepts ONLY packed ConstantStructs** (non-packed deferred).

Subtlety: `<{ ..., [24 x i8] zeroinitializer }>` — the inner field is `ConstantAggregateZero`, not `ConstantDataArray`. Must handle that fan-out.

**Claim B — ptr is 8 bytes:** TRUE on x86_64 per t5 datalayout. Target-dependent. **Don't hardcode 8 — read datalayout.**

**Claim C — hard-reject is no information loss:** TRUE for safety. Zero-substitution would silently corrupt pointer dereferences downstream; `verify_reversibility` can't catch it.

**Claim D — G6 same-width interaction:** CRITICAL TENSION. For `<{ i64, [8 x i8] }>` (hypothetical pure-integer mixed-width), no honest single elem_width exists. **Dict shape forces byte-granular normalization (`elem_width=8`).**

**Claim E — downstream consumers:** PARTIALLY TRUE. `_handle_memcpy_global_src` and `lower_var_gep!` will require dst to be `alloca i8` / `[N x i8]` for struct-derived globals. That's exactly the t5_tr2:153 acceptance shape.

## Design

### Ptr-field policy: HARD-REJECT

All non-integer/non-array-of-integer field types (ptr, float, vector, nested non-packed, opaque) hard-reject with `Bennett-zxhg-nonintegerfield` (or `Bennett-zxhg-ptr` for the ptr-specific case). Survey: 31 instances of `<{ ptr, [N x i8] }>` across t5_tr1/2/3 — all Rust panic-Location ABI. Hard-reject is strictly better diagnostic than today's silent-skip.

Don't pre-file `Bennett-zxhg-ptr` per CLAUDE.md §11; let the breadcrumb name it as a future bead ID.

### `_extract_const_globals` extension

After line 270, add dispatch on initializer kind:
- `ConstantDataArray` — existing path
- `ConstantStruct` (packed only) — new arm calling `_flatten_struct_to_bytes`
- `ConstantAggregateZero` on StructType — companion arm (all-zero fast path)

**New helper `_flatten_struct_to_bytes(init, rejected_globals, gname, depth=0) -> Union{Nothing, Vector{UInt8}}`** (~80 LOC):

Walk `LLVM.operands(init)` in source order. Dispatch on field type:
- `ConstantInt + IntegerType` (8/16/32/64): little-endian byte pack
- `ConstantDataArray + ArrayType<IntegerType>`: append bytes
- `ConstantAggregateZero` on ArrayType or IntegerType: append zero bytes
- `ConstantStruct`: recurse (depth limit 8)
- ANYTHING ELSE: return `nothing` AFTER appending diagnostic to `rejected_globals[gname]`

### Element-width policy: byte-granular `elem_width=8`

Forced by mixed-width-field structs. Trade-off: pure-i64-fielded structs lose natural `elem_width=64`, must memcpy into `[N x i8]`. Zero T5 instances; not worth a separate bead today.

### Naming / downstream

**Diagnostic-record sidecar:** new module-walk-scoped `rejected_globals::Dict{Symbol, String}` populated during extraction. Threaded as a KWARG (with empty-dict default) through `_convert_instruction` → `_handle_intrinsic` → `_handle_memcpy_arm` → `_handle_memcpy_global_src`. At G5 (instructions.jl:483), if `rejected_globals[gname]` exists, APPEND it to the error message. Q04a contract preserved via kwarg-with-default.

`_extract_const_globals` returns `(globals, rejected_globals)` tuple.

### Test plan

9 fixtures: 6 positive + 3 reject covering: int-field-only struct, zeroinit inner field, three-i8-fields, nested-packed, i64-field, whole-struct-aggregate-zero (positive); ptr-field reject, float-field reject, non-packed reject.

Existing doih test flip: `test/test_doih_memcpy_global_src.jl:133` "ConstantStruct global rejects" → flip to positive (the fixture is pure-integer `<{ i8, [3 x i8] }>` which now extracts).

T5 acceptance: compile t5_tr2_hashmap.ll:153 entry, assert fail-loud with `Bennett-zxhg-ptr` + "field 0" + "ptr" in message.

Peer sweep: doih, 8kno, 37mt, 9nwt, ixiz, munq, lqif, q04a, gate-count-regression.

### Risk register

- **R1**: Non-packed silently rejected → diagnostic gap. Mitigation: rejected_globals records "non-packed struct" reason.
- **R2**: ConstantAggregateZero on whole struct type vs ConstantStruct dispatch. Mitigation: explicit fixture #6 forces verification.
- **R3**: Datalayout-dependent ptr width. Don't mention bit-width in error message; just "type `ptr` (no Bennett wire semantics)".
- **R4**: Recursion depth on adversarial nested structs. Limit at 8.
- **R5**: `lower_var_gep!` byte-granular var-GEP into structs now succeeds. Flag in worklog.
- **R6**: q04a contract test. Kwarg-with-default; verify pass.
- **R7**: Bead acceptance ambiguity. Explicitly pick "fails loud" branch per safety.
- **R8**: Drive-by struct globals as memcpy DST. Out of scope; keep dst-as-global rejected.
- **R9**: Float/vector field types in real corpus. Zero hits; `Bennett-zxhg-nonintegerfield` catch-all.

## Implementation sketch

1. `src/extract/module_walk.jl:244`: extend return type to `(out, rejected_globals)`. Dispatch on init kind at line 269.
2. New `_flatten_struct_to_bytes` helper (~80 LOC) before line 244.
3. `module_walk.jl:58`: destructure `(globals, rejected_globals)`.
4. `module_walk.jl:190`: pass `rejected_globals` kwarg.
5. `src/extract/instructions.jl`: add `rejected_globals` kwarg to `_convert_instruction`, `_handle_intrinsic`, `_handle_memcpy_arm`, `_handle_memcpy_global_src`. Refine G5 message at line 483.
6. `src/ir_types.jl:356`: update docstring.
7. `test/test_doih_memcpy_global_src.jl:133`: flip testset.
8. `test/test_zxhg_struct_global.jl` (NEW, ~180 LOC, 9-12 testsets).
9. `test/runtests.jl`: register after doih.
10. `test/fixtures/ll/zxhg_*.ll` (8-9 new fixtures).

**Estimated footprint:** ~110 LOC src + ~180 LOC test + ~9 fixtures.

## Summary

zxhg extends `_extract_const_globals` with new ConstantStruct + ConstantAggregateZero-on-StructType arms. New helper `_flatten_struct_to_bytes` recursively walks fields; integer / array-of-integer fields flatten to byte stream; everything else hard-rejects via returning nothing + recording diagnostic in new `rejected_globals` sidecar dict. Packed-only MVP (31/31 t5 globals are packed). Byte-granular `elem_width=8` normalization (forced by mixed-width fields). New `rejected_globals` kwarg threaded through dispatch chain (q04a contract preserved via kwarg-with-default). Doih test flip required for pure-integer struct that now extracts.

## Blockers / assumptions

- **PACKED-ONLY scope**: field survey backs this; non-packed deferred.
- **Hard-reject ptr** per safety; option 2 (zero-substitute) risks silent miscompile.
- **Byte-granular dict** the only honest representation for mixed-width.
