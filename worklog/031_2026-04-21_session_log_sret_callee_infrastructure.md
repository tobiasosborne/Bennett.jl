## Session log — 2026-04-21 — α + β + γ (sret + callee infrastructure)

Triple-bead session. The T5-P6 research step (p6_consensus §2) surfaced three
distinct bugs blocking the persistent-tree dispatcher arm. Each got its own
bead, its own 3+1 protocol, its own RED-green cycle. Deliverables:

- 3 source-code commits: `08ba192` (α), `6f9bd8d` (β), `9adbc66` (γ)
- 1 WORKLOG commit: `f171d0a`
- 17 design docs (~12,000 lines total)
- 3 new test files
- Full `Pkg.test()` GREEN after each landing

### Bennett-atf4 (α) — `lower_call!` method-table arg types

**Bug** (`src/lower.jl:1869` pre-fix):
```julia
arg_types = Tuple{(UInt64 for _ in inst.args)...}
callee_parsed = extract_parsed_ir(inst.callee, arg_types)
```
Hardcoded `UInt64` for every arg. Every pre-existing callee (44 of them) had
that shape by coincidence; any non-UInt64 signature (Int8, NTuple, etc.)
threw `MethodError: no unique matching method`.

**Fix** (`src/lower.jl`, +~80 LOC):
- New `_callee_arg_types(inst::IRCall) -> Type{<:Tuple}` uses
  `first(methods(inst.callee)).sig.parameters[2:end]`. Fail-loud on
  zero-method / multi-method / Vararg / arity-mismatch callees.
- New `_assert_arg_widths_match(inst, arg_types) -> Nothing` cross-checks
  `inst.arg_widths[i] == sizeof(T_i)*8` for each method param. Closes the
  latent silent-wire-misalignment bug noted in `p6_research_local.md §12.4`.
- 2-line patch at `lower_call!` line 1869 replacing the hardcoded derivation.

**R8 instrumentation** (A's flagged risk): before shipping, I ran a probe
across a representative compile suite (`soft_fma`, `soft_fadd`, `soft_fcmp_olt`,
`div`, `rem`, `x+1`, `x*y`). Zero `arg_widths` mismatches. The assertion
shipped safely.

**Test** (`test/test_atf4_lower_call_nontrivial_args.jl`, 7 testsets, 24 assertions):
T1 Int8 scalar arg, T2 NTuple{9,UInt64} arg (gets past line 1870, tolerates β-scope
sret error), T3 width-mismatch assertion, T4 vararg reject, T5 multi-method reject,
R1 soft_fma regression, R2 arity mismatch.

**Regression**: byte-identical by construction — every existing callee's
`Tuple{params[2:end]...}` equals `Tuple{UInt64, ...}`.

### Bennett-0c8o (β) — vector-lane sret stores + vector loads

**Bug 1** (`src/ir_extract.jl:517-520` pre-fix): `_collect_sret_writes`
rejected `store <N x iW>` into sret GEPs with "sret store has non-integer
value type". SROA+SLPVectorizer produces these under `optimize=true` for
NTuple returns where the store pattern has 4+ consecutive same-predicate selects.

**Bug 2** (implicit, surfaced during β implementation): the store's value
cone reaches `load <N x iW>` (`%18 = load <4 x i64>, ptr %"state::Tuple[2]_ptr"`).
`_convert_vector_instruction` had no LLVMLoad handler — naive store-only fix
would fail at the load producer.

**Fix** (`src/ir_extract.jl`, +~150 LOC):
- `_collect_sret_writes` gains a vector-store branch that **reserves slot
  ranges with `:__pending_vec_lane__` sentinels** (preserves the existing
  "every slot written" invariant) and records `pending_vec[store.ref] =
  (first_slot, n_lanes)` + `pending_val_refs[store.ref] = val.ref`.
- New pass-2 hook `_resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)`
  harvests from the `lanes` dict when `_convert_vector_instruction` walks the
  vector-producing instruction.
- New `_assert_no_pending_vec_stores!(sret_writes)` fails loud at `ret void`
  if any sentinel survives.
- Scalar-store duplicate-slot check at line 532 gains a sharper error when
  colliding with a vector sentinel.
- `_convert_vector_instruction` gains an `LLVMLoad` case at line 2237 that
  synthesises `n` scalar `IRPtrOffset` + `IRLoad` pairs at lane byte offsets,
  populating `lanes[inst.ref]`.

**Critical design choice** (vs. Proposer B's inline decomposer): the
structural fix **reuses `_convert_vector_instruction` as the canonical
vector→scalar decomposer**. Proposer B's design had a local recursive
walker that would have duplicated that logic (CLAUDE.md §12 violation).

**Test** (`test/test_0c8o_vector_sret.jl`, 7 testsets, 97 assertions):
primary repro (NTuple{9,UInt64} extract), end-to-end reversible_compile +
verify_reversibility, scalar-input semantic roundtrip (4 test cases covering
insert-at-slot-0/1/2, overflow), n=2 swap2 baseline (82 gates), n=3 UInt32
identity, n=8 UInt32 (no SLP), heterogeneous rejection, and (later updated
by γ) memcpy auto-canonicalisation.

**Option (c) Scalarizer empirically rejected**: both proposers verified LLVM.jl's
`NewPMPassBuilder` rejects `"scalarizer<load-store>"` parameter syntax; plain
`"scalarizer"` leaves load/store scalarisation defaulted off. The vector store
survives. Documented in `gamma_proposer_A.md` §3.1 and cross-ref'd from
`beta_consensus.md`.

### Bennett-uyf9 (γ) — auto-SROA for memcpy sret

**Bug** (`src/ir_extract.jl:451-461` pre-fix): `_collect_sret_writes` rejected
`llvm.memcpy` stores into sret pointer with "sret with llvm.memcpy form is not
supported". Julia's `optimize=false` specfunc emits aggregate returns as
`alloca [N x iM]` + memcpy.

**Fix** (`src/ir_extract.jl`, +~25 LOC):
- New `_module_has_sret(mod::LLVM.Module) -> Bool` predicate walks all
  functions (with bodies) and checks each parameter for the `sret`
  enum-attribute. Placed near `_detect_sret`.
- In `extract_parsed_ir` (post-parse, pre-pass-run) and `_extract_from_module`
  (shared by `_from_ll` / `_from_bc`): when `_module_has_sret` is true AND
  `"sroa"` isn't already in `effective_passes`, `prepend!(effective_passes,
  ["sroa", "mem2reg"])`. SROA decomposes the alloca+memcpy into per-slot
  scalar stores that `_collect_sret_writes` already handles.
- Keep the existing memcpy-rejection error as defensive fallback.

**Option comparison**: both proposers independently recommended C1 (auto-SROA)
over C2 (port Enzyme.jl's `memcpy_sret_split!` + recursive `copy_struct_into!`).
C1 is ~15 LOC + one stock LLVM pass; C2 is ~120 LOC duplicating logic SROA
already does correctly. C2's advantage (no pass-ordering churn) doesn't outweigh
the maintenance cost.

**Test updates**:
- `test/test_uyf9_memcpy_sret.jl` (new, 5 testsets, 11 assertions): primary
  NTuple{9,UInt64} under `optimize=false`, explicit `preprocess=false` still
  auto-SROAs, non-sret function is unaffected (gate-count baseline i8=100/28T),
  `preprocess=true` doesn't double-run SROA, n=3 UInt32 under `optimize=false`.
- `test/test_sret.jl:125-136`: flipped from `@test_throws ErrorException` to
  successful-extraction assertion (previous error contract closed by γ).
- `test/test_0c8o_vector_sret.jl:158-168`: β's regression test for memcpy
  rejection updated — β shipped when γ wasn't yet merged, so the contract
  changed between β landing and γ landing. Documented in the updated test.

### Research artifacts generated

| File | Lines | Purpose |
|---|---|---|
| `p6_research_local.md` | 1646 | Local audit of IRCall + lower_call + ir_extract sret + callee corpus + test coverage |
| `p6_research_online.md` | 1157 | Julia NTuple ABI, SYSV sret classification, Enzyme.jl source, LLVM passes, reversible-compiler prior art |
| `p6_consensus.md` | (updated) | T5-P6 design; research step §2 flipped from OPEN to RESOLVED |
| `alpha_proposer_{A,B}.md` | 975 + ~500 | Independent designs for Bennett-atf4 |
| `alpha_consensus.md` | ~275 | α synthesis |
| `beta_proposer_{A,B}.md` | 996 + 1351 | Independent designs for Bennett-0c8o |
| `beta_consensus.md` | ~225 | β synthesis (takes A's structure + includes vector-load scope per "no quick fixes" directive) |
| `gamma_proposer_{A,B}.md` | ~700 + 978 | Independent designs for Bennett-uyf9 |
| `gamma_consensus.md` | ~260 | γ synthesis |

### Baselines — session-close spot-check (post-γ, post-full-regression)

All byte-identical to pre-session:

| Test | Expected | Actual |
|---|---|---|
| i8 `x+1` total/Toffoli | 100 / 28 | 100 / 28 ✓ |
| i16 `x+1` total | 204 | 204 ✓ |
| i32 `x+1` total | 412 | 412 ✓ |
| i64 `x+1` total | 828 | 828 ✓ |
| `_ls_demo` total/Toffoli | 436 / 90 | 436 / 90 ✓ |
| HAMT demo | 96,788 | 96,788 ✓ |
| CF demo | 11,078 | 11,078 ✓ |
| CF+Feistel | 65,198 | 65,198 ✓ |
| TJ3 | 180 | 180 ✓ |

### Lessons (for the NEXT AGENT header above, and for future 3+1 protocols)

- **Bead descriptions are aspirational** (WORKLOG rule rediscovered 3×). T5-P6's
  bead said "add one dispatcher arm + kwargs". Real scope was "also fix 3
  independent infrastructure bugs first". Research step saved us.
- **The 3+1 protocol rewards parallel independent research.** Proposer B of β
  caught the `load <4 x i64>` issue that Proposer A punted to follow-up.
  Both independently verified Option (c) Scalarizer is dead. Single-agent
  design would have missed one or both.
- **WireAllocator zero invariant + callee inlining + `methods()` dispatch**
  compose: with α shipped, `register_callee!` can now accept NTuple-arg
  callees directly; they inline through `lower_call!` the same way scalar
  soft_* callees do. T5-P6's architecture benefits.
- **`_convert_vector_instruction` is the canonical vector→scalar gateway**;
  do not build parallel decomposers. β's deferred-resolution design hinges
  on this principle.
- **Julia's `optimize=true` runs SROA 4× plus SLPVectorizer plus VectorCombine**
  (per `src/pipeline.cpp:362-553`). For Bennett, this means `<N x iW>` stores
  are the norm for aggregate returns, not the exception. β is load-bearing.

---

### Epic status

**Bennett-cc0 memory epic** — T5 Phase 5+ is the current frontier:

| Bead | Status | What it blocks / unblocks |
|------|--------|---------------------------|
| cc0.7 (InsertElement/Vector SSA) | ✓ closed 2026-04-20 | Unlocked `optimize=true` everywhere; 3-50× gate-count reduction on SLP-vectorised workloads. 4.4× measured on ls_demo_16 sweep fixture. |
| cc0.3 (LLVMGlobalAlias) | ✓ closed 2026-04-20 | Unblocks Vector/Dict/metaprogrammed pathways; downstream `@eval`-generated code can extract past runtime-JIT-global references. |
| cc0.4 (constant-ptr icmp eq) | ✓ closed 2026-04-21 | TJ3 (mutable linked list `isnothing(next)`) GREEN at 180 gates. ConstantExpr<icmp eq/ne> on pointer operands folds to iconst(0/1) via canonical `_ptr_identity` (chases alias → inttoptr(ConstantInt) → named global / null). |
| cc0.6 (error-report cleanup) | ✓ closed 2026-04-21 | All `error()` calls in `ir_extract.jl` now prefixed `ir_extract.jl:`. Instruction-scoped errors follow canonical format "ir_extract.jl: `<opcode>` in @`<funcname>`:%`<blockname>`: `<instruction>` — `<reason>`" via new `_ir_error(inst, reason)` helper + `_LLVM_OPCODE_NAMES` dict. Behavior-preserving chore; test/test_cc06_error_context.jl gates the format. |
| T5-P5a (`.ll` ingest) | ✓ closed 2026-04-21 | `extract_parsed_ir_from_ll(path; entry_function)` lands. Refactored `_module_to_parsed_ir` into dispatcher + core walker (`_module_to_parsed_ir_on_func`). New `_find_entry_function` does exact LLVM-level name lookup with fail-loud on miss / ambiguous / declaration-only. C corpus TC1/TC2/TC3 GREEN on extract, RED on lower. 256-input equivalence test vs `extract_parsed_ir(f,T)` — ParsedIR structurally equal, gate counts match. |
| T5-P5b (`.bc` ingest) | ✓ closed 2026-04-21 | `extract_parsed_ir_from_bc(path; entry_function)` via `MemoryBufferFile(path)` + `parse(Module, ::MemoryBuffer)` (bitcode-only overload). Shares `_extract_from_module` plumbing with P5a. `use_memory_ssa` unsupported on .bc path (fail loud with llvm-dis hint). Exhaustive i8 test via llvm-as-compiled fixture. |
| cc0.5 (thread_ptr GEP) | ○ (scope bumped) | TJ4 (Array{T}(undef,N)) — **needs T5-P6-scope milestone**, not a standalone fix. See 2026-04-20 session log §cc0.5 for empirical evidence and right-sized approach. |
| T5-P5a (Bennett-lmkb) | ○ (P2) | `extract_parsed_ir_from_ll(path)` — raw .ll text ingest for multi-language support |
| T5-P5b (Bennett-f2p9) | ○ (P2) | `extract_parsed_ir_from_bc(path)` + clang/rustc fixtures |
| T5-P6 (Bennett-z2dj) | ○ (P2) | `_pick_alloca_strategy :persistent_tree` arm + `mem=` kwarg. User's 2026-04-20 Phase-3-reversed sweep showed **linear_scan beats HAMT/CF/Okasaki at every N up to 1000** — recommended default. Dispatcher design should not prefer tree-shaped structures. |
| T5-P7a (Bennett-ktt8) | ○ (P2) | Full Pareto-front benchmark; waits on P6 |
| T5-P7b (Bennett-2uas) | ○ (P2) | BENCHMARKS.md + paper outline; waits on P6/P7a |

### Recommended sequence (per user plan 2026-04-20)

1. **cc0.4** — small, isolated bug fix on constant-pointer icmp eq. The cc0.3
   helpers (`_resolve_aliasee`, `_safe_operands`, `OPAQUE_PTR_SENTINEL`) are
   already in place and will likely make this a few-line addition to the
   icmp handler.
2. **cc0.6** — chore-level error-report cleanup for user-facing messages.
   May also surface ptrtoint/inttoptr scope questions.
3. **T5-P5a + P5b** — multi-language ingest (.ll / .bc). Headline feature
   ("Enzyme of reversibility" cross-language). Independent of bugs above;
   could be parallelized to a sonnet subagent.
4. **T5-P6** dispatcher — using this session's finding that linear_scan is
   the right default (not CF/HAMT/Okasaki). Needs cc0.4 + cc0.6 GREEN for
   the test corpus to actually drive the dispatcher.
5. **cc0.5** — proper TLS-allocator + Memory{T}-struct modeling as part
   of T5-P6 dispatcher or a dedicated milestone.
6. **T5-P7** — BennettBench writeup. Final epic close.

### Key recent session insights (don't re-discover)

1. **`freeze` / `x+0` is NOT zero-gate.** Empirically ~W+2 gates per
   `IRBinOp(:add, x, iconst(0), w)`. Both cc0.7 proposers assumed zero;
   falsified by direct measurement. If you're designing a "pure rename"
   primitive, it needs to mutate the `names` table or use a
   `value_aliases::Dict{_LLVMRef, IROperand}` — not add-0.

2. **TJ4 "succeeds" under optimize=true due to Julia-optimizer folding.**
   `Array{Int8}(undef, N); a[idx]=x; a[idx]` folds to `ret i8 %x` — the
   array never flows into the circuit. Any cc0.5 pre-walk can "pass" TJ4
   while doing nothing useful. Validate against cond_pair under
   `--check-bounds=yes` (Pkg.test default) to see the actual TLS chain.

3. **Pkg.test uses `--check-bounds=yes`.** This changes IR shape for
   array-literal patterns — they route through the TLS allocator instead
   of static allocas. Test your fixes under both modes:
   `julia --project=. test/runtests.jl` (no bounds check — fast) AND
   `julia --project=. -e 'using Pkg; Pkg.test()'` (bounds=yes — authoritative).

4. **LLVM.jl's operand iterator raises on unknown value kinds.** Any
   `LLVM.operands(inst)` + `LLVM.Value(ref)` path can crash on
   GlobalAlias, inline-asm, and other exotic operand kinds. Use the raw
   C-API pattern from `_any_vector_operand` (cc0.7) or `_safe_operands`
   (cc0.3) when a handler might see these. LLVM.jl exposes
   `LLVMGetNumOperands` / `LLVMGetOperand` / `LLVMGetValueKind` /
   `LLVMAliasGetAliasee` / `LLVMIsAInlineAsm` for defensive iteration.

5. **Bead descriptions are aspirational, not gospel.** Two beads this
   session (cc0.3 chain, cc0.5 pre-walk) described simpler fixes than
   the code actually required. Read the bead, extract real IR, then
   decide on scope. cc0.3 turned out simpler than described (skip-path
   > alias resolution); cc0.5 turned out much harder.

### Session close commits (this session)

- `552c802` Bennett-cc0.7: ir_extract handles SLP-vectorised IR
- `d213bfa` bd: sync dolt cache after Bennett-cc0.7 close
- `e4673bb` bd: sync dolt cache (post-push drift)
- `072ca2a` Bennett-cc0.3: ir_extract skips LLVMGlobalAlias instructions
- `134bd52` bd: sync dolt cache (post-push drift, cc0.3)

Gate-count spot checks (all byte-identical vs pre-session):
- soft_fptrunc: 36,474
- popcount32 standalone: 2,782
- HAMT demo max_n=8: 96,788
- CF demo max_n=4: 11,078
- CF+Feistel: 65,198

Two new gate-count wins from cc0.7:
- ls_demo_16: 22,902 → 5,218 (4.4× reduction; optimize=true unlocked)
- Any auto-vectorised workload: 3-50× reduction on same pattern

### Ground truth for next agent

Read these before starting:
- `CLAUDE.md` — the 13 implementation principles (§2 requires 3+1 for
  `ir_extract.jl` changes)
- `docs/design/cc07_consensus.md` — the design-doc style model
- `docs/design/cc03_05_consensus.md` — continuation pattern for ir_extract
- `src/ir_extract.jl:1341-1500` — cc0.3 helpers + cc0.7 handlers already
  in place; cc0.4 will build on them
- `test/test_t5_corpus_julia.jl` — TJ1/TJ2/TJ3/TJ4 `@test_throws` that
  drive the `ir_extract` gaps. TJ3 is the cc0.4 target. Watch the error
  message — the existing test passes on **any** ErrorException, so a
  clean fix will keep the test GREEN but with a message that no longer
  mentions "Unknown operand ref for: i1 icmp eq (ptr @…RNode…, …)".
- `test/test_t0_preprocessing.jl` — the "canary" for cc0.5-style
  regressions. `cond_pair` / `array_even_idx` under bounds=yes use the
  TLS allocator. If your next change touches the outer dispatch loop,
  run this test under `--check-bounds=yes` before committing.

### Proposer / implementer protocol (reminder)

Core `ir_extract.jl` / `lower.jl` / `bennett.jl` changes require 3+1 per
CLAUDE.md §2. Last two beads landed via:
- 2 proposer subagents (general-purpose, haiku/sonnet-class) with full
  ground-truth context (IR samples, full source files, constraints)
- Orchestrator (this agent) synthesises a consensus doc, then
  implements — OR hands the consensus to a sonnet implementer subagent
- Red-green TDD: write the failing test FIRST, confirm RED, then build
  toward GREEN

For small additive changes in a new file (e.g. new primitive library,
new persistent-DS impl), single-implementer OK — but still red-green.

---

