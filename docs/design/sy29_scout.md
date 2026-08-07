# Bennett-sy29 — DESIGN-VERIFYING SCOUT report

**Bead:** `Bennett-sy29` (P1) — "xkl frontier wall 9: push! ROOT walls at the 37mt
arena-src memcpy reject — arena-to-arena copy capability under `ptr_cells`"
**HEAD at time of scouting:** `1fea8a4` (Bennett-bvmd, landed 2026-08-06)
**Sister repo HEAD:** BennettVM.jl `84d6648`
**Scope:** verification pass only. **No `src/` or `test/` change was made; no commit.**
**Probes** (all under the session scratchpad, all run under
`julia --project --check-bounds=yes`, i.e. suite mode per CLAUDE.md §Build):
`s01_wall.jl`, `s02_dump.jl` (→ `root.ll`), `s03_seq.jl`/`s04_seq.jl`/`s05_seq.jl`/
`s06_seq.jl` (successive simulated admissions), `s07_bvm_e2e.jl` (BennettVM E2E,
42/42), `s08_route_r2.jl` (route-R2 closure), `s09_sc_cover.jl` ((SC) coverage).

---

## VERDICT UP FRONT

**REDUCED arc: scout → implementer → hostile review.** No tripwire trigger fires,
and each non-firing is *measured*, not argued:

| trigger | verdict | evidence |
|---|---|---|
| mixed-tier src/dst pairing with no clean cell-map argument | **NO** | The pairing IS mixed (byte-tier src, word-tier dst) and the cell-map argument is closed and **executed**: `s07` runs a K=2 arena-src → alloca-dst copy **and** its alloca-src → arena-dst mirror on BennettVM, oracle-exact under both L2 and L3 history regimes, with exact `unrun!`. 42/42. §4 |
| the `Bennett-21rj` (SC) gap becomes load-bearing | **NO** | 21rj is the `heap.jl` / `dict_vm` / `vector_vm` bypass. The `heap.jl` early return is gated `mem === :heap` (`module_walk.jl:409-419`); the corpus path is `mem=:auto` + `ptr_cells=true`, so `_check_scale_coherence!` runs (`module_walk.jl:688-696`). Probe `s09` proves (SC) **sees the memcpy arm's own emitted nodes**. §5 |
| a BVM src change is needed | **NO** | `s07`'s lowered program uses only `Define` / `IntrinsicGCAlloc` / `MemoryLoad` / `MemoryStore` / `StackAlloca`, all pre-existing. The streak (8) is preserved *by measurement*, not by assumption. §6 |
| genuine multi-route contest | **NO** | The two candidate routes are not co-viable. Route R2 (`IRCall(:memcpy)`, the vau9/8bys D5b void-call shape) is **CLOSED** for this program class: probe `s08` shows `lower_vm` fails loud — `_enforce_julia_heap_tier!` refuses any `IntrinsicMemcpy`/`IntrinsicMemmove` in a `gc_alloc_obj`-bearing program. §3 |

**Honest note on CLAUDE.md §2.** This touches `src/extract/instructions.jl`, part of
the split `ir_extract.jl`, so §2's letter asks for 3+1. The reduced arc still runs
three independent agents plus the orchestrator (scout / implementer / hostile
reviewer), which is the shape §2 exists to buy. The reason blind proposers would be
ceremonial here — and were **not** for foz5 and bvmd — is that the design space has
exactly one surviving route (§3) and the emission is a mirror of already-ratified,
already-shipped code (the vbv9 dst arm plus its 4y0d stamp split). The orchestrator
should overrule this if it disagrees; the cost of a full 3+1 is two proposers writing
the same document.

Everything below is delivered so the implementer starts from measured ground.

---

## 1. Wall 9 at HEAD, reproduced (probe `s01_wall.jl`)

The gated path, exactly as `test_bvmd_root_scale` (I) / `test_foz5` (W8) drive it:

```julia
_pushsy29(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end
Bennett.extract_parsed_ir_set_from_julia(_pushsy29, Tuple{Int64}; ptr_cells=true)
```

Verbatim wall:

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`_pushsy29#688e0247` (callable=_pushsy29, argtypes=Tuple{Int64}) —
ir_extract.jl: call in @julia__pushsy29_32102:%top:
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Array.size",
                                   ptr align 8 %"new::Array.size_ptr1",
                                   i64 8, i1 false)
— llvm.memcpy.p0.p0.i64: memcpy src operand is not alloca-backed (or
alloca-backed via a const-offset GEP). Same restriction as the dst case;
tracked in Bennett-8bys. (Bennett-37mt Phase 1).
```

**The rejecting predicate is Predicate 6's SRC half**, `instructions.jl:2178-2181`
(`src_root === nothing && _ir_error(...)`). It is *not* Predicate 7 (self-copy), *not*
Predicate 8 (element width), and *not* the global-src arm — `_src_reaches_global`
returns `false`, so the walk never enters `_handle_memcpy_global_src`.

**Marker verification** (probe `s01`, exact `occursin` results on the wall message):

| marker | fires | role |
|---|---|---|
| `memcpy` | **true** | positive (all six advanced files) |
| `Bennett-37mt` | **true** | positive |
| `Bennett-8bys` | **true** | incidental (the downstream-bead breadcrumb) |
| `src operand` | **true** | identifies which half of Predicate 6 |
| `Bennett-583s` | false | LOAD-BEARING NEGATIVE at wall 9 — **flips at wall 10** |
| `base-cancelling` | false | LOAD-BEARING NEGATIVE at wall 9 — **flips at wall 10** |
| `Bennett-p06b` / `gc_alloc_obj` / `BYTE-granular` | false | wall 8 stays cleared |
| `Bennett-lgzx` / `Bennett-jbko` / `Bennett-iwo9` / `memmove` | false | walls 3/5/6 stay cleared |

The four advanced markers pin exactly this wall. **The bead text is accurate** on the
wall's identity, its provenance, and its arc-shape recommendation.

### 1.1 The verbatim memcpy, and every sibling in the corpus

`_module_has_sret(root) == false` (probe `s03`), so **no `sroa`/`mem2reg` prepend
fires** — the root is walked at raw `optimize=false`. Do not assume the `_growend!`
pass pipeline here. Full root: `scratchpad/root.ll`, 317 lines.

```llvm
top:
  %"new::Array.size" = alloca i64, align 8                                   ; DST
  ...
  %"new::Array" = call ... ptr @julia.gc_alloc_obj(ptr %current_task, i64 24, ptr %4)
  ...
  %"new::Array.size_ptr" = getelementptr inbounds i8, ptr %"new::Array", i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Array.size_ptr",
                                   ptr align 8 @"_j_const#1", i64 8, i1 false)  ; vbv9 — WORKS
  ...
  %"new::Array.size_ptr1" = getelementptr inbounds i8, ptr %"new::Array", i32 16 ; SRC
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Array.size",
                                   ptr align 8 %"new::Array.size_ptr1",
                                   i64 8, i1 false)                             ; <-- WALL 9
```

* **src provenance** — `gep i8 %"new::Array", 16`, a SINGLE-index i8 GEP one hop off
  a `julia.gc_alloc_obj(_, i64 24, _)` call. `_gc_alloc_root_ref` (vbv9) resolves this
  in exactly one hop, by construction (its docstring's STEP-0c shape).
* **dst provenance** — `alloca i64`, direct, no GEP. `_alloca_elem_width_bits == 64`,
  `_alloca_reservation` → `(64, ConstOperand(1))` ⇒ **scale 8, 1 cell**.
* **size / alignment / volatility** — `i64 8` CONSTANT, `align 8` on both, `i1 false`.
  Predicates 1-5b all pass. **K = 1.**

The eight `llvm.memcpy` calls in the root body, classified (line numbers into
`root.ll`; block in brackets):

| # | line | blk | dst | src | status at HEAD |
|---|---|---|---|---|---|
| 1 | 46 | `%top` | arena `+16` | global `@"_j_const#1"` | **WORKS** (vbv9/doih) |
| 2 | 55 | `%top` | `alloca i64` | **arena `+16`** | **WALL 9 — this bead** |
| 3 | 80 | `%L16` | `alloca[9×i64] +32` | `alloca i64` | works (37mt/ixiz) |
| 4 | 82 | `%L16` | `alloca[9×i64] +40` | **loaded `ptr` (`.mem`)** | future wall — *different* provenance class |
| 5 | 87 | `%L16` | `alloca[9×i64] +56` | `alloca {ptr,ptr}` | future wall — Predicate 8 (non-integer elem) |
| 6 | 107 | `%L18` | **arena `+16`** | `alloca [1×i64]` | future wall — the MIRROR of #2 |
| 7 | 112 | `%L21` | `alloca i64` | **arena `+16`** | wall-9 class |
| 8 | 149 | `%L31` | `alloca i64` | **arena `+16`** | wall-9 class |

**The corpus memcpy is arena → *alloca*, never arena → arena.** It reads the boxed
`Array`'s `size` field (byte 16 of the 24-byte header) into a stack temp that is then
`load i64`-ed. Three sites, all identical in shape (N=8, K=1, src `gep i8 %obj, 16`,
dst `alloca i64`). Site #6 is the mirror; see §7 for the scoping recommendation.

---

## 2. Wall ordering after admission (probes `s04`–`s06`, `.ll` surgery on `root.ll`)

`extract_parsed_ir_from_ll(root.ll; entry_function="julia__pushsy29_91",
ptr_cells=true)` reproduces wall 9 **byte-identically** (probe `s03`), which makes
textual surgery a faithful admission simulator. Replacing a walled
`memcpy(dst, src, 8)` with its emission-equivalent `load i64` + `store i64` gives:

| after | next wall | where |
|---|---|---|
| #2 admitted | **WALL 10** — `%12 = ptrtoint ptr %memory_data3 to i64`, `Bennett-583s` / `Bennett-foz5` | `%top`, 5 instructions later |
| + wall 10 | #4 (`.mem` loaded-ptr src, another 37mt Predicate-6 reject) | `%L16` |
| + #4 | **wall 11** — `store {ptr,ptr} %"new::Array.ref", ptr %0` where `%0 = alloca {ptr,ptr}` — p06b's own silent-skip residual | `%L16` |
| + wall 11 … | #5, #6, #7, #8 remain behind it | `%L16`/`%L18`/`%L21`/`%L31` |

This confirms the bvmd forecast exactly: **wall 10 is the immediate successor of wall
9**, and it sits in the SAME block, five instructions downstream. Sites #4–#8 are all
behind wall 10 and behind wall 11.

---

## 3. The route decision — R2 is closed, so there is no contest

**R1 — decompose into per-cell traffic (the vbv9 / 37mt-ixiz shape).**

```
IRPtrOffset(src_off, src_op, k*8, ew_src)     # ew_src = 8·scale(src_root)
IRPtrOffset(dst_off, dst_op, k*8, ew_dst)     # ew_dst = 8·scale(dst_root)
IRLoad (tmp,      ssa(src_off), 64)           # VALUE width — one whole cell
IRStore(ssa(dst_off), ssa(tmp),  64)
```

**R2 — route to `IRCall(:memcpy)` D5b-style, like vau9's variable-size memmove.**
**MEASURED CLOSED** (probe `s08`). A `gc_alloc_obj`-bearing program carrying a
bulk-copy `IRCall` dies at `lower_vm`:

```
lower_vm: BennettVM.IntrinsicMemmove in a JULIA-tier program (byte-granular
cells) is unmodeled — its word-granular ÷8 span would silently copy an eighth
of the byte range (CW-D4, bead bennettvm-9n3y; the rehash-grow element copy is
the predicted next wall). Rule 1 fail-loud.
```

`_enforce_julia_heap_tier!` (`BennettVM/src/ir/intrinsics_genericmemory.jl:192-199`)
refuses `IntrinsicMemcpy` and `IntrinsicMemmove` alike in the Julia tier, and it is
right to: `_copy_range!` (`intrinsics_bulk.jl:105-113`) strides by ONE CELL per
element with `cells = _cell_count(nbytes) = nbytes ÷ 8`, which is the word tier's map.
Taking R2 would require `bennettvm-rxgy`'s byte-exact sibling (an
`IntrinsicMemcpyBytes`) — a BVM src change, for a **constant, K=1** copy that R1
expresses in four nodes that already ship.

**Take R1.** This is the same decision vbv9, doih, u2kk and qmv7 all made; sy29 is
their mirror, not a new mechanism.

---

## 4. The cell-map argument for every tier pairing the corpus exhibits

The bead asks for the argument per pairing. `IRPtrOffset(d, b, off, ew)` lowers to
`Define(d, b, :add, off ÷ (ew÷8))` (`BennettVM/src/ir/ingest_body.jl:534`), so
`elem_width` **is** the object's bytes-per-cell scale — `_root_scale`'s whole content.

| pairing | src scale | dst scale | offsets emitted | argument |
|---|---|---|---|---|
| **arena → alloca** (corpus, ×3) | 1 (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)`) | 8 (`_lower_alloca!` reserves `n` cells) | src `(8k, 8)` → cell `src+8k`; dst `(8k, 64)` → cell `dst+k` | Each side is an INDEPENDENT address computation off its own root; the shared quantity is the 64-bit VALUE, which occupies exactly ONE cell in **both** tiers (byte tier: at the field's base byte address, `+1…+7` never named — the 416r.13 / 9n3y / vbv9 convention; word tier: cell `k`). So `K = N/8` and element `k` is `src+8k → dst+k`. |
| **alloca → arena** (site #6, mirror) | 8 | 1 | src `(8k, 64)`; dst `(8k, 8)` | Same argument, transposed. |
| alloca → alloca | 8 | 8 | `(8k, 64)` both sides | Today's shipped path, unchanged. |
| arena → arena | 1 | 1 | `(8k, 8)` both sides | Sound *if* the roots are distinct (§8); not exercised by the corpus. |

**EXECUTED, not argued** (probe `s07_bvm_e2e.jl`, 42/42 under
`--check-bounds=yes`). A hand-written `.ll` writes 64-bit values into a 24-byte
`gc_alloc_obj` box at byte offsets 8 and 16, copies **both** (K = 2, so nothing is
vacuous) into an `alloca [2 x i64]`, then copies one back into the box at byte 0:

```
  w8  -> (off=8,  ew=8)  cell=+8        s0 -> (off=8,  ew=8)  cell=+8
  w16 -> (off=16, ew=8)  cell=+16       s1 -> (off=16, ew=8)  cell=+16
  m0  -> (off=0,  ew=8)  cell=+0        d0 -> (off=0,  ew=64) cell=+0
                                        d1 -> (off=8,  ew=64) cell=+1
  VM instruction kinds: [Define, IntrinsicGCAlloc, MemoryLoad, MemoryStore, StackAlloca]
  [L2 x=7 y=11] res=29 oracle=29  t0=7 t1=11 back=11
  [L3 x=7 y=11] res=29 oracle=29  t0=7 t1=11 back=11
  [L2 x=-3 y=2^40] res=2199023255549 oracle=2199023255549  ✓
  [L3 x=-3 y=2^40] res=2199023255549 oracle=2199023255549  ✓
```

plus exact `unrun!` (memory, frames, pc, `arena_top` all restored). Non-vacuity: had
the byte-tier stamps collapsed to word cells, the two seeded values would land at
cells `+1`/`+2` and every read would return `0` (ADR 0018 §E), giving `res == 0`.

**Value width vs address stamp — the 4y0d discipline, restated for the src side.**
`dst_ew`/`src_ew` (the width each `IRLoad`/`IRStore` carries) and `ptr_ew` (the
bytes-per-cell scale each `IRPtrOffset` carries) are **different numbers**. HEAD's
non-global arm (`instructions.jl:2256-2259`) uses `dst_ew` for BOTH, and for the
current alloca↔alloca clientele they coincide by construction. They do **not**
coincide the moment either side is an arena root. Take each side's stamp from
`_root_scale`, exactly as `_handle_memcpy_global_src:2777-2779` now does:

```julia
ptr_ew_src = let rs = _root_scale(src_v, names, ptr_cells); rs === nothing ? src_ew : 8*rs[1] end
ptr_ew_dst = let rs = _root_scale(dst_v, names, ptr_cells); rs === nothing ? dst_ew : 8*rs[1] end
```

This is byte-identical for every existing client (alloca roots: `8·8 == 64 == dst_ew`).

---

## 5. (SC) coverage — YES, and the K=1 trap it does NOT catch

**(SC) covers the memcpy arm's emitted nodes.** Structurally: `_check_scale_coherence!`
iterates every `IRPtrOffset`/`IRVarGEP` in the emitted stream and needs only the node's
BASE to be a named LLVM value (`instructions.jl:454-476`). The arm's base is
`ssa(names[src_v.ref])` / `ssa(names[dst_v.ref])` — always named. Measured (probe
`s09`): an `alloca [4 x i64]` addressed by a byte GEP **and** by a K=2 37mt memcpy
(which stamps `ew=64`) is refused loudly —

```
ir_extract.jl: SCALE-COHERENCE violation in @sy29_sc: … the use-directed
BYTE-NORMALISATION … requires EVERY emitted offset off the root to be
byte-stamped … (Bennett-bvmd, predicate `_root_scale` / `_check_scale_coherence!`)
```

— which can only happen if the arm's own `ew=64` nodes are in the resolved set.

**Bennett-21rj is NOT load-bearing for this arc.** The bypass it names is the
`heap.jl` early return, gated `mem === :heap` (`module_walk.jl:409-419`), plus
`dict_vm` / `vector_vm_emit`, which build their own ParsedIR. The corpus path is
`mem=:auto` + `ptr_cells=true` through `_module_to_parsed_ir_on_func`, which runs the
check at `module_walk.jl:695`. sy29's route emits through `instructions.jl`, not
`heap.jl`. 21rj stays a P2 in its own right; do not fold it in.

**THE TRAP — (SC)'s vacuity exemption makes a K=1 mis-stamp invisible.** Enforcement
skips a node whose emitted and intended cells coincide (`instructions.jl:593`,
`cell_emitted == cell_meant`), canonically offset 0. At **K = 1 the only offset IS 0**,
so an arena-src node wrongly stamped `ew=64` would pass (SC) silently — and the whole
corpus is K = 1. This is *precisely* how the pre-4y0d vbv9 defect stayed green
(`instructions.jl:2774-2776`, and `test_vbv9_arena_memcpy.jl`'s K=1 pins).

> **Implementer obligation (non-negotiable):** the RED test must include a **K ≥ 2
> arena-src** fixture asserting `(offset_bytes, elem_width) == (8, 8)` for `k = 1`,
> mirroring `test_bvmd_root_scale.jl` (H). A K=1-only fixture proves nothing.

---

## 6. BVM side — zero src change, verified not assumed

* **`IntrinsicMemcpy` never sees a byte-tier src, at either K.** Not because it
  handles it, but because it cannot be reached: `_enforce_julia_heap_tier!` fails loud
  first (§3, probe `s08`). Its `_copy_range!` **is** word-tier-only (`src+i`, `d+i`
  with `cells = nbytes÷8`) and would be 8× wrong for a byte-tier operand at K ≥ 2 —
  the 4y0d class, on the VM side. It is fenced off, not fixed, and that fence is the
  right answer for this arc. `bennettvm-rxgy` owns the byte-exact successors.
* **Route R1 needs nothing new.** Probe `s07`'s lowered program contains only
  `Define`, `IntrinsicGCAlloc`, `MemoryLoad`, `MemoryStore`, `StackAlloca` — every one
  pre-existing, and `@test !any(IntrinsicMemcpy|IntrinsicMemmove)` holds.
* **Zero-BVM-src-change claim: verified by E2E probe**, forward and reverse, under two
  history regimes. The streak (8) is an observation; this probe is the reason it can
  be claimed a ninth time, and the implementer should re-run `s07`'s assertions as a
  BennettVM-side test file (`test_sy29_arena_src_vm.jl`, the
  `test_bvmd_byte_tier_vm.jl` pattern) rather than inherit the claim.

---

## 7. Proposed admission — the concrete diff shape

All of it lands in `_handle_memcpy_arm` (`instructions.jl:2065-2262`), gated on
`ptr_cells` so the circuit path is byte-identical (the vbv9 / u2kk / qmv7 pattern —
`ptr_cells=false` keeps the *unchanged* Predicate-6 message, which is what
`test_qmv7` GATE (b) and `test_37mt` pin).

1. **Predicate 6, src half.** Before the src reject at `:2178`, under `ptr_cells`
   only, resolve `src_arena = _gc_alloc_root_ref(src_v)`; on success set
   `is_arena_src = true`, `src_ew = 64` (a cell is one `Int64`, ADR 0018 §A), and skip
   the `_alloca_elem_width_bits` probe (there is no `LLVMGetAllocatedType` for a call
   result) — verbatim the vbv9 G3/G4 structure.
2. **Predicate 6, dst half (see the scoping note below).** The symmetric
   `dst_arena = _gc_alloc_root_ref(dst_v)`, inserted *before* the dst reject at
   `:2171` and after the existing qmv7 `gc_loaded` branch at `:2163-2169`.
3. **NEW predicate: cell-aligned arena offset.** `_gc_alloc_root_ref` returns only the
   root, not the byte offset. The arm must compute the const-GEP byte offset from the
   arena root and require `offset % 8 == 0` (and `N % 8 == 0`, which Predicate 8c
   already gives once `ew = 64`). Rationale: the byte-tier convention places a 64-bit
   value in ONE cell at its base byte address; an 8-byte chunk starting at byte 4 has
   no faithful single-cell gather. (SC) will **not** catch this — `gep i8 %obj, 4` is
   perfectly scale-coherent. This is a genuinely new guard, not a copy of vbv9; note
   that vbv9's dst side has the same unchecked corner (its G7 checks the *global*
   offset only). Corpus offset is 16, so this fires on nothing today.
4. **Predicate 8/8b (element width).** With an arena on either side that side's `ew` is
   64; the existing same-width check then *requires* the other side to be 64 too. A
   `memcpy(alloca i8 dst, arena src, 8)` must fail loud with the cross-width message —
   the exact analogue of doih's G6.
5. **Emission.** The `:2252-2260` loop, with `ptr_ew_src` / `ptr_ew_dst` from
   `_root_scale` per §4, and `IRLoad`/`IRStore` widths left at the VALUE width.
6. **Bennett-land carry-through — a hole to close, not inherit.** `:2241-2243`
   propagates the synth-address tag via `synth_ptr_allocas`, a set keyed on **alloca**
   refs. vbv9's arena-dst branch deliberately records **nothing** (`:2753`,
   `elseif !is_arena && …`), so synthetic-address bytes CAN sit untracked in an arena
   cell; an arena-src memcpy would then launder them into an alloca and defeat the
   `Bennett-land-ptrload` escape guard. Not reachable in this corpus (`@"_j_const#1"`
   is a plain integer), but the arm must decide rather than drift. Two clean options:
   (a) `Set{_LLVMRef}` already admits a `gc_alloc_obj` call ref — have vbv9 push the
   arena root and have this arm propagate from it; or (b) fail loud on an arena src
   whose root was ever a synth-provenance dst, the u2kk choice (`:2747-2752`). Prefer
   (a); it is two lines and strictly stronger. **Do not silently skip.**

**Scoping recommendation — admit the arena root on BOTH sides in this arc.** The bead
says "src"; the corpus site #6 is the mirror and is only two blocks away. Arguments:
the predicate work is shared; the (P7) distinctness rule (§8) has to handle mixed
roots anyway; and an asymmetric arm re-walls on the same function for the transposed
reason. The cost is that the dst direction needs its **own reversibility paragraph**,
because site #6 *destructively overwrites* arena `+16`, which vbv9's STEP-0c freshness
argument does **not** cover — the correct citation is u2kk's REVERSIBILITY
JUSTIFICATION (`:2615-2629`): the write is reversed by BVM's Bennett-1973 history tape,
not by a freshness precondition, and the circuit path stays fail-loud because the whole
branch is `ptr_cells`-gated. If the implementer prefers a smaller diff, src-only is
defensible — site #6 sits behind wall 10 regardless — but then **file the dst bead in
the same commit** and say so in the arm comment.

---

## 8. Overlap / aliasing

`llvm.memcpy`'s contract forbids overlap. Route R1 **bypasses BVM's runtime overlap
check entirely** (that check lives in `forward(::IntrinsicMemcpy)`,
`intrinsics_bulk.jl:117-121`, which R1 never emits), and R1's per-element
load-then-store in ascending order genuinely miscopies an overlapping range. **The
extraction-time distinctness guard is therefore load-bearing, and it is replacing a
check, not adding one.** Say so in the arm comment.

* **Corpus: provably non-overlapping.** src root is `%"new::Array"` (a
  `julia.gc_alloc_obj` call), dst root is `%"new::Array.size"` (an `alloca i64`).
  Different LLVM refs, different *allocator kinds*: BVM reserves the alloca out of the
  stack region (`StackAlloca` / `stack_top`) and the box out of the arena
  (`IntrinsicGCAlloc` / `arena_top`). No dynamic execution can make them alias.
* **The guard.** Generalise Predicate 7 (`:2184-2188`) from "same alloca ref" to
  "same **root** ref, whichever kind". Two *distinct* static allocation sites yield
  disjoint ranges (both allocators are monotone bumps; distinct allocas are distinct
  frame slots). The dangerous shape is one root on both sides — canonically
  `memcpy(gep i8 %obj, 0, gep i8 %obj, 8, 8)` — which must keep failing loud with the
  existing "semantically memmove" message, now reachable for arena roots too. **Do not
  weaken it to a byte-range disjointness test**: that would be a new alias analysis
  Bennett does not have, and CLAUDE.md §1 prefers the loud refusal.
* **The vau9 asymmetry, restated.** memmove is *allowed* to overlap and routes to
  `IRCall(:memmove)` because BVM's `_copy_range!` snapshots the whole src range before
  writing (`intrinsics_bulk.jl:100-113`) — overlap-safe by construction. sy29 has no
  such backstop, because R1 does not go through that code. The asymmetry is: memmove
  delegates overlap safety to the VM; sy29 must **prove disjointness at extraction**.

---

## 9. Wall 10, verified and characterised (for the wall-10 scout — NOT designed here)

After simulated admission of #2, the next wall is verbatim (probe `s04`):

```
ir_extract.jl: ptrtoint in @julia__pushsy29_91:%top:
  %12 = ptrtoint ptr %memory_data3 to i64
— ptrtoint of a GenericMemory .data base under ptr_cells whose result is NOT
confined to a same-Memory base-cancelling bounds check (a use is not a
same-root sub(ptrtoint,ptrtoint); e.g. inttoptr-deref, store, hash, or a
cross-allocation difference) — predicate `_verify_memdata_bounds_cluster`. An
escaping base-dependent address would break oracle match (Bennett-583s / CW-D;
CLAUDE.md §1). AND its result is not CONFINED to a dead-throw bounds check
either — predicate `_foz5_confined_dead_bounds` (Bennett-foz5 / ADR 0017 §4a):
the source must be a certified materialised cell and EVERY use must run
sub(ptrtoint,ptrtoint) → icmp → i1-and/or/xor → a conditional br with a
utzc-pruned `:__unreachable__` successor …
```

**The cluster, with its complete use-graph** (`root.ll:58-78`, verified by exhaustive
`grep` for each SSA name):

```llvm
  %memory_data_ptr2 = getelementptr inbounds { i64, ptr }, ptr %9, i32 0, i32 1
  %memory_data3     = load ptr, ptr %memory_data_ptr2, align 8
  %12 = ptrtoint ptr %memory_data3 to i64      ; uses: {sub}                 <-- WALL 10
  %13 = ptrtoint ptr %7 to i64                 ; uses: {sub}
  %memoryref_offset    = sub  i64 %13, %12     ; uses: {udiv}   <-- (C2) FAILS HERE
  %memoryref_offsetidx = udiv exact i64 %memoryref_offset, 8
  %14 = add i64 %memoryref_offsetidx, 1        ; uses: {%15, STORE env+16}
  %15 = add i64 %14, %11                       ; uses: {%16}
  %16 = sub i64 %15, 1                         ; uses: {icmp, STORE env+8}
  %17 = icmp slt i64 %.unbox, %16
```

**Why foz5 §4a clause (iii) fails, precisely.** Clause (iii) is implemented at
`instructions.jl:1707-1716` (C2): *for each use of the `sub`, the user's opcode must be
`LLVMICmp`*. Here the `sub`'s **only** use is `udiv exact` ⇒ the loop returns `false` at
`:1714` on the first iteration. Note what does **not** fail: (C0) passes —
`%memory_data3` and `%7` are both certified `:load` sources, named and unsuppressed;
(C1) passes — the single use is a 64-bit `sub` of two `ptrtoint`s. **The cluster is one
opcode away from foz5's contract, and that opcode is the whole difficulty**: the
difference does not merely *steer* a halting branch, it becomes the element index and
**escapes into two closure-env stores** (`env+8`, `env+16`) that `_growend!` reads.

**The observation the wall-10 scout will want** (offered as data, not as a contract):
the value `%memoryref_offset` is a byte difference between two pointers into the *same*
GenericMemory, and `udiv exact 8` converts it to an element index. Under the Julia byte
tier a VM cell index **is** a byte address, so a cell difference equals the native byte
difference and the `÷8` is faithful — but that is exactly the premise foz5 §4a
*declined to prove*, and BVM's first runtime evidence for it arrived only with bvmd's
E2E fixture. A third contract must either prove oracle-equality for the escaping value
or confine it some other way. **Do not design it here.**

---

## 10. Blast radius

### 10.1 Message-territory pins that FLIP (six sites, not four)

Every one carries the same three-part shape: p06b narrowings (unchanged), the wall-7
blanket negatives (**flip**), and the wall-9 positive (**flips**).

| file | anchor | what must change |
|---|---|---|
| `test/test_bvmd_root_scale.jl` (I) | `:663-699` | positive + both 583s negatives |
| `test/test_p06b_aggregate_store.jl` (k) | `:765-785` | same |
| `test/test_foz5_confined_bounds.jl` (W8) | `:855-872` | same |
| `test/test_40ys_instanceless_callees.jl` | `:535-558` | same |
| `test/test_7wsz_ptr_sret_fields.jl` (J) | `:540-560` | same |
| **`test/test_vau9_variable_memmove.jl`** | `:280-333` | same — **this one is not in the bead's "four"; do not miss it** |

`test/test_jbko_ptr_identity_icmp.jl:554-555` also asserts `Bennett-583s` /
`base-cancelling` **positively**, but on its own fixture, not the corpus — untouched.

### 10.2 Marker design for wall 10

The `udiv exact` discriminator that bvmd's notes suggest **is not available**: the
wall-10 message text contains no `udiv` (the `_ir_error` prefix quotes the *ptrtoint*,
not the cluster). Measured anchors in the wall-10 message: `ptrtoint`, `Bennett-583s`,
`base-cancelling`, `Bennett-foz5`, `_foz5_confined_dead_bounds`,
`_verify_memdata_bounds_cluster`, `memory_data`. Recommended replacement, in the foz5
two-part idiom:

```julia
# BODY SCOPE — preserves the original intent exactly: wall 7 was the CLOSURE's
# `%idxend41` cluster, cleared by foz5. Wall 10 is in the ROOT body.
@test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
# POSITIVE, wall 10 — non-numeral anchors only (Bennett-0ncn), disjoined
# because which predicate is named first is not a contract.
@test occursin("Bennett-583s", msg) || occursin("Bennett-foz5", msg)
# NEW LOAD-BEARING NEGATIVE — wall 9 is CLEARED; a 37mt reject is a regression.
@test !occursin("Bennett-37mt", msg)
```

Keep every p06b/bvmd narrowing verbatim; keep `!occursin("Bennett-lgzx")`,
`!occursin("Bennett-jbko")`, `!occursin("Bennett-iwo9")`, `!occursin("memmove")`,
`!occursin("BYTE-granular getelementptr")`, `!occursin("Bennett-bvmd")` — all measured
still-true at wall 10.

### 10.3 The memcpy-family neighbours (green baselines re-measured at HEAD)

| file | baseline | exposure |
|---|---|---|
| `test_37mt_memcpy_const_aligned.jl` | **86/86** | the arm being edited. Every testset is alloca↔alloca or a reject on the CIRCUIT path ⇒ must stay green **byte-identically**; that is the `ptr_cells`-gating obligation. No testset pins the src-not-alloca message. |
| `test_lqif_memcpy_memmove_reject.jl` | 12/12 | `ptr_cells=false` residue pins. Unaffected. |
| `test_vbv9_arena_memcpy.jl` | 20/20 | arena **dst**, global src. `_root_scale` is already the stamp source there (4y0d); adding a src arm must not touch it. |
| `test_doih_memcpy_global_src.jl` | 85/85 | the G1-G9 cascade. Untouched if the src arm is added to the NON-global path only. |
| `test_qmv7_gc_loaded_memcpy.jl` | 35/35 | `gc_loaded` **dst** branch at `:2163-2169`, and GATE (b) pins the UNCHANGED Predicate-6 message on the circuit path. A dst-side arena branch must be inserted so qmv7's branch still runs first. |
| `test_u2kk_param_memcpy.jl` | — | param-cell dst; the precedent for the reversibility paragraph if the dst direction is in scope. |
| `test_8bys_variable_memset.jl`, `test_munq_arr_i8_alloca.jl` | — | mention 37mt in prose only. |

Also verify `_bvmd_reject_normalised_alloca!` (`src/lowering/driver.jl`) still fires
for `ptr_cells=true` + `lower()`: if the new arm's alloca dst ever gets
byte-normalised, the circuit path must keep refusing loudly by name.

---

## 11. Recommended arc

1. **RED first** (CLAUDE.md §3): `test/test_sy29_arena_src_memcpy.jl` with (a) the
   corpus-shaped K=1 arena-src → alloca-dst fixture, (b) **a K=2 fixture pinning
   `(8, 8)` on the src side** (§5's trap), (c) a cross-width reject, (d) a same-root
   arena→arena reject, (e) a `ptr_cells=false` byte-identity control asserting the
   unchanged Predicate-6 message, (f) a non-8-aligned arena offset reject.
2. **GREEN**: the `_handle_memcpy_arm` edit of §7.
3. **BennettVM**: `test/test_sy29_arena_src_vm.jl` from probe `s07` — E2E oracle,
   both history regimes, exact `unrun!`, and an assertion that no `IntrinsicMemcpy`
   appears. Expect ZERO BVM `src/` change; if that turns out false, **stop and
   escalate** — it is an upgrade trigger fired late.
4. **Marker advance**: the six sites of §10.1, with §10.2's replacement.
5. **File**: the arena-dst direction if src-only is chosen; the Bennett-land arena
   provenance hole (§7.6) if option (b) is taken; and note in `Bennett-8bys` that the
   loaded-`ptr` src class (corpus site #4) and the `alloca {ptr,ptr}` src class (#5)
   remain its territory.
6. **Do not** touch `Bennett-21rj` (§5), the (P5) surface, or `_root_scale` itself.

## 12. Corrections to the bead text

* "arena-to-arena copy capability" — the corpus copy is **arena → alloca** (×3), plus
  one **alloca → arena** mirror. There is no arena→arena site. The title is
  misleading; the capability is *an arena root on either side of a const-size memcpy*.
* "the four advanced markers" — there are **six** (§10.1); `test_vau9` is the extra,
  and `test_bvmd_root_scale` (I) is the one bvmd itself added.
* "the blanket `!583s` negatives are still true at wall 9" — correct, and they
  **stop** being true the instant this bead lands. That is bvmd's marker trap arriving
  exactly where bvmd predicted (`test_bvmd_root_scale.jl:686-693`).
* The bvmd notes' suggested `udiv exact` discriminator for wall 10 is **not
  constructible from the message text** (§10.2).
