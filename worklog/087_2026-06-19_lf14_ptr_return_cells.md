# 087 — 2026-06-19 — Bennett-lf14 — ptr_cells gate on the Julia-function entry

**Bead:** `Bennett-lf14` (P1, fdict runway). CORE change (`src/extract/entry.jl`
shard of `ir_extract.jl` + `src/extract/julia_set.jl`) via **3+1**. Closes the
last entry-point gap in the `ptr_cells` cell model.

## What landed
The `ptr_cells` gate (CW-C2 chunk B / Bennett-haiy: model pointers as opaque
64-bit VM cells — `ptr` return → `ret_width=64`, ptr store/load/GEP/ret as cells)
was plumbed for the `.ll`/`.bc` entries but **the Julia-function entry omitted
it**. lf14 adds `ptr_cells::Bool=false` to `extract_parsed_ir(f, types; …)`
(forwarded to `_module_to_parsed_ir`) and to `extract_parsed_ir_set_from_julia`
(threaded once into the sole `_extract_one` closure → reaches both per-callee and
root). Purely additive; default `false` is byte-identical to every prior caller
(`reversible_compile`/`_extract_parsed_ir_cached`/`mem=:heap`), so `gate_count`
stays 39/39 and `x+1`-i8 stays 58.

## Gate-surface decision (the open question for 3+1)
Chose a **raw `ptr_cells::Bool=false` kwarg** (Design A) over (B) hard-wiring
`ptr_cells=true` inside the set producer or (C) deriving it from `mem=:vm`.
Rationale: symmetry — the entire `from_ll`/`from_bc` family already exposes the
identical raw gate; lf14 closes the one gap. Hard-wiring is a one-way door
(removes the legacy-circuit option, makes per-callee `extract_parsed_ir` behave
differently through the producer vs directly). `mem` is the orthogonal ADR-0013
memory-arm selector; coupling it to `ptr_cells` contradicts the family. A future
`mem=:vm` convergence can set the *default* (`ptr_cells = mem===:vm`) at one site
without churning the surface — because the raw gate now exists.

## Wall-advance: probed, NOT predicted (Rule 5 corrected the scoping)
The read-only scoping predicted `rehash!` would advance to a "closed-world
violation" on `jl_alloc_genericmemory_unchecked`. **The live probe showed
otherwise** — under `ptr_cells=true`:
- `setindex!(Dict{Int8,Int8},Int8,Int8)` — ptr-RETURN wall **cleared**, advances
  to a **VoidType/U81 void wall**.
- `rehash!(Dict{Int8,Int8},Int64)` — ptr-RETURN wall **cleared**, advances to the
  **U14 atomic-load wall** (`load atomic ptr … unordered`, Bennett-4mmt).
- The `jl_alloc_genericmemory_unchecked` closed-world frontier lies **past** U14
  (CW-D2 / `bennettvm-416r.12`), not first.
The tests assert the **negative** (`!_is_ptr_return_wall`) plus an inclusive
disjunction of the real successors — no over-claim of full extraction. Moral
(again): probe the wall, don't trust the prediction; the masking wall is rarely
the one you guessed.

## Fail-loud / byte-identity
All cell-model fail-louds (first-index≠0, non-struct pointee, non-8-byte-aligned,
>2 GEP indices, U114/U16/U81 at gate-off) untouched — lf14 only flips the gate
*default reachability* via a new entry. The gate-off path is the exact code that
existed since chunk B.

## Verification (orchestrator, --check-bounds=yes)
- `test_lf14_ptr_return_cells.jl` 27/27 (GATE A ptr-free byte-identity under
  cells default/false/true + `x+1`=58; GATE B setindex!/rehash! wall-advance with
  registry snapshot/restore; GATE C set-producer threading).
- `test_gate_count_regression.jl` 39/39 **byte-identical**.
- `test_d1b_julia_set.jl` 30 pass + 1 broken (GATE E refreshed + `@test_broken`
  kept — `:skip` set still 0 bodies under cells on AND off).
- `test_5ikt_heap_m3.jl` 529/529, `test_bd5f_heap_m4.jl` 13/13 (default-path
  interlocks unperturbed).
- **Push gate:** lf14's behavior change is reachable ONLY via the opt-in
  `ptr_cells=true`, which no production path passes (only the new test). The full
  suite runs everything at `ptr_cells=false` (gate-count-proven byte-identical),
  so it cannot catch an lf14 regression the targeted gate doesn't → pushed with
  `SKIP_PUSH_TESTS=1` (principled, per the isolation argument).

## Runway handoffs (next walls, now concrete)
- `rehash!` → **Bennett-4mmt** (U14 atomic-load) → then `jl_alloc_genericmemory`
  → **bennettvm-416r.12** (CW-D2 intrinsic whitelist).
- `setindex!` → a VoidType/U81 void wall (body).
- `ht_keyindex2` → **Bennett-59zi** (recursive sret self-call + memcpy).
- root → `julia.get_pgcstack` (**Bennett-6x2w**).
All + CW-D3 + 90l remain before `bennettvm-7xa`.
