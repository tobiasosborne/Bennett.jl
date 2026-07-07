# Worklog chunk 092

## Session log — 2026-07-07 — Bennett-583s / CW-D: GenericMemory `.data`-base ptrtoint → cell identity under ptr_cells (ADR 0017)

**What.** `src/extract/instructions.jl`: extended the iwo9 ptrtoint lever to admit
`ptrtoint ptr %memory_data to i64` (the GenericMemory `.data` base pointer) as a
width-64 cell identity `IRBinOp(dest, :or, src, iconst(0), 64)` under `ptr_cells`,
gated to a same-Memory base-cancelling bounds check. Three new structural helpers
beside `_param_ptr_root_ref`: `_is_memdata_field1_gep` (field-1 GEP of `{i64,ptr}`),
`_memdata_root` (traces `.data` provenance through the i8 byte-offset GEP + identity
casts, depth-8), `_verify_memdata_bounds_cluster` (EVERY use of the ptrtoint must be a
same-ROOT `sub(ptrtoint,ptrtoint)`; use-less → reject). New arm is `LLVMPtrToInt`-only —
an `inttoptr` of a `.data` base is the forbidden escape, falls to the iwo9 fail-loud.

**Why sound.** `sub(ptrtoint(base+off), ptrtoint(base)) = off` — the base cancels, the
net effect is base-INDEPENDENT → matches the native oracle. The unsoundness boundary is a
base-DEPENDENT escaping value (cross-allocation diff, hash, inttoptr-deref) → stays
fail-loud. Same-ROOT (not merely "both memdata") is load-bearing: option (b) "sibling is
a memdata ptrtoint" would wrongly admit `sub(ptrtoint(dataA+off), ptrtoint(dataB))` for
DIFFERENT allocations (base does not cancel → the bennettvm-90l oracle-mismatch hazard).
Chose option (a), the same-root gate.

**Gotchas (next agent, read this).**
1. The extractor walks **NON-RAW** IR (`entry.jl:60` `code_llvm(...; raw=false)`): 0
   addrspacecast, plain `getelementptr {i64,ptr}`. A `raw=true` `code_llvm` dump is
   MISLEADING for the seed predicate — always re-dump non-raw for the walker's view.
   Hand-built `.ll` fixtures must use plain `ptr` (addrspace 0), else they wall at
   addrspacecast.
2. 583s is a `--check-bounds=yes`-ONLY artifact: at default check-bounds, `setindex!` has
   0 ptrtoint and already extracts. The arm is byte-identically inert at default, so the
   real-target test self-guards on `Base.JLOptions().check_bounds == 1`.
3. Data structure: a self-contained structural `_memdata_root` helper — NOT a threaded
   `memdata_ssa` set through `module_walk.jl`. The same-base gate needs structural
   root-tracing regardless, so a membership set is redundant (`x ∈ set ⟺ _memdata_root(x)
   !== nothing`); mirrors `_param_ptr_root_ref`/`_alloca_root_ref`.

**Process.** 3+1 (2 blind proposers → implementer → orchestrator review). Both proposers
independently caught the non-raw-IR correction and converged on option (a); diverged only
on data structure (threaded set vs structural helper) — chose the structural helper.

**Tests.** New `test/test_583s_memdata_bounds.jl` (7 testsets: GREEN node-shape, escape
guards hash + inttoptr-deref, width≠64, non-memdata, cross-Memory, real-target
wall-advance, byte-identity/inertness). Default 28 / suite 29. Downstream u2kk-trap
updates: `test_59zi` (ht_keyindex2 → U114 store wall) + `test_beaw` GATE d (fdict_d1b →
AssertionError wall); baseline-green-confirmed before editing. ptr_cells regression
cluster (iwo9/r92o/beaw/8g7m/lf14/59zi/u2kk/yd4f) green under `--check-bounds=yes`.

**Next wall — both modes converging on THROW/DEAD-block constructs.** After 583s the
fdict set-extraction walls at: suite → `setindex!` U114 `store { ptr, ptr } %memory_ref,
ptr %"box::GenericMemoryRef"` (non-integer struct-store; Bennett-lgzx made it fail-loud,
now needs modeling); default → `rehash!` `[1 x ptr] @j_AssertionError` ArrayType return
(Bennett-44dg). 583s also made `rehash!` **mode-invariant** (both modes → AssertionError).
BOTH walls live in Julia throw/error DEAD blocks (bounds_error / AssertionError) — ADR
0017 §4 "throw/unreachable → halt-dead-branch" recognition could clear both at once; the
next design should weigh that vs modeling each construct. FOLLOW-UPS filed: fold
`sub(ptrtoint(gep i8),ptrtoint) → off` for in-model cancellation (Bennett.jl). NOT yet
filed (capture at the BennettVM assembly step): BennettVM `VarGEP` byte-vs-cell stride
reconciliation for wider-than-Int8 element types (exact for Int8 fdict).

---

## Session log — 2026-07-07 — Bennett-yd4f / U80: integer undef in phi-incoming → zero cell under ptr_cells (CW-D, ADR 0017)

**What.** `src/extract/instructions.jl` generic `_convert_instruction` PHI arm:
the per-incoming `_operand(val, names)` call is replaced by a gated form —
`(ptr_cells && val isa LLVM.UndefValue && LLVM.value_type(val) isa
LLVM.IntegerType) ? iconst(0) : _operand(val, names)`. Under the closed-world
`ptr_cells` gate ONLY, an INTEGER `undef` in phi-INCOMING position lowers to a
`ConstOperand(0)` instead of the Bennett-bjdg / U80 fail-loud. Everything else
is byte-identical: poison anywhere, non-integer (ptr) undef, integer undef in
any NON-phi operand position, and the entire `ptr_cells=false` circuit/:heap
path all stay fail-loud (poison is a DISTINCT LLVM.jl type, not a subtype of
UndefValue, so it is never caught; non-integer undef fails the `IntegerType`
guard and falls through to `_operand`).

**Why sound.** `rehash!(::Dict{Int8,Int8},::Int64)` at `optimize=false` has
exactly 5 undef operands, all `i64`, all phi-incoming, all on dynamically-dead
edges (LLVM LangRef: undef-as-phi-incoming don't-care contract). BennettVM
resolves phis by the TAKEN predecessor edge (`BennettVM/src/ir/ingest_phi.jl:84`),
so a `0` placeholder on a dead incoming is never materialised at runtime. Gated
at the phi SITE, not in `_operand`, because undef→0 is position-DEPENDENT.

**Wall-advance (this is a WALL-ADVANCE, not full extraction).** rehash! advances
PAST the `phi i64 [ undef, ... ]` U80 wall (8g7m's successor) to a MODE-dependent
next wall — captured on this machine 2026-07-07:
- **default mode**: `call [1 x ptr] @j_AssertionError_… has unsupported return
  type LLVM.ArrayType([1 x ptr]) under ptr_cells … (BVM ADR 0020 D5 / chunk C)`.
- **suite mode (`--check-bounds=yes`)**: `%N = ptrtoint ptr %memory_data to i64 —
  ptrtoint under ptr_cells whose source is NOT a recognised Julia type-tag value
  (Bennett-iwo9 / CW-D3 Lever 1)`.
Two distinct successor beads for the orchestrator to file: an ArrayType
(`[1 x ptr]`) C-call-return lever, and the `%memory_data` GenericMemory
data-pointer ptrtoint (iwo9 extension). `ptr_cells=false` still walls EARLIER at
the ptr-return width wall (`unsupported LLVM type for width query: PointerType`)
in BOTH modes — the undef phi is never reached under the gate-off path, so the
byte-identity guard for cells=false is "still errors at the ptr wall", not "undef
wall".

**Gotcha — the u2kk cross-test trap (mode-dependent).** Landing yd4f removes the
undef wall that THREE other rehash! wall-advance tests assert as their "next
wall": `test_8g7m` GATE F, `test_lf14` GATE B rehash! block, `test_u2kk` GATE (d).
In SUITE mode all three already covered the ptrtoint/iwo9 successor, so
`Pkg.test()` (which runs `--check-bounds=yes`) would stay green WITHOUT the test
edits — but a per-file run in DEFAULT mode walls at the `j_AssertionError`
ArrayType message, which none of the three disjunctions covered → RED. Added
`unsupported return type` / `assertionerror` / `arraytype` disjuncts to all
three (order-tolerant, Rule 5). The load-bearing NEGATIVE assertions are
unaffected: `_is_null_wall` (8g7m), `_is_ptr_return_wall` = "unsupported LLVM
type" && "PointerType" (lf14), `_is_doih_g3_wall` (u2kk) match neither new wall.

**Task-spec discrepancy (reported to orchestrator).** The bead predicted
`test_yd4f` GATE 5 `ptr_cells=false` would throw the UndefValue wall; observation
shows it throws the PointerType ptr-return-width wall (the ptr return pre-empts
the undef phi under the gate-off path). The new test asserts reality (still
errors + pointer wall, defensively inclusive of undef).

**Verification (all suite mode `--check-bounds=yes` unless noted).**
`test_yd4f` 26/26 (default 26/26 too); `test_8g7m` 47/47; `test_lf14` 27/27;
`test_u2kk` 15/15; regression set (beaw/6bu3/59zi/ares/zf5v/nd45/iwo9/r92o/xrd6)
all green.

## Session log — 2026-07-06 — Case C: two-index array GEP support (cross-repo bennettvm-416r.4 + closes dzd)

**What.** `src/extract/instructions.jl` gains a new "Case C" arm (before the
qal5/U16 reject) for the two-index ARRAY getelementptr `[N x iM], ptr BASE, i64
0, i64 IDX` — a runtime-indexed array element access. Emits the SAME
`IRVarGEP(dest, base_sym, idx, elem_width)` node the single-index global/local
arms already produce (the leading constant-0 is stripped; semantically
identical). ONE arm covers BOTH bases: a const global integer array (name ∈
`parsed.globals`) — the `bennettvm-416r.4` driver (`rom[i&7]`) — and a named
local alloca-backed array (`haskey(names, base.ref)`) — the **Bennett-dzd**
closure (C `uint8_t a[N]` stack arrays, which previously forced the `calloc`
workaround). Fails loud (keeping the qal5 breadcrumb) on non-integer element
(float/pointer/nested — no bit-exact `elem_width`), first index ≠ constant-0, or
>3 operands (genuine multi-dim). Struct GEPs (StructType source, not ArrayType)
skip this arm and hit the existing struct arm unchanged.

**Why (cross-repo).** This is the Bennett.jl half of BennettVM's `416r.4`
(const globals as read-only VM memory — a NES ROM prerequisite). Landed via the
CORE 3+1 protocol (2 proposers + implementer + review); the BennettVM half
(`GlobalROM` segment, `GLOBAL_BASE=2^48`, materialization) is in BennettVM
`src/ir/{IState,memory_floor,ingest}.jl`. See BennettVM WORKLOG 2026-07-06.

**Gotcha — two fail-loud tests updated (legitimately, not weakened).**
`test_qal5_multi_index_gep.jl`'s original fixture (`[4 x i32], ptr @tbl, 0, %i`,
a const global int array at a runtime index) IS the 416r.4 goal and now
extracts → the test now positively asserts `IRVarGEP(:tbl,…,32)` +
`parsed.globals[:tbl]==([1,2,3,4],32)`, and moves its fail-loud coverage to a
genuine multi-dim `[2x[2xi32]]` + a non-integer `[4xdouble]`.
`test_haiy_ptr_cells_store_load_gep.jl` swapped its now-supported `[4xi64]`
local-array edge case for `[4xdouble]` (non-integer element, still rejected). A
grep over all test `.ll`/inline IR found no other affected fixtures (the
implementer's narrower grep missed ~10 `heap_*`/T5 fixtures that ALSO carry
2-index array GEPs, but those all still pass — `heap_m2` 9734, `heap_m3` 529,
T5-julia 517 — because their allocas' Case C lowering is correct). Verified:
qal5 (4+6), haiy (39), plus BennettVM `test_global_array_vm.jl` 2375/2375 and
the BennettVM full suite 9328/9328.

**Also this session — fixed a PRE-EXISTING red (`test_doh6_docs_makejl.jl`).**
Diagnosing why the Bennett.jl full suite timed out (it did NOT — it ran ~2.5×
slow under machine pressure, ~71min, and the 75min cap cut off the last file
`kuza`, which passes standalone 9734/9734), a streamed run revealed the ONLY
failing file was `test_doh6`: the docs overhaul (commit `1bf2a51`) retired flat
`docs/src/reference.md` → `docs/src/reference/autodocs.md`, but that docs-only
push skipped tests, so the stale-path checks went red unnoticed. Repointed the
test (14/14). Unrelated to Case C; fixed here to unblock a green push.

## Session log — 2026-06-30 — Comprehensive documentation round (README + Diátaxis docs/src), Bennett.jl + BennettVM.jl

**What.** Full docs overhaul for both sibling repos. Bennett.jl: total README rewrite +
restructured `docs/src` into a Diátaxis site (getting_started / tutorials / howto /
explanation / reference, 18 pages) + hand-authored SVG pipeline diagram + new `make.jl`
nav; retired the 4 superseded flat pages (`tutorial.md`/`api.md`/`architecture.md`/
`reference.md`), preserving the autogen `@docs` surface as `reference/autodocs.md`.
BennettVM.jl: README rewrite (production front door, replacing the spike-dominated text)
+ a `docs/src` site scaffolded from scratch (6 pages) + `make.jl` + `docs/Project.toml`.

**Method.** Two mapping workflows (12 + 6 subagents) produced subsystem maps + a doc
staleness audit + a **live README-snippet verifier** (ran real Julia 1.12.5). Then two
write-then-adversarially-verify workflows authored the Diátaxis pages grounded in a
verified-facts block + the maps + source; the verify pass caught/fixed real errors.

**Key staleness fixed (every headline number re-verified against a live run).**
- `gate_count` returns a **NamedTuple** `(total, NOT, CNOT, Toffoli)`, not an Int — the
  old README showed it as a scalar everywhere.
- `x+Int8(1)` default: **58** gates / ancilla **25** / t_count **84** (old README: 100/76/196).
  `x*x+3x+1`: **482** (old: 872). `x*y` Int32 default toffoli_depth **180** (old: 190);
  `:qcla_tree` **56** ✓. QROM `sbox` example **114** (old: 146).
- **CRITICAL**: `simulate(controlled(c), false, x)` returns **0** (output register stays
  zero), not the input — the old README taught wrong controlled-circuit semantics. Source
  docstring (`src/controlled.jl`) confirms 0.
- `mul=:karatsuba` is **retired** (only `:auto/:shift_add/:qcla_tree`); `add=:auto` is
  always `:ripple` (not "Cuccaro-when-dead"); `target` has no `:circuit` value (it is
  `:gate_count`/`:depth`/`:reversible_vm`).
- The shipped **`target=:reversible_vm`** backend (BennettVM, M13 e2e Collatz) is now the
  README's headline "two backends" story — was previously documented as "no implementation
  exists."
- Transcendentals are **supported** (60 `soft_*` exports; ≤2 ulp); QROM is `2(L-1)` Toffoli
  (T-count `4(L-1)`); Feistel is `~4W` Toffoli (not `8W`); `lower.jl`/`ir_extract.jl` are
  shims over `src/lowering/` + `src/extract/`; `ir_parser.jl`/`sat_pebbling.jl` deleted.

**Gotchas for the next agent.**
- I deliberately ran **no `bd`** commands so the carefully-synced `.beads` export stayed
  clean (the auto-export-drops-memories trap). Follow-ups are recorded here, not filed as
  beads, to avoid re-churning the export.
- `docs/make.jl` now sets **`doctest=false`** (the prose pages show live-verified outputs
  as plain ```julia blocks). Re-enable `doctest=true` only after validating the build.
- The Bennett-1973 DOI is `10.1147/rd.176.0525` (the old README hyperlinked the 1989 SIAM
  DOI `10.1137/0218053`).

**Follow-ups (doc debt, unfiled).**
- `CLAUDE.md` "File Structure" is stale: still calls `lower.jl`/`ir_extract.jl` monolithic
  ("3+1 split pending"), lists deleted `ir_parser.jl`/`sat_pebbling.jl`, and says "274 test
  files" (actual 297). Worth a pass.
- BennettVM `BENNETT_JL_PIN.md` / `lower_vm.jl` / PRD §3.7 cite four divergent Bennett.jl
  SHAs; reconcile to one canonical pin. BennettVM `src/BennettVM.jl` "Status" docstring and
  several PRD §3.x signatures are frozen at the M0.1/spike era (documented in the maps).

## Session log — 2026-06-29 — Bennett-8g7m: ptr-typed `icmp` under `ptr_cells` (closed-world fdict CW-D path) + session wind-up

**Context.** Third bead of a single orchestrated session advancing the P0 closed-world
fdict critical path (cross-repo BennettVM EPIC `bennettvm-416r.11` / e2e `7xa`), after
`Bennett-xrd6` (sret-call) and `Bennett-u2kk` (param-cell memcpy). After u2kk,
`extract_parsed_ir(Base.rehash!, Tuple{Dict{Int8,Int8},Int64}; optimize=false, ptr_cells=true)`
walled at `icmp ne ptr %4, null` (a Dict-field null check).

**Root cause.** The ICmp arm of `_convert_instruction` (`src/extract/instructions.jl` ~2414)
had two interlocked defects under `ptr_cells`: (A) it didn't thread `ptr_cells` to
`_operand`, so a `ConstantPointerNull` hit the U80 fail-loud (helpers.jl:198) even though the
helper ALREADY lowers `null → iconst(0)` under the gate (Bennett-beaw); (B) `_iwidth(ops[1])`
on a pointer operand hits `_type_width(PointerType)` → error (no PointerType branch). Both
needed fixing together. Note `IRICmp` requires `width >= 1`, so the select/phi `width=0`
sentinel is illegal — a pointer operand's cell width is **64**.

**Process (CLAUDE.md Rule 2, 3+1).** 2 independent opus proposers CONVERGED ~98%.
Adjudicated: under `ptr_cells`, a pointer-typed icmp threads `ptr_cells=true` to both
operands + width 64, and admits **ONLY `:eq`/`:ne`**; the 8 ordering predicates FAIL LOUD —
address-magnitude comparison over virtual cells is BVM-allocation-layout-dependent (UB across
allocations in C), a Rule-1 silent-miscompile risk. The fdict check is `ne` → admitted.
Non-pointer / `ptr_cells=false` icmp is byte-identical.

**Done (`src/extract/instructions.jl`, ICmp arm only).** A ptr-operand branch under the gate
(eq/ne guard + `_operand(...; ptr_cells=true)` + width 64); the integer path unchanged (only
`pred` hoisted to a local). No `ir_types.jl`/`helpers.jl`/`lower.jl` change. New
`test/test_8g7m_ptr_icmp_cells.jl` (47 structural-invariant assertions: eq/ne null, ptr-vs-ptr
eq, ordering reject, `ptr_cells=false` byte-identity, non-pointer integer-icmp unchanged,
rehash! wall-advance). Registered in `runtests.jl`.

**Verified (orchestrator re-ran the FULL `ptr_cells`-real-fn set — the u2kk lesson, below).**
`test_8g7m` 47/47, `test_lf14` 27/27, `gate_count` 39/39 IDENTICAL, `test_beaw` 17/17,
`test_6bu3` 162/162, `test_59zi` 545/545, `test_ares` 57/57, `test_zf5v` 17/17, `test_nd45`
71/71, `test_d1b` 30+1-broken. **lf14 + beaw passed WITHOUT disjunction edits** — their
inclusive successor-disjunctions already catch the new wall. **Producer advanced:** rehash!
clears the ptr-null ICmp wall → next wall **`Bennett-yd4f`** (`i64 undef` phi operand,
helpers.jl:172, Bennett-bjdg / U80 family). Cross-repo: no new BVM contract (pointer eq/ne
lowers to an ordinary i64 cell compare). Recorded on `bennettvm-416r.11`.

---

## Session wind-up — 2026-06-29 — fdict CW-D triple (xrd6 → u2kk → 8g7m) + HANDOFF

**Three beads landed this session, each a full 3+1 + adversarial cycle on the P0 fdict path:**

| Bead | Wall cleared | Commit | Gate |
|---|---|---|---|
| `Bennett-xrd6` | sret-convention consumed call (`ht_keyindex2_shorthash!` `{i64,i8}` via sret → void) | `c884ce5` | full `Pkg.test()` green (689,876) |
| `Bennett-u2kk` | param-cell global-src memcpy (`rehash!` idxfloor/ndel/maxprobe field inits) | `77faf89` | full green (689,891) after a recovery — see below |
| `Bennett-8g7m` | ptr-typed `icmp` (Dict-field null check) | committed; full-gate push launched at wind-up | ptr_cells-real-fn set green; full gate pending |

**The u2kk gate-failure recovery (institutional memory).** u2kk's first push FAILED the full
`Pkg.test()` gate: I had OMITTED `test_lf14_ptr_return_cells.jl` from u2kk's targeted
regression subset. lf14 GATE-B pins each callee's per-wall LANDING via an `occursin`
disjunction; u2kk advanced rehash! past the memcpy wall to the ptr-null wall, which the
disjunction didn't list → fail. (My first gate-capture used `| tail -25` and LOST the failure
details; re-ran with full capture to pinpoint `lf14:179`.) Fixed by adding `null`/`U80`
disjuncts (a legitimate expectation update, not a weakening), bundled into the u2kk commit,
re-pushed green. **Lesson banked in `bd remember cwd-ptr-cells-rerun-lf14`:** any change to a
callee's `ptr_cells` extraction MUST re-run `test_lf14` + the `ptr_cells`-real-fn set
(test_6bu3/59zi/ares/zf5v/lf14/nd45) before pushing — the full gate is the real net; targeted
subsets are necessary but not sufficient. (For 8g7m I applied this: ran the whole set, all green.)

**fdict CW-D frontier (where the next session resumes).** `extract_parsed_ir_set_from_julia(fd; ptr_cells=true)`
where `fd(k,v)=(d=Dict{Int8,Int8}();d[k]=v;d[k])` now extracts `setindex!` +
`ht_keyindex2_shorthash!`; the `rehash!` callee is the active wall-by-wall front. After
xrd6/u2kk/8g7m, rehash! lands on:
- **`Bennett-yd4f` (P2, NEXT):** `i64 undef` phi operand under ptr_cells (helpers.jl:172).
  Caution: undef ≠ null (undef = ANY value, UB to read) — the soundness story is subtler than
  8g7m's null→0; a fully-designed 3+1 is warranted.
- Under `--check-bounds=yes` (suite mode), `setindex!` itself still walls earlier at the
  pre-existing iwo9 ptrtoint artifact (`Bennett-kvdv`) — orthogonal, already filed.

**Open follow-ups filed this session:** `Bennett-yd4f` (next wall), `Bennett-h7r2` (P3 — harden
the global-src memcpy arm: byval-param discrimination + K>1 chunk-stacking + dst-cell bounds,
u2kk verifier nits). Standing: `Bennett-amah` (dolt `noms` blob now 56.9 MB — GitHub 50 MB soft
warning; compaction needed before the 100 MB hard limit).

**Cross-repo BVM (BennettVM-416r.11) contracts recorded for D1c:** the consumed-sret IRCall
(xrd6) and the param-cell field-write (u2kk) both require BVM to tape `(cell, pre-image)` and
reverse for **caller-supplied pointer-parameter cells (by-reference)** — the SAME contract
`setindex!`'s field stores already depend on (surfaced, not introduced). 8g7m adds no new BVM
contract. These are producer-side-unprovable; D1c must assert them with a round-trip.

**State at wind-up:** xrd6 + u2kk pushed (origin/main = `77faf89`). 8g7m committed locally +
full-gate push launched in background (the pre-push hook gates main — it pushes only if the
full suite is green; if a test fails, the commit stays local for the next session to fix).
BennettVM pushed (`81c66dd`). All beads synced; worklog + handoff here.
