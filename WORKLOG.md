# Bennett.jl Work Log

> # 🚨 NEXT AGENT — START HERE 🚨
>
> **Read [`worklog/058_2026-05-04_ckvj_soft_asin.md`](worklog/058_2026-05-04_ckvj_soft_asin.md) FIRST** — 2026-05-04, **Bennett-ckvj close** (Tier C1.3 — third close in trig completion, follow-on to qpke/atan and s1zl/tan from earlier the same day). `soft_asin` = faithful musl `e_asin.c` port (FreeBSD/Sun 1993, BSD); `llvm.asin.f64` direct dispatch. **≤2 ULP vs `Base.asin` on 100k random samples × 3 seeds; 1075-input subnormal binade sweep at 0 ULP.** Five gotchas captured incl. (a) `Base.asin` THROWS DomainError on |x|>1 not NaN — random sweep needs separate OOB testset, (b) Path C₂'s 0/0 at |x|=1 is masked by override ordering, (c) `_asin_R(z)` helper module-private and **shared with `soft_acos`** (Bennett-bd7f, NEXT) per CLAUDE.md §12, (d) single ifelse-selected R-call avoids qpke SLP-vectorisation gotcha, (e) tiny + eq1 overrides give bit-exact (0-ULP) at ±0/±1. `_CALLEES_FP_TRANS` extended 16 → 17. `Bennett-Enzyme-Parity-NorthStar.md` Tier C1 updated (3 of 11 done). 9 C1 siblings remain; **`bd7f` (acos) is the cheapest next pickup** — reuses `_asin_R` + 10 R-coefficients + `pio2_hi`/`pio2_lo` verbatim from `fasin.jl`.
>
> **Then read [`worklog/057_2026-05-04_s1zl_soft_tan.md`](worklog/057_2026-05-04_s1zl_soft_tan.md)** — 2026-05-04, two entries top-down: **Bennett-qpke close** (Tier C1.2 — `soft_atan` + `llvm.atan` dispatch; faithful musl `atan.c` branchless port, self-contained no `_rp_rem_pio2` dependency; max ULP ≤ 2 on 500k random + 1076-input subnormal binade at 0 ULP; gotcha #1 = SLP-vectorisation trap on parallel `soft_fdiv` calls, fix is one fdiv on ifelse-selected num/den). Below it: **Bennett-s1zl close** (Tier C1.1 — `soft_tan` + `llvm.tan` dispatch; musl `__tan` port reusing `_rp_rem_pio2` from `fsin.jl`; max ULP = 1 on 500k random samples; SET_LOW_WORD odd-arm precision trick from musl).
>
> **Then read [`worklog/056_2026-05-03_37mt_memcpy_phase1.md`](worklog/056_2026-05-03_37mt_memcpy_phase1.md)** — 2026-05-03 late evening, top entry: **Bennett-8bys research/scope-split + Bennett-munq close**. Empirical scan of t5_tr2_hashmap.ll: 60 memcpy sites, ALL using `alloca [N x i8]` ArrayType (silently dropped pre-munq) — Phase 1+2 covered ZERO of them without ArrayType extraction. 8bys split into 6 sub-beads (munq P2; ixiz/xtu9/yxr8/zmry/doih all P3); 8bys kept open as umbrella. Bennett-munq close: ~30 LOC extension to `_alloca_elem_width_bits` + alloca dispatch in `instructions.jl`; 61 testset asserts; 3+1 deviation documented (mechanical extension, design space catalogued by corpus survey). 1186 asserts green in targeted sweep. Below it: **Bennett-9nwt close** (Bennett-hao Phase 2): const-c const-N memset on alloca-i8-backed dst. `_handle_memset_arm` + `_alloca_is_fresh` (~210 LOC) added; `llvm.memset` removed from benign list. 13-predicate cascade with two no-op short-circuits (N=0, c=0). 82 testset asserts / 9 testsets (3 green case A + C, 6 reject). 3+1 synthesis: option γ (intra-block freshness sweep) for c≠0 path, option β (preserve pre-9nwt broad tolerance) for c=0 fast-path. Below it: **Bennett-37mt close** (Phase 1: const-size memcpy): const-size memcpy between distinct `alloca i8`-backed pointers lowers to N byte-granular IRPtrOffset+IRPtrOffset+IRLoad+IRStore quads. `src/extract/instructions.jl` gains `_handle_memcpy_arm` + helpers `_alloca_root_ref` / `_alloca_elem_width_bits` (~155 LOC). 8 testset / 80 assertions across 3 green paths (N=4/8/24, identity oracle clean for `Int8(-8):Int8(8)`) + 5 reject paths (volatile / variable-N / same-alloca / alloca-i64 elem_w mismatch / memmove). Big gotcha: the bead's "(N/8) at 64-bit granularity, memory.jl unchanged" wording was internally inconsistent — `aggregate.jl:227` (`ew == 8 || continue`) and `memory.jl:245-246` (`inst.width == elem_w`) force byte-granular chunks on `alloca i8`. Honest scope tightening, not creep. hao still open; closes when 9nwt + 8bys close.
>
> **Then read [`worklog/055_2026-05-03_3mo_sin_cos.md`](worklog/055_2026-05-03_3mo_sin_cos.md)** — 2026-05-03, **Bennett-3mo close**: full musl `sin.c` / `cos.c` / `__rem_pio2.c` / `__rem_pio2_large.c` port with full Payne-Hanek argument reduction. `src/softfloat/fsin.jl` (~770 LOC) houses both `soft_sin` and `soft_cos`; LLVM dispatch entries for `llvm.sin.*` / `llvm.cos.*` route raw .ll/.bc ingest to them. **100k random sweep (3 seeds, 5 magnitude buckets up to 1e22): cos max ULP = 0, sin max ULP = 1, 0 fails > 2 ULP.** 1076-input subnormal-INPUT sin sweep bit-exact. soft_sin compiles to ~11M reversible gates (verified, all simulate inputs bit-exact vs Base.sin). Big gotcha: native UInt128 in compile-to-gates code emits i128 constants which Bennett rejects (Bennett-l9cl) — even though Bennett-yys3 said UInt128 ops compile. The (hi, lo) UInt64-pair representation is mandatory for paynehanek + fromfraction. Five other gotchas captured at the chunk top. _CALLEES_FP_TRANS extended 12 → 14.
>
> **Then read [`worklog/054_2026-05-02_soft_log.md`](worklog/054_2026-05-02_soft_log.md)** — 2026-05-02, top entry: **Bennett-jexo close** (`soft_pow_julia` Path A — line-for-line port of `Base.:^(::Float64, ::Float64)` using Julia's `_log_ext` + extended `exp_impl(x, xlo)` kernels; `Base.:^(::SoftFloat, ::SoftFloat)` routes to it; LLVM `llvm.pow.f64` dispatch keeps using `soft_pow` musl for raw .ll/.bc ingest; **300,000 / 300,000** random samples bit-exact vs `Base.:^`; integer-y bug pinned and fixed via `muladd→mul+add` distinction at `@noinline` sites). Below it: **Bennett-582 + Bennett-emv close** — branchless ports of Arm Optimized Routines / musl: `flog.jl` (~310 LOC, log + log2 + log10), `fpow.jl` (~700 LOC, soft_pow + soft_powi). soft_log: 100% bit-exact vs `Base.log` on 100k samples. soft_pow: 99.17% bit-exact, 0% above 2 ULP across 13k extreme bivariate samples, tracks musl/glibc pow via ccall. LLVM dispatch entries for `llvm.log` / `llvm.log2` / `llvm.log10` / `llvm.pow.f64` / `llvm.powi.f64.i32`; Float32 forms rejected per §13. Per-bead regression tests + `.ll` fixtures ship alongside. _CALLEES_FP_TRANS extended 6 → 12.
>
> **Then read [`worklog/053_2026-05-01_dnh_research_nj6c.md`](worklog/053_2026-05-01_dnh_research_nj6c.md)** — 2026-05-01 late late evening, four entries top-down: **Tier A grind: Bennett-h6f + Bennett-4eu + Bennett-imz7 closed** (`llvm.fma`/`fmuladd` direct dispatch via existing `soft_fma`; `indirectbr` declared a Bennett hard stop with precise fail-loud error; ~24 vpch sites tightened from generic `error()` to typed exceptions across 8 src files + 9 test files; Pkg.test 487,167 pass), then **Bennett-cb9y + Bennett-dnh close → OPCODE PARITY for runtime-indexed memory** (multi-origin × runtime-idx walls closed at `memory.jl:141` and `aggregate.jl:362` via `extern_pred_wire` kwarg + synthetic-IRLoad pattern; covers MUX-EXCH AND shadow_checkpoint multi-origin shapes; `Bennett-dnh` itself closes — every load/store/GEP at runtime SSA index compiles, single-origin OR multi-origin, all shapes; Pkg.test 487,151 pass / 0 fail / 3 broken), then **Bennett-nj6c close** (dnh phase 1a — `_MUX_SHAPES_NW` extended to all (N,W) with N·W ≤ 64), then **Bennett-dnh research/re-scope** (six-agent research sweep on 2026-05-01 evening). Bennett's LLVM memory-opcode coverage now matches Enzyme's (modulo correctly-hard-stop atomics/EH). Open follow-ups (NOT opcode gaps): **Bennett-8guh** (IRSwap, P2, 3+1) and **Bennett-6c6f** (QROAM cost win, P3). Below it in chunk 052: **Bennett-1pb close** (direct `llvm.sqrt.f64` / `llvm.exp.f64` / `llvm.exp2.f64` dispatch), **Bennett-kv7b / U65 close** (test-coverage epic), **Bennett-i2ca / U55 close** (`bennett(lr; strategy=...)`).
>
> **Then read [`worklog/051_2026-05-01_eleven_close_grind.md`](worklog/051_2026-05-01_eleven_close_grind.md)** — 2026-05-01 afternoon grind, **11 catalogue closes** in one session, hardest-first: **iwv5** (U90, softfloat/persistent → `module SoftFloatLib` / `module Persistent`); **u71l** (U161, `CompileOptions` struct + opts-form `reversible_compile` overloads); **x2iw** (U88, `BlockLoweringOpts` bundle replaces 11 kwargs on `lower_block_insts!` / `lower_loop!`); **u2yp** (U149, drop sat_pebbling.jl + PicoSAT dep); **vpch** (U45, ~146 `error()` → `ArgumentError` / `DimensionMismatch` / `AssertionError` codemod across 29 src files); **3rph** (U137, Float32 double-rounding deviation documented; native f32 filed as Bennett-e283); **gk1h** (U210, Aqua.jl + JET.jl hygiene gates); **fidj** (U217, `:auto` × liveness invariance pinned); **58rl** (U214, dolt-cache commit-bundling convention documented); **sa39** (U211, BenchmarkTools-based compile-time bench); **8403** (U159, per-source-file unit-test homes for Bennett.jl/lower.jl/ir_extract.jl + PER_SOURCE_INDEX.md). All 419291+ tests pass; gate counts unchanged. **Catalogue is now 1.7 % open** (3 of 173 beads): 25dm blocked on z2dj, i2ca needs 3+1, kv7b epic ongoing.
>
> **Then read [`worklog/050_2026-05-01_v958_ehoa_lm3x.md`](worklog/050_2026-05-01_v958_ehoa_lm3x.md)** — 2026-05-01 morning grind, 4 catalogue closes: **s92x** (U115, SretInfo struct + _collect_sret_writes decomposition); **lm3x** (U56, MUX load/store @eval consolidation, ~110 LOC deleted, single `_MUX_SHAPES_NW` source); **ehoa** (U43, LoweringCtx ::Any → concrete dict types); **v958** (U68, IROperand tagged-union → abstract type hierarchy via 3+1 protocol with 4 sentinel singletons, 47 `.kind` sites eliminated). All 419,228 tests pass, gate counts unchanged at every site.
>
> **Then read [`worklog/049_2026-04-30_vdlg_x3jc_zpj7_kv7b.md`](worklog/049_2026-04-30_vdlg_x3jc_zpj7_kv7b.md)** — 2026-04-30 grind, three structural splits + four kv7b sub-items shipped: **vdlg** (`lower.jl` 3,172 → 9 files under `src/lowering/`), **x3jc** (`ir_extract.jl` 2,946 → 9 files under `src/extract/`), **zpj7** (5 pebbling/eager files → `src/pebble/`), kv7b sub-items #05 F19 (loop tests Int8 → all widths), #03 F8/F15/F16 + #05 F15 (SHA-256 / mul-dispatcher / vector_ir tests sampled → exhaustive). Net +263k test asserts.
>
> **Read [`worklog/048_2026-04-27_1xub_persistent_ds_refresh.md`](worklog/048_2026-04-27_1xub_persistent_ds_refresh.md) NEXT** — top entry is the **2026-04-28 LOC-tier grind summary** (**51 beads closed**; net -16,700 LOC). Substantive 30: qxg9 P2 perf-bug fix at 33× compile-time speedup; P3 fehu simulate! 2.7× speedup, 2hhx soft_round, is5s diagnose_nonzero, g7r8 regression check, **19g6 Bennett.jl 545→270 LOC split**, plus 9 more; P4 incl. xgf6 BENCHMARKS -42%/-34%, mg6u/s8gs/nj5r polish, 4nvl gitignore -17,818 LOC, plus 6 stale-bead closes. Plus 21 LLVM-opcode/intrinsic verify-or-fail-loud closes. Plus kv7b epic partial (5 of 19 sub-items, +11 test asserts). Below it: the 2026-04-28 qxg9 close detail, then 2026-04-27 qxg9 bisect data and 1xub close. Then [`worklog/047_2026-04-27_heup_fold_constants_doc_only.md`](worklog/047_2026-04-27_heup_fold_constants_doc_only.md) (7 prior 2026-04-27 entries: tzrs stage-1 → tbm6 → 7xng → cvnb → jc0y → q04a → heup).
>
> **State of the bug backlog (2026-04-28):** qxg9 closed today. Only 3 `[bug]` beads remain: `25dm` (P2, blocked on `z2dj` IN-PROGRESS T5-P6 dispatcher), `ponm` (P2, bd-tool schema bug — NOT a Bennett.jl source bug), `cc0.5` (P2 IN-PROGRESS — Julia TLS allocator GEP base, T5-P6.3 multi-language ingest, multi-session scope per its own notes).
>
> **Active mode: structural / LOC refactors.** User explicitly lifted the bugs-only directive 2026-04-27 evening. Today's grind (2026-04-28) closed **51 beads** + kv7b partials, net -16,700 LOC — see chunk 048 top entry. Yesterday's (2026-04-27) closes:
> - `7xng` — LoweringResult.constant_wires dead-store removal (-45 LOC)
> - `cvnb` — bennett_direct + self_reversing discoverability (Sturm.jl-ao1)
> - `tbm6` — Karatsuba multiplier removed (~250 LOC delete)
> - `tzrs` stage-1 — `_handle_intrinsic` extracted via 3+1 protocol (still OPEN; stages 2-5 deferred per CLAUDE.md §11)
>
> **Active rule of thumb:** any change to `lower.jl` / `ir_extract.jl` / `bennett_transform.jl` / `gates.jl` / `ir_types.jl` / phi resolution → **3+1 protocol per CLAUDE.md §2** (2 parallel `Plan` proposers, synthesise, implement, review). Otherwise → direct grind. Always pair `verify_reversibility` with an output-vs-Julia-oracle assertion — `verify_reversibility` does NOT check semantic correctness (see today's 3of2 close + the chunk-045 directive).
>
> **Suggested next pickups** (all P2/P3 non-bug, most need 3+1 because they touch core files):
>   - `vdlg` (P2) — lower.jl 2,662 LOC structural split
>   - `tzrs` stages 2-5 — remaining `_convert_instruction` arms (medium priority; stage 1 already shipped most of the value)
>   - `x3jc` (P3) — ir_extract.jl 2,394 LOC similar to vdlg
>   - `ehoa` second-half (P2) — `LoweringCtx` `::Any` field concretization (the back-compat-ctor half of ehoa was closed as a drive-by during tbm6)
>   - `s92x` (P3) — `_detect_sret` 173-line soup
>   - `vt0a` (P3) — Bennett-aware wire allocator (algorithmic; needs careful design)
>
> Smaller / contained next-tier work (no 3+1):
>   - `qjet` — empirical timing-based reorder of test/runtests.jl (carries test-ordering risk)
>   - `19g6` — src/Bennett.jl 297-line junk drawer (refactor target ≤80 LOC)
>   - `iwv5` — wrap softfloat/persistent in proper modules (touches namespace; high blast radius)
>   - `zpj7` — pebbling/eager file naming consistency
>   - `2hhx` — soft_round (roundToIntegralTiesToEven) implementation
>   - `3rph` — Float32 native arithmetic (currently fpext→f64→fptrunc)
>   - `u2yp` — sat_pebbling.jl: wire (via fg2) or drop the PicoSAT dep
>   - `u71l` — CompileOptions struct (565 callers; deferred 2026-04-28, needs careful design)
>
> Older session logs are sharded into ~200-300 line chunks under `worklog/`, file-numbered chronologically (000 = oldest, 047 = newest as of 2026-04-27).

This file is now an **index** — historical content was sharded out of the
monolithic 9,774-line `WORKLOG.md` per Bennett-fyni / U70. Concatenating the
chunk files in REVERSE filename order (`037 → 036 → … → 000`) reproduces the
original byte-for-byte; `scripts/shard_worklog.py` is the canonical re-shard
tool.

## Adding new entries

When you finish a session, **prepend** a `## Session log — YYYY-MM-DD — …`
block to the current top chunk file (today: `worklog/038_*.md`). When that
file passes ~280 lines, create a new chunk file with the next sequential
`NNN_` prefix and start prepending there. The next agent should always be
able to read the highest-numbered file first to find the latest state.

Re-running `python3 scripts/shard_worklog.py` re-flows everything if structure
drifts; it verifies byte-for-byte that the reverse-concatenation matches the
sum of all chunk files.

## Session-log template (per Bennett-fyni / U70)

Separate "what shipped" (already in git log) from durable knowledge (gotchas,
rejected paths, hand-off pointers). Avoid restating the diff:

```markdown
## Session log — YYYY-MM-DD — Bennett-<id> / U## <one-line summary>

**Shipped:** see git log around <commit-sha>; <one-line summary of intent>.

**Why:** <motivation / context not derivable from the diff>

**Gotchas / Lessons:** <surprising findings worth keeping for future sessions>

**Rejected alternatives:** <approaches tried and why they didn't work>

**Next agent starts here:** <one-line pointer to the next concrete step>
```

## Index — newest first

| File | Lines | First section |
|---|---:|---|
| [058_2026-05-04_ckvj_soft_asin.md](worklog/058_2026-05-04_ckvj_soft_asin.md) | ~165 | Session log — 2026-05-04 — **Bennett-ckvj close** (Tier C1.3 — `soft_asin` + `llvm.asin` dispatch). Faithful musl `e_asin.c` port, branchless. ≤2 ULP vs `Base.asin` on 100k random × 3 seeds; 1075-input subnormal binade at 0 ULP. Five gotchas captured incl. `Base.asin` OOB-throws-not-NaN, override-ordering masking 0/0 at \|x\|=1, R(z) helper shared with `soft_acos` per §12. _CALLEES_FP_TRANS extended 16 → 17. |
| [057_2026-05-04_s1zl_soft_tan.md](worklog/057_2026-05-04_s1zl_soft_tan.md) | ~240 | Session log — 2026-05-04 — two entries top-down: **Bennett-qpke close** (Tier C1.2 — `soft_atan` + `llvm.atan` dispatch; max ULP ≤ 2 on 500k random) + **Bennett-s1zl close** (Tier C1.1 — `soft_tan` + `llvm.tan` dispatch; max ULP = 1 on 500k random). _CALLEES_FP_TRANS extended 14 → 15 → 16. |
| [056_2026-05-03_37mt_memcpy_phase1.md](worklog/056_2026-05-03_37mt_memcpy_phase1.md) | ~430 | Session log — 2026-05-03 evening — three concatenated entries (newest first): **Bennett-8bys research/scope-split + Bennett-munq close** (8bys split into 6 sub-beads; munq landed `[N x i8]` ArrayType extraction, 61 asserts), **Bennett-9nwt close** (Phase 2 memset, 82 asserts), **Bennett-37mt close** (Phase 1 memcpy, 80 asserts). Total Bennett-hao progress: lqif/37mt/9nwt/munq closed; ixiz/xtu9/yxr8/zmry/doih open under 8bys umbrella. |
| [055_2026-05-03_3mo_sin_cos.md](worklog/055_2026-05-03_3mo_sin_cos.md) | ~210 | Session log — 2026-05-03 — **Bennett-3mo close**: `soft_sin` / `soft_cos` (musl + full Payne-Hanek). 100k random sweep cos=0 ULP, sin=1 ULP, 0 fails > 2 ULP. Five gotchas captured incl. UInt128-constant rejection. |
| [054_2026-05-02_soft_log.md](worklog/054_2026-05-02_soft_log.md) | ~370 | Session log — 2026-05-02 — top: **Bennett-jexo close** (`soft_pow_julia` Path A: bit-exact vs `Base.:^`; `Base.:^(::SoftFloat,::SoftFloat)` routes to it; 300k/300k random samples bit-exact; muladd↔mul+add gotcha at `@noinline` sites). Below it: **Bennett-582 close** (log family) + **Bennett-emv close** (`soft_pow` / `soft_powi` musl + `llvm.pow` / `llvm.powi` dispatch). |
| [053_2026-05-01_dnh_research_nj6c.md](worklog/053_2026-05-01_dnh_research_nj6c.md) | ~265 | Session log — 2026-05-01 (late evening) — **Bennett-cb9y + Bennett-dnh close → OPCODE PARITY for runtime-indexed memory** (multi-origin × runtime-idx walls closed; dnh itself closes), **Bennett-nj6c close** (dnh phase 1a — `_MUX_SHAPES_NW` extended to all (N,W) with N·W ≤ 64), **Bennett-dnh research/re-scope** (six-agent research sweep). |
| [052_2026-05-01_i2ca_strategy_dispatch.md](worklog/052_2026-05-01_i2ca_strategy_dispatch.md) | ~250 | Session log — 2026-05-01 (evening) — top: **Bennett-kv7b / U65 close** (test-coverage epic; 8 final sub-items batched: test_two_args 256→exhaustive, persistent-map bounds, dep_dag semantics, memssa end-to-end, add×mul cross, controlled × soft-float). Below: **Bennett-i2ca / U55 close** (`bennett(lr; strategy=...)` dispatch via `abstract type BennettStrategy` + 6 subtypes; 5 legacy aliases as forwarders; helpers extracted; 3+1 protocol). |
| [051_2026-05-01_eleven_close_grind.md](worklog/051_2026-05-01_eleven_close_grind.md) | ~559 | Session log — 2026-05-01 (afternoon) — **11 catalogue closes**: iwv5/u71l/x2iw/u2yp/vpch/3rph/gk1h/fidj/58rl/sa39/8403. Catalogue 98 % closed at session end. |
| [050_2026-05-01_v958_ehoa_lm3x.md](worklog/050_2026-05-01_v958_ehoa_lm3x.md) | ~439 | Session log — 2026-05-01 (morning) — 4 catalogue closes (s92x U115 SretInfo struct; lm3x U56 MUX consolidation; ehoa U43 LoweringCtx concretization; v958 U68 IROperand abstract hierarchy via 3+1). All 419k tests pass. |
| [049_2026-04-30_vdlg_x3jc_zpj7_kv7b.md](worklog/049_2026-04-30_vdlg_x3jc_zpj7_kv7b.md) | ~150 | Session log — 2026-04-30 (continuation 2) — kv7b grind 3 more sub-items (SHA-256 + mul dispatcher + vector_ir → exhaustive), preceded by x3jc + zpj7 + kv7b loop-widths, preceded by vdlg lower.jl 9-file split. Three structural splits + four kv7b sub-items in one day. |
| [048_2026-04-27_1xub_persistent_ds_refresh.md](worklog/048_2026-04-27_1xub_persistent_ds_refresh.md) | ~235 | Session log — 2026-04-28 — LOC-tier grind (51 beads closed + kv7b epic partials); below it: 2026-04-28 qxg9 close detail, 2026-04-27 qxg9 bisect data, 1xub close. |
| [047_2026-04-27_heup_fold_constants_doc_only.md](worklog/047_2026-04-27_heup_fold_constants_doc_only.md) | ~380 | Session log — 2026-04-27 (3+1 refactor, stage 1) — Bennett-tzrs partial (extract _handle_intrinsic) — followed by 6 more 2026-04-27 sessions: tbm6 / 7xng / cvnb / jc0y / q04a / heup |
| [046_2026-04-27_y986_loop_header_dispatch.md](worklog/046_2026-04-27_y986_loop_header_dispatch.md) | ~510 | Session log — 2026-04-27 — Bennett-y986 / U05-followup-2 close (loop-header dispatch unification) |
| [045_2026-04-27_day_summary_bugs_only_directive.md](worklog/045_2026-04-27_day_summary_bugs_only_directive.md) | 283 | Session log — 2026-04-27 — Bennett-salb / U119 close (div-by-0 + signed typemin/-1 contract) |
| [044_2026-04-26_late_night_doh6.md](worklog/044_2026-04-26_late_night_doh6.md) | 282 | Session log — 2026-04-27 (early morning) — Bennett-3of2 / U112 close (wire-leak investigated, doc-only) + Bennett-vt0a filed |
| [043_2026-04-26_late_afternoon_wlf6_6u9q.md](worklog/043_2026-04-26_late_afternoon_wlf6_6u9q.md) | 274 | Session log — 2026-04-26 (late night) — 9c4o close (lower.jl deps load before lower.jl) |
| [042_2026-04-26_midday_d1ee_f6qa.md](worklog/042_2026-04-26_midday_d1ee_f6qa.md) | 270 | Session log — 2026-04-26 (afternoon) — hjbf + 8p0g closes (Contributing section + ParsedIR seam test) |
| [041_2026-04-26_morning_069e_k7al.md](worklog/041_2026-04-26_morning_069e_k7al.md) | 270 | Session log — 2026-04-26 (late-morning) — 8kno + zy4u closes (LLVM.initializer narrowing + outer @testset) |
| [040_2026-04-25_late_night_348q_tfo8.md](worklog/040_2026-04-25_late_night_348q_tfo8.md) | 280 | Session log — 2026-04-26 (early morning) — uzic + uinn closes (citations + InterruptException narrowing) |
| [039_2026-04-25_evening_softfloat_grind.md](worklog/039_2026-04-25_evening_softfloat_grind.md) | 250 | Session log — 2026-04-25 (post-night) — 6t8s + ej4n closes (mechanical rename + callee ParsedIR cache) |
| [038_2026-04-25_uoem_persistent_ds_research_relocation.md](worklog/038_2026-04-25_uoem_persistent_ds_research_relocation.md) | 269 | Session log — 2026-04-25 (afternoon) — catalogue grind, 13 P2 beads cleared |
| [037_2026-04-25_preamble.md](worklog/037_2026-04-25_preamble.md) | 280 | Session log — 2026-04-25 — Bennett-jppi deferred, Bennett-p1h1 README Project-status refresh |
| [036_2026-04-24_…_evening_session_close.md](worklog/036_2026-04-24_next_agent_start_here_evening_session_close.md) | 315 | NEXT AGENT — start here — 2026-04-24 (evening session close) |
| [035_2026-04-24_session.md](worklog/035_2026-04-24_session.md) | 259 | Session — 2026-04-24 |
| [034_2026-04-22_…_catalogue_beads_phase.md](worklog/034_2026-04-22_next_agent_previous_context_catalogue_beads_phase.md) | 579 | (continuation of 033 — single monolithic narrative; one of the few outliers > 300 lines that resists clean splitting) |
| [033_2026-04-22_…_catalogue_beads_phase.md](worklog/033_2026-04-22_next_agent_previous_context_catalogue_beads_phase.md) | 196 | NEXT AGENT — start here — 2026-04-21 (mother-of-all code review landed) |
| [032_2026-04-21_…_t5_p6_unblocked.md](worklog/032_2026-04-21_next_agent_shipped_t5_p6_unblocked_earlier_in_day.md) | 151 | NEXT AGENT — 2026-04-21 (α+β+γ shipped; T5-P6 unblocked) — earlier in day |
| [031_2026-04-21_…_sret_callee_infrastructure.md](worklog/031_2026-04-21_session_log_sret_callee_infrastructure.md) | 303 | Session log — 2026-04-21 — α + β + γ (sret + callee infrastructure) |
| [030_2026-04-21_…_t5_p5_multi_language.md](worklog/030_2026-04-21_session_log_bennett_lmkb_bennett_f2p9_closed_t5_p5.md) | 196 | Session log — 2026-04-21 — Bennett-lmkb + Bennett-f2p9 (T5-P5a + P5b multi-language ingest) |
| [029_2026-04-21_…_cc0_4_constantexpr_icmp.md](worklog/029_2026-04-21_session_log_bennett_cc0_4_closed_constantexpr_icmp.md) | 268 | Session log — 2026-04-21 — Bennett-cc0.4 closed (ConstantExpr icmp folding) |
| [028_2026-04-20_…_cc0_7_slp_vectorised.md](worklog/028_2026-04-20_session_log_bennett_cc0_7_closed_slp_vectorised_ir.md) | 134 | Session log — 2026-04-20 — Bennett-cc0.7 closed (SLP-vectorised IR support) |
| [027_2026-04-16_…_m1_m2_m3_landed.md](worklog/027_2026-04-16_next_agent_start_here_m1_m2a_d_m3a_landed_m3b_or_m.md) | 263 | NEXT AGENT — start here — 2026-04-16 (M1 + M2a-d + M3a landed) |
| [026_2026-04-20_…_persistent_ds_scaling_sweep.md](worklog/026_2026-04-20_session_log_persistent_ds_scaling_sweep_phase_3_co.md) | 225 | Session log — 2026-04-20 — Persistent-DS scaling sweep (Phase-3 reversed at scale) |
| [025_2026-04-17_…_t5_phase_3_complete.md](worklog/025_2026-04-17_session_log_t5_phase_3_complete_p3a_interface_p3b.md) | 241 | Session log — 2026-04-17 — T5 Phase 3 complete (P3a + P3b/c/d 3 persistent-DS impls) |
| [024_2026-04-16_…_m3a_shadow_checkpoint.md](worklog/024_2026-04-16_session_log_m3a_bucket_a_b_spillover_t4_shadow_che.md) | 167 | Session log — 2026-04-16 — M3a Bucket A/B-spillover T4 shadow-checkpoint MVP (Bennett-jqyt) |
| [023_2026-04-16_…_m2d_mux_store_gating.md](worklog/023_2026-04-16_session_log_m2d_bucket_c3_mux_store_gating_bennett.md) | 223 | Session log — 2026-04-16 — M2d Bucket C3 MUX-store gating (Bennett-i2a6) |
| [022_2026-04-16_…_m2b_pointer_typed_phi.md](worklog/022_2026-04-16_session_log_m2b_bucket_c2_pointer_typed_phi_select.md) | 273 | Session log — 2026-04-16 — M2b Bucket C2 pointer-typed phi/select (Bennett-tzb7) |
| [021_2026-04-16_…_m1_parametric_mux_exch.md](worklog/021_2026-04-16_session_log_m1_bucket_a_parametric_mux_exch_green.md) | 210 | Session log — 2026-04-16 — M1 Bucket A (parametric MUX EXCH) GREEN |
| [020_2026-04-16_…_m2a_cross_block_ptr.md](worklog/020_2026-04-16_session_log_m2a_bucket_c1_cross_block_ptr_provenan.md) | 318 | Session log — 2026-04-16 — M2a Bucket C1 cross-block ptr_provenance |
| [019_2026-04-16_…_soft_fma.md](worklog/019_2026-04-16_session_log_soft_fma_ieee_754_binary64_fma_bennett.md) | 263 | Session log — 2026-04-16 — soft_fma (IEEE 754 binary64 FMA) (Bennett-0xx3) |
| [018_2026-04-16_…_soft_exp_subnormal_fix.md](worklog/018_2026-04-16_session_log_soft_exp_soft_exp2_bit_exact_subnormal.md) | 167 | Session log — 2026-04-16 — soft_exp / soft_exp2 bit-exact subnormal output via musl specialcase |
| [017_2026-04-16_…_soft_exp_base_exp.md](worklog/017_2026-04-16_session_log_soft_exp_soft_exp2_base_exp_softfloat.md) | 292 | Session log — 2026-04-16 — soft_exp / soft_exp2 + Base.exp(::SoftFloat) (Bennett-cel) |
| [016_2026-04-15_…_soft_fsqrt_base_sqrt.md](worklog/016_2026-04-15_session_log_soft_fsqrt_base_sqrt_softfloat_bennett.md) | 316 | Session log — 2026-04-15 — soft_fsqrt + Base.sqrt(::SoftFloat) (Bennett-ux2) |
| [015_2026-04-14_…_workstream_complete.md](worklog/015_2026-04-14_session_log_continuation_workstream_complete.md) | 264 | Session log — 2026-04-14 (continuation) — advanced-arithmetic workstream complete |
| [014_2026-04-13_…_bc_3_full_sha256_sret.md](worklog/014_2026-04-13_session_log_bc_3_full_sha_256_sret_support.md) | 319 | Session log — 2026-04-13 — BC.3 full SHA-256 + sret support |
| [013_2026-04-09_session_log.md](worklog/013_2026-04-09_session_log.md) | 210 | Session log — 2026-04-09 |
| [012_2026-04-09_…_v0_5_float64.md](worklog/012_2026-04-09_session_log_continued_v0_5_float64.md) | 140 | Session log — 2026-04-09 (continued): v0.5 Float64 |
| [011_…_research_overflow_false_path.md](worklog/011_9999-99-99_research_overflow_simulation_bug_false_path_proble.md) | 220 | Research: overflow simulation bug — "false path" problem (literature survey + reference, no date) |
| [010_2026-04-10_…_branchless_soft_fadd.md](worklog/010_2026-04-10_session_log_branchless_soft_fadd_option_a.md) | 317 | Session log — 2026-04-10: branchless soft_fadd (Option A) |
| [009_2026-04-11_…_documentation_narrow_bit_width.md](worklog/009_2026-04-11_session_log_continued_documentation_narrow_bit_wid.md) | 242 | Session log — 2026-04-11 (continued): Documentation + narrow bit-width |
| [008_2026-04-10_…_switch_reversible_memory_research.md](worklog/008_2026-04-10_switch_instruction_reversible_memory_research_benn.md) | 263 | 2026-04-10 — Switch instruction + reversible memory research (Bennett-282) |
| [007_2026-04-10_…_float64_division_multi_arg.md](worklog/007_2026-04-10_fix_float64_division_and_multi_arg_float64_compile.md) | 252 | 2026-04-10 — Fix Float64 division and multi-arg Float64 compile (Bennett-dqc) |
| [006_2026-04-11_…_pebbling_pipeline_eager.md](worklog/006_2026-04-11_pebbling_pipeline_gate_groups_value_level_eager_be.md) | 313 | 2026-04-11 — Pebbling pipeline: gate groups + value-level EAGER (Bennett-an5) |
| [005_2026-04-11_…_checkpoint_bennett_sha256.md](worklog/005_2026-04-11_checkpoint_bennett_66_wire_reduction_on_sha_256_be.md) | 320 | 2026-04-11 — Checkpoint Bennett: 66% wire reduction on SHA-256 (Bennett-an5) |
| [004_2026-04-12_…_irstore_iralloca_types.md](worklog/004_2026-04-12_memory_plan_t1a_1_irstore_iralloca_types_bennett_f.md) | 309 | 2026-04-12 — Memory plan T1a.1: IRStore / IRAlloca types (Bennett-fvh) |
| [003_2026-04-12_…_handoff_session_close.md](worklog/003_2026-04-12_handoff_for_next_agent_session_close.md) | 287 | HANDOFF FOR NEXT AGENT — 2026-04-12 session close |
| [002_2026-04-12_…_qrom_vs_mux_scaling.md](worklog/002_2026-04-12_t1c_3_qrom_vs_mux_scaling_benchmark_bennett_qw8k.md) | 232 | 2026-04-12 — T1c.3: QROM vs MUX scaling benchmark (Bennett-qw8k) |
| [001_2026-04-12_…_4_round_feistel.md](worklog/001_2026-04-12_t3a_1_4_round_feistel_reversible_hash_bennett_bdni.md) | 288 | 2026-04-12 — T3a.1: 4-round Feistel reversible hash (Bennett-bdni) |
| [000_2026-04-12_…_session_close_memory_plan_push.md](worklog/000_2026-04-12_session_close_second_of_day_memory_plan_push.md) | 205 | Session close — 2026-04-12 (second-of-day, memory plan push) |

## Notes on the sharded layout

- **Why the file numbering doesn't match strict date order**: the original
  WORKLOG was *mostly* reverse-chronological but sessions were sometimes
  appended at the bottom rather than prepended at the top, so e.g. some
  2026-04-12 content sits below 2026-04-09 content in the source. The
  chunker preserves source order — the `NNN_` prefix reflects the source
  file's structure, not strict date order. The dates in filenames give the
  approximate timeframe.

- **Single outlier at 579 lines** (`worklog/034_…`): a coherent narrative
  with no internal `### ` subsections to split on. Accepted as-is rather
  than fragmenting.

- **A few chunks under 200 lines** (134-196 each): natural session-log units
  too small to merit their own chunk under strict 200-300 sizing, but
  combining them with adjacent dates would mix unrelated topics. Left as-is.

- **Reference content** (Project purpose / Repository layout / Version
  history / Key design decisions / Sturm.jl integration path) is preserved
  inside `worklog/013_2026-04-09_session_log.md` and adjacent chunks where
  it originally lived. Future cleanup may extract this to `docs/`; for now
  the byte-for-byte preservation is the priority.
