# CW-D2/D3 — type-tag + GC-allocation cluster — session handoff (2026-06-20)

Next-session starting point. Written after landing CW-D2 levers 1–2. The
fdict-e2e road has crossed from mechanical extractor levers into the
substantive "model Julia's typed GC allocation reversibly + deterministically"
regime. This doc is the design seed.

## What landed this session (both pushed, full Pkg.test green)
- **Bennett-ares** (lever 1, `c552f70`'s parent `f9e485b`): VM-gated U14 atomic
  relaxation. Band `{NotAtomic,Unordered,Monotonic,Acquire,Release}` accepted
  under `ptr_cells`; circuit byte-identical. `src/extract/instructions.jl`.
- **Bennett-zf5v** (lever 2, `c552f70`): drop `llvm.julia.gc_preserve_begin/end`
  token intrinsics under `ptr_cells` + allowlist `julia.get_pgcstack` in
  `julia_set.jl` closed-world check. Root advanced past gc_preserve.

Both were full 3+1. The skepticism discipline (Rule 10) twice overturned a
proposer/bead premise — see the worklog (chunk 087) and the two consensus docs
in `docs/design/Bennett-ares-*.md` / `Bennett-zf5v-*.md`.

## CRITICAL correction for the next agent (avoid the trap I hit)
**The closed-world producer extracts bodies at `optimize=FALSE`** (`extract_parsed_ir_set_from_julia`,
julia_set.jl:185/231/261), NOT the `optimize=true` default of bare `extract_parsed_ir`.
Probe walls at `optimize=false, ptr_cells=true` or you will chase phantom walls
(the get_pgcstack `movq %fs:0` inline-asm wall is an `optimize=true` artifact;
at optimize=false get_pgcstack is the clean `@julia.get_pgcstack()` intrinsic).
Bennett-6x2w was closed *superseded* for exactly this reason.

## Current wall-map (optimize=false, ptr_cells=true, post-lever-2)
| path | next wall | bead |
|---|---|---|
| **ROOT** `fdict_d1b` | `ptrtoint ptr→i64` of a TYPE-OBJECT global | **Bennett-iwo9** |
| `setindex!` | `insertvalue { ptr, ptr }` memoryref aggregate | Bennett-6bu3 |
| `rehash!` | `llvm.memcpy` dst not alloca-backed | Bennett-8bys |
| `ht_keyindex2_shorthash!` | sret-`llvm.memcpy` (optimize=false form) | (sret/preprocess) |
| (all, later) | 2× GC-safepoint `fence`/callee | Bennett-3ptu |

## The crux all paths converge on (the real work ahead)
`gc_alloc_obj` (typed box alloc) + `jl_alloc_genericmemory_unchecked` (Memory
backing) + the **type-object globals** they consume. The `ptrtoint` wall
(Bennett-iwo9) is the entry: its operand is
`@"+Main.Base.Dict#85.jit" = inttoptr(i64 129722337912592 to ptr)` — the
absolute *host-process JIT address* of the `Dict` type object, loaded then
`ptrtoint`'d to pass as the type-tag arg to `gc_alloc_obj`.

**Soundness landmine:** a naive `ptrtoint`→cell passthrough injects a
NON-DETERMINISTIC host address into the deterministic reversible VM — the exact
hazard `module_walk.jl:733` `:addr`-rejection guards. So `ptrtoint` is NOT a
mechanical identity cast; it requires modeling these interned type-object
globals as **deterministic VM type-tag constants** (a stable small ID per type),
= the **CW-D3** workstream (`bennettvm-416r.13`, interned-global initializer
extraction), interlocked with **CW-D2** `gc_alloc_obj`/`genericmemory`
(`bennettvm-416r.12`).

## Recommended approach (cross-repo design phase)
This is genuinely cross-repo and architectural — design before implementing:
1. **Bennett.jl side:** how to recognize the `@"+Type#N.jit" = inttoptr(const)`
   type-object globals and emit them as deterministic type-tag cells (a tag
   table in `ParsedIR.globals`?), so `load`→`ptrtoint`→`inttoptr` of a type tag
   lowers to a stable VM constant, not a host address. Reuse/extend
   `_extract_const_globals` + `constexpr.jl` (`:addr` provenance) — but make the
   tag DETERMINISTIC (content-addressed by type, not the raw JIT address).
2. **BennettVM side:** ingest `gc_alloc_obj(current_task, size, type_tag)` and
   `jl_alloc_genericmemory_unchecked(ptls, n, type)` onto the existing reversible
   heap arena (CW-A2 `bennettvm-416r.3` already shipped malloc/calloc/realloc/
   free/memcpy/memmove/memset + the 7-intrinsic boundary). The type_tag is
   metadata the VM stores but need not interpret for reversibility.
3. Sequence the levers: type-tag-global modeling → `ptrtoint/inttoptr`
   passthrough (now sound) → `gc_alloc_obj` → `genericmemory` → then the
   per-callee aggregate/memcpy walls (6bu3, 8bys, sret) → `fence` drop (3ptu).

Suggest a `Workflow` design pass (scout both repos' type/alloc modeling, judge
2–3 type-tag representations, pick) before the first implementation 3+1.

## Open beads (all filed this session unless noted)
- `Bennett-iwo9` (P1) — ptrtoint/type-tag (root, CW-D3 entry) — has the full ground-truth note.
- `Bennett-3ptu` (P2) — fence-as-noop under ptr_cells.
- `Bennett-6bu3` (P2, pre-existing) — StructType insertvalue (setindex! successor; noted).
- `Bennett-8bys` (P3, pre-existing) — memcpy dst-not-alloca (rehash! successor).
- `bennettvm-416r.12` (CW-D2) / `416r.13` (CW-D3) — the BennettVM-side cluster.
- `Bennett-6x2w` — CLOSED superseded (get_pgcstack was an optimize=true phantom).

## BennettVM-side note (the "both repos" picture)
The synergy is currently *sequential*: every remaining wall is Bennett.jl-side
(extraction); BennettVM can't consume a closure member until it fully extracts.
The CW-D3 cluster is where BennettVM re-enters (typed-alloc + type-tag ingest).
If a parallel BennettVM track is wanted before then, self-contained unblocked
units exist: `bennettvm-6db` (P0, push! delta reversibility), `bennettvm-416r.4`
(globals-as-VM-segments, now unblocked by CW-D1).
