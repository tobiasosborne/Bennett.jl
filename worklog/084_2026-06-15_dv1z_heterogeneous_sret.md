# 084 — 2026-06-15 — Bennett-dv1z — heterogeneous bits-struct sret

**Bead:** `Bennett-dv1z` (the sret MVP limit) + cross-repo `bennettvm-x3t0`. On the
CW-D closed-world fdict runway (one of `ht_keyindex2`'s walls), but **independently
valuable**: it flips 3 previously-rejected returns to *compiling*. CORE change.

## What landed
sret extraction extended from `[N x iM]` homogeneous arrays to **heterogeneous
bits-structs** (`{i64,i8}`, `{i8,i64}`, `{i32,i8,i64}`, …):
- **NEW IR node `IRInsertBits`** (`ir_types.jl`) — inserts a `val_width`-bit value at
  an absolute BIT offset in a `total_width`-bit packed aggregate (IRInsertValue can't:
  it hardcodes a uniform `elem_width`, so it physically cannot place an `i8` at bit 64).
- **`lower_insertbits!`** (`aggregate.jl`) — same CNOT-aliasing gate class as
  `lower_insertvalue!` (no new gate kinds, no gate-count perturbation) + dispatch (`types.jl`).
- **sret extractor** (`sret.jl`): 3-way `_detect_sret` (Array → homogeneous verbatim /
  Struct → new arm / else reject loud); `_sret_struct_fields` (per-field
  `(byte_offset, width_bits)` via `LLVMOffsetOfElement`; rejects packed / non-integer /
  bad-width fields loud); hetero scalar-store branch (exact `findfirst(offset==)`, NOT
  `÷eb`); `_synthesize_sret_bits` (IRInsertBits chain at contiguous bit offsets in field
  order); `module_walk.jl` dispatch + `ret_width=sum(widths)` / non-uniform `ret_elem_widths`.

## Scope correction (the +1 / synthesis caught it)
This is **NOT a pure front-end change** — it requires the new IR node + its lowering
(a Proposal-A claim that a flat IRRet could be synthesized "through the existing
mechanism" was proven false: the IRRet operand is a single SSA value, and the only
existing concatenator is the uniform-width IRInsertValue chain). So it touches
`ir_types.jl` + `lowering/` — covered by the 3+1, gated by the full suite.

## Correctness crux (hostile-review-verified)
Two coordinate systems must NOT be conflated: **LLVM byte offsets** (padded; used ONLY
to map a store back to its field index) vs the **packed bit offset** in the synthesized
return (field-order cumulative widths; padding dropped). The code keys slot index,
packed bit offset, and `ret_elem_widths` ALL on field-declaration order; byte offsets
only drive store→slot matching. Traced clean for `{i64,i8}` AND the maximally-divergent
reversed `{i8,i64}` (field1 at BYTE 8 but packed BIT 8) and `{i32,i8,i64}`. `ret_width`
is the packed sum (72/96/104), never the padded ABI size (128). Wire order field0-low/
field1-high, verified element-by-element via `simulate` over typemin/typemax/negatives.

## Runway finding (necessary-but-NOT-sufficient for fdict)
`ht_keyindex2_shorthash!` (the Julia/fdict consumer) hits TWO MORE walls beyond
heterogeneity — 5 `ret` sites (`Bennett-jghk`, multi-return sret) + a recursive
sret-returning self-call+memcpy (`Bennett-59zi`) — BOTH orthogonal to heterogeneity. And
`HashMap::new` (Rust T5) is permanently out of scope: a nested 48-byte struct with
pointer/`{i64,i64}` fields → stays `:dv1z_sret_reject` (the `test_land_ptrfield_struct`
outcome the 083 fix already accepts; comment-only update here). So dv1z does NOT close
fdict; it's one wall + a general capability.

## Method + hostile review
3+1 design pass → Opus implementer (probe-verified the O1 IR + datalayout offsets first,
Rule 9) → +1 + hostile review. Hostile findings: **no BLOCKER**; **SF-1 fixed** (the
typed-element-GEP arm used `eb=0` on the hetero path → silent offset-0; now rejects loud
per §1 — hetero structs only see i8 byte-GEPs); N-1 docstring already correctly scoped;
N-2 (a width∉{8,16,32,64}-field reject fixture) noted, branch read-verified, low value.

## Gates
Full `--check-bounds` `Pkg.test` (`b0flip1k7`, ~111 min) ran with `IRInsertBits` present:
**688850 pass, 2 fail, 0 error, 2 expected-broken**. The 2 failures were BOTH
`test_q04a_convert_instruction_contract.jl` (the IRInst-inventory contract — it pins the
exact subtype count; `IRInsertBits` is the 20th). That contract test working as designed
(forces deliberate acknowledgment of a new IRInst). Fixed (19→20, +`:IRInsertBits`;
noted that IRInsertBits is sret-synthesis-only so the `_convert_instruction` return-Union
bound is unaffected) → q04a 9/9 in isolation. Since the fix is test-expectation-only and
the full suite validated all other 688850 assertions green WITH IRInsertBits present, the
committed state is full-green; no redundant 111-min re-run. gate-count regression 39/39
byte-identical. New `test_dv1z_hetero_sret.jl` 142/142; 3 reject→positive flips
(`test_sret`/`test_0zsk`+new ptr-field reject row/`test_0c8o`).

## Follow-ups filed
`Bennett-jghk` (multi-return sret), `Bennett-59zi` (recursive sret-self-call+memcpy),
`Bennett-fd1r` (latent `narrow.jl:45` `elem_count` vs `n_elems` bug), `bennettvm-x3t0`
(BVM ingest of IRInsertBits + non-uniform `ret_elem_widths` — comment).
