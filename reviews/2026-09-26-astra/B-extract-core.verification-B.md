# Verification B — B-extract-core F13–F26 — 2026-09-26

Independent re-execution of findings F13–F26 of `B-extract-core.md` (F1–F12 are verified
separately). Environment: Julia 1.12.3 / LLVM 18, x86_64 Linux, `julia --project
--check-bounds=yes --compiled-modules=existing`. All IR probes were fed in-memory through
`Bennett._parsed_ir_from_ir_string` (the shared tail of `extract_parsed_ir` / the `.ll` entries;
signature `src/extract/entry.jl:95`), then `reversible_compile(::ParsedIR)`, `simulate`,
`verify_reversibility(c; n_tests=4)`. No MethodErrors: every reproducer's call matched the real
signatures. Probe scripts lived only in the session scratchpad. No src/test edits, no bd, no commit.

Dedup sources: `B-circuit-core.triage.md`, `B-arith.triage.md` (no overlapping rows for any of
F13–F26), `.beads/issues.jsonl` (ids + keyword search), and the untriaged sibling report
`B-extract-vm.md` (two exact cross-report duplicates, see F15/F16/F26).

## Summary

| F# | Verdict | Sev (report → ok?) | Reachability | Dedup | Note |
|---|---|---|---|---|---|
| F13 | CONFIRMED | S0 ok | **Julia-reachable** (`unsafe_load(Ptr{U24},2)`); default datalayout suffices | NEW, OVERLAPS Bennett-0ucg (open, non-integer branch) | got 7 want 0x99, rev=true; custom `e-i24:32` not needed |
| F19 | CONFIRMED | S0 ok (ptr_cells/VM model) | global shape is Julia's type-tag form; null compare hand-written | NEW (iwo9 closed = origin; eqjl different namespace) | first tag id 0 == null; got 1 want 0, rev=true; per-function `tag_ids` REASONED |
| F24 | CONFIRMED | S0 by rubric; practically latent | **from_ll-only** (Julia/clang x86-64 always fold to i64 inttoptr) | NEW (6qsn/rpqc tangential) | circuit 0, native `llvmcall` 1 |
| F20 | CONFIRMED | S0 by rubric; practically latent | **from_ll-only** (big-endian module; Julia host is LE) | NEW | `E` and `e` both give 1; `E` must give 128 |
| F17 | CONFIRMED | S0 ok | from_ll / clang `alias` attr; Julia only emits `jl_global#N.jit` aliases (fnxh/hsm3) | DUPLICATE-OF Bennett-n4di (open P2) — upgrade evidence | store through `@a` erased (0 insts); direct `@g` rejects loudly |
| F23 | CONFIRMED | S1 ok | **Julia-reachable** (plain parametric functor) | DUPLICATE-OF Bennett-zuk5 (open P3) — framing too weak | two identical `callee=ReviewAdder argw=[64,8] retw=8` calls accepted |
| F14 | CONFIRMED (+1 extra) | S1 ok | from_ll / clang `volatile`; Julia does not emit these | OVERLAPS Bennett-4mmt (closed, incomplete) | vector volatile load → IRLoad; sret volatile *and* `store atomic seq_cst` accepted |
| F18 | CONFIRMED | S1 → S2 arguable (loud) | clang release `.ll` (numeric labels) plausible, clang not installed here; Julia & rustc name blocks | NEW (c6ex = downstream guard) | 3 blocks all `Symbol("")`, lower rejects |
| F22 | CONFIRMED | S1 ok (S2 arguable: circuit fails loud) | from_ll; clang 2-D VLA `alloca [K x T], i64 %n` plausible | DUPLICATE-OF Bennett-uiqq (open P2) | `IRAlloca(:p,8,ConstOperand(1))`, store idx=1 out of range |
| F9 | CONFIRMED | S1 ok | **Julia-reachable**: `reversible_compile(x->(x,x,x,x), Int64)` fails | NEW (0c8o closed, incomplete) | splat `insertelement`+`shufflevector` → sret store; also `NTuple{8,Int32}` |
| F21 | PARTIALLY (extractor fold confirmed; semantic claim REASONED) | S1 ok | clang `extern __attribute__((weak))`; not Julia | NEW | `icmp eq (@weak, null)` → `IRRet(ConstOperand(0),1)` |
| F15 | CONFIRMED | S2 ok (borderline S1: hang) | Julia-reachable only via opt-in `extract_parsed_ir(...; use_memory_ssa=true)` | DUPLICATE-OF B-extract-vm F5 (untriaged) | n=1000 stores → 53,886 B OK; n=2000 → timeout 124 |
| F26 | CONFIRMED | S2 ok (no consumer) | any multi-function module (Julia `dump_module=true` has callees) | OVERLAPS B-extract-vm F8 (same parser; F8 mentions function-local IDs) | `def_clobber=Dict(2=>1,1=>2)`, `phis=Dict(2=>…)` |
| F16 | CONFIRMED | S2 ok | Julia-reachable (any self-recursive fn) | DUPLICATE-OF B-extract-vm F3 (untriaged); not t7zu | root in `transitive_callees`; duplicate canonical key |
| F25 | CONFIRMED | S2 ok | **Julia-reachable**: `x->reinterpret(Int64, floor(reinterpret(Float64,x)))` rejects | NEW (6pa closed claims it; tests only cover SoftFloat route) | all 4 `llvm.{floor,ceil,trunc,rint}.f64` reject; `llvm.round` control extracts |

Headline: 14/14 reproduced (F21 partially, by design). Julia-reachable: F13, F9, F16, F23, F25 (plus
F15 via opt-in kwarg). from_ll-only S0s: F20 and F24 (as suspected), and F17 in practice.

## Per-finding details

### F13 — CONFIRMED, S0 ok, Julia-reachable
- Reproducer as written: ParsedIR `IRPtrOffset(:q, SSAOperand(:p), 3, 24)`; `simulate(c, UInt64(0x0000009907000000))`
  = 7 (want 0x99), `verify_reversibility` = true.
- Same result **without** the `target datalayout="e-i24:32"` line: LLVM's default gives i24 the
  alignment of the next specified integer (i32 → 4), so alloc size 4 ≠ 3 on every datalayout Julia uses.
- Julia reachability: `primitive type U24 24 end; h(p::Ptr{UInt8}) = unsafe_load(Ptr{U24}(p), 2)`
  emits `getelementptr inbounds i24, ptr %p, i64 1`; `extract_parsed_ir` yields
  `IRPtrOffset(..., 3, 24)`, while native execution on bytes `0:8` returns `0x060504` (stride 4).
  `sizeof(U24)=3`, `datatype_alignment=4`.
- Adjacent 0ucg (non-integer branch) also re-confirmed: `getelementptr float` → `IRPtrOffset(...,1,8)`,
  got 7 want 153, rev=true; and **Julia-reachable**: `reinterpret(UInt32, unsafe_load(Ptr{Float32}(p),2))`
  extracts `IRPtrOffset(..., 1, 8)` (should be 4). Worth adding to Bennett-0ucg.
- Dedup: integer-width stride is not in 0ucg's text (0ucg = raw index for non-integer source). NEW, same
  code family → file separately or widen 0ucg.

### F19 — CONFIRMED, S0 ok (for the ptr_cells/VM model)
- ParsedIR (`ptr_cells=true`): `IRBinOp(:tag,:or,ConstOperand(0),ConstOperand(0),64)`,
  `IRICmp(:r,:eq,SSAOperand(:tag),ConstOperand(0),64)`; simulate(UInt8(1)) = 1, want 0; rev=true.
- Code: `module_walk.jl:199` creates `tag_ids` per function; `instructions.jl:7487–7488` assigns
  `Int64(length(tag_ids))` → first tag = 0 = null encoding. Cross-function ID inconsistency follows
  from the per-function dict: REASONED-ONLY (not executed).
- Reachability: the `@"+Main.Core.Int8#N" = constant ptr inttoptr (i64 … to ptr)` global is the shape
  Julia emits; an `icmp eq tag, null` is not something Julia codegen typically produces, so the
  null-collision witness is hand-written. The id-collision class is plausible in Julia-produced
  closed-world sets (tag compared with another pointer-valued cell that encodes 0).
- Dedup: keyword search found only iwo9 (closed, introduced it) and beaw (closed, null operand support).
  NEW.

### F24 — CONFIRMED, S0 by rubric, from_ll-only
- ParsedIR `IRRet(ConstOperand(0),1)`; circuit(UInt8(0)) = 0; native `Base.llvmcall` of the zext
  variant = 1. rev=true.
- Reachability: Julia on 64-bit only emits `inttoptr (i64 …)`; clang folds narrow integer→pointer
  constants to i64 before emission. Only hand-written / foreign `.ll` produces `inttoptr (i32 -1 to ptr)`.
  Recommend practical priority P3 despite S0 label.
- Dedup: Bennett-6qsn (inttoptr-of-const ptr fields) and Bennett-rpqc (32-bit ptr) are tangential. NEW.

### F20 — CONFIRMED, S0 by rubric, from_ll-only
- `target datalayout="E"`: simulate(UInt8(1)) = 1 (LangRef big-endian packing requires 128); `"e"`: 1.
  rev=true both. The datalayout is ignored by the vector→int bitcast scalariser.
- Reachability: Julia on this host always produces a little-endian layout; only `.ll`/`.bc` from a
  big-endian target (s390x, ppc64, mips BE) hits it. The cheap fix is a uniform big-endian reject at ingest.
- Dedup: none (haiy/epfe/rpqc keyword hits are unrelated). NEW.

### F17 — CONFIRMED, S0 ok, DUPLICATE-OF Bennett-n4di
- Alias store: block `entry` has `IRInst[]`, terminator `IRRet(SSAOperand(:x),8)` — store erased.
- Direct-global control: rejects with `store target pointer is not a registered SSA name (value=LLVM.GlobalVariable("g")) … (Bennett-lgzx / U114)`.
- Reachability: Julia emits aliases only for `jl_global#N.jit` (handled by fnxh/hsm3); user aliases come
  from clang `__attribute__((alias))` or Rust. n4di (open P2) describes exactly this swallow; the report's
  witness upgrades it from "possible dangling SSA" to "executed dropped side effect" — annotate n4di and
  consider P1.

### F23 — CONFIRMED, S1 ok, DUPLICATE-OF Bennett-zuk5
- `extract_parsed_ir_set_from_julia(root_adder, Tuple{Int8}; ptr_cells=true)` returned keys
  `root_adder#48af7fb4, ReviewAdder#20e9b5fb, throw_inexacterror#223736bc, ReviewAdder#7be14e9b`
  (identical digests to the report). Root body has two `IRCall callee=ReviewAdder argw=[64,8] retw=8`.
- Julia-reachable with ordinary code. zuk5 (open P3, "defense-in-depth") is the same missing
  >1-candidate guard; annotate with this witness and raise priority. Downstream wrong-body linking is not
  executed (no VM run), so S1 not S0 is right.

### F14 — CONFIRMED, S1 ok, OVERLAPS Bennett-4mmt (closed)
- `load volatile <1 x i8>` → `IRPtrOffset, IRLoad, IRBinOp(add …,0)` (accepted). Scalar control
  `load volatile i8` rejects (`volatile load not supported (Bennett-4mmt / U14)`).
- `store volatile i8 %x, ptr sret` → `IRInsertValue(…) ; IRRet` (accepted).
- Extra probe (not in report): `store atomic i8 %x, ptr %out seq_cst, align 1` into sret → identical
  accepted ParsedIR, confirming the report's "sret pre-walk never checks atomic ordering" remark.
- Reachability: from_ll / clang (`volatile` vector loads, e.g. `volatile __m128*`); Julia does not emit
  volatile, and never atomics into sret. 4mmt is closed; this is a bypass of its guard → reopen-style NEW bead
  referencing 4mmt. Related: B-extract-vm F6 (atomicrmw in heap skeleton) is a separate producer.

### F18 — CONFIRMED, S1 → S2 arguable
- Three blocks labelled `Symbol("")`; `IRBranch(SSAOperand(:__v1), Symbol(""), Symbol(""))`;
  `reversible_compile` → `lower: duplicate basic-block labels in ParsedIR (Bennett-c6ex)`.
- Fails loud (c6ex guard), never silently. Reachability: Julia names every block (`top`, `L4`, …;
  checked at optimize true/false); rustc `--emit=llvm-ir -C opt-level=2` names blocks (`start`, `bb5`);
  release clang discards value names and prints numeric block labels — plausible for C `.ll` ingest but not
  verified (clang not on PATH). The T5 corpus in `build/` (3 rustc files) has no numeric labels.
- Dedup: none (ehoa keyword hit unrelated). NEW.

### F22 — CONFIRMED, S1 ok (S2 arguable), DUPLICATE-OF Bennett-uiqq
- `IRAlloca(:p, 8, ConstOperand(1))`; compile → `ArgumentError: _lower_store_via_shadow!: idx=1 out of range [0, 1)`.
- `_alloca_reservation` docstring (`instructions.jl:110–128`) itself says the count is deliberately not
  consulted and points at uiqq; scalar-type allocas do read the count. Circuit path fails loud; ptr_cells
  p06b refuses N≠1. Reachability: from_ll; clang 2-D VLAs (`int a[n][4]`) emit `alloca [4 x i32], i64 %n`.

### F9 — CONFIRMED, S1 ok, Julia-reachable, NEW
- Reproducer: `AssertionError: ir_extract.jl: 1 pending sret vector store(s) remain unresolved at ret void…`.
- **Plain Julia hits it**: `reversible_compile(x -> (x,x,x,x), Int64)` — optimize=true IR is
  `insertelement <4 x i64> poison, …` + `shufflevector … zeroinitializer` + `store <4 x i64> %1, ptr %sret_return`
  → same AssertionError. Also `x::Int32 -> NTuple{8}` splat. Controls `(x,x+1,x,x+1)` and
  `(x,x,x+3,x+3)` (no vector ops emitted) compile and simulate correctly.
- Dedup: 0c8o (closed) added vector-lane sret stores but misses pure-plumbing producers. NEW; this is the
  most user-visible of the loud findings here (any splat tuple return).

### F21 — PARTIALLY CONFIRMED, S1 ok
- `icmp eq (ptr @review_undefined_weak, ptr null)` folds to `IRRet(ConstOperand(0),1)` — confirmed.
- That the correct answer is 1 depends on link-time resolution of an undefined `extern_weak` symbol
  (LangRef: may be null). No native oracle attempted (the report's JIT attempt failed); semantic half is
  REASONED-ONLY, and I agree with it: folding to 0 asserts non-null, which LLVM itself does not do for
  extern_weak. Reachability: clang `extern int sym __attribute__((weak))` availability checks; not Julia.
- Dedup: no hits. NEW.

### F15 — CONFIRMED (bounded), S2 ok, DUPLICATE-OF B-extract-vm F5
- `timeout 90s`: n=500 stores → `MEMSSA_DONE 26885`; n=1000 → `53886` (0.04 s); n=2000 → only
  `MEMSSA_START`, exit 124. The threshold sits just above 64 KiB, the Linux pipe buffer, matching the code
  path (`memssa.jl:132–141`: `redirect_stderr(pipe)` around a synchronous `LLVM.run!`; `read(pipe)` only
  after `close(pipe.in)`).
- Reachability: only `extract_parsed_ir(...; use_memory_ssa=true)` (not exposed by `reversible_compile`;
  no other src caller). The printer prints the whole module, so a >64 KiB Julia module (e.g. a soft-float
  callee at optimize=false with `dump_module=true`) would hang. S2 fine; a hang is arguably S1-class.
- Dedup: identical to B-extract-vm F5 (same file/lines, same mechanism). File once.

### F26 — CONFIRMED, S2 ok, OVERLAPS B-extract-vm F8
- Printer output: `MemorySSA for function: f1` → `1 = MemoryDef(liveOnEntry)`, `2 = MemoryDef(1)`;
  `MemorySSA for function: julia_f2` → `2 = MemoryPhi({entry,liveOnEntry},{loop,1})`, `1 = MemoryDef(2)`.
  `parse_memssa_annotations` → `def_clobber=Dict(2=>1, 1=>2)`, `phis=Dict(2=>[(:entry,0),(:loop,1)])`.
- No consumer: `memssa` never read under `src/lowering/`; metadata-only. B-extract-vm F8 (phi+def in
  one slot) names "IDs are also function-local … no function namespace" and tests for it; one bead for the
  memssa parser covering both.

### F16 — CONFIRMED, S2 ok, DUPLICATE-OF B-extract-vm F3
- `transitive_callees(rec_review, Tuple{Int8})` = `[(typeof(rec_review), Tuple{Int8})]`;
  `extract_parsed_ir_set_from_julia` → `duplicate canonical key rec_review#6f2728c5` (same digest as report).
- Julia-reachable (any self-recursive function); loud. Not t7zu (downstream sret recursion). B-extract-vm
  F3 labels it S1; S2 is adequate since recursion is unsupported downstream anyway.

### F25 — CONFIRMED, S2 ok, Julia-reachable, NEW
- All four raw wrappers reject: `call to 'llvm.{floor,ceil,trunc,rint}.f64' has no registered callee
  handler or intrinsic pattern`. Control `llvm.round.f64` extracts to `IRCast, IRCall, IRCast`.
- Code: `instructions.jl:5091–5104` is an empty `if` whose comment claims the registry handles these;
  `_CALLEES_FP_ROUND` (`src/callees.jl:32`) registers `soft_*` names only.
- **Julia-reachable**: `reversible_compile(x -> reinterpret(Int64, floor(reinterpret(Float64, x))), Int64)`
  and `extract_parsed_ir(floor, Tuple{Float64})` both reject the same way. `reversible_compile(f, Float64)`
  works only because SoftFloat dispatch rewrites `floor` before codegen; `test/test_float_intrinsics.jl`
  covers only that route, which is why 6pa/0hu closed green. Fail-loud capability gap → S2.
