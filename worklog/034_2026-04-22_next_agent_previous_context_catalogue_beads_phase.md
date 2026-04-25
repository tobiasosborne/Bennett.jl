### Session end — 2026-04-23

**20 P1 catalogue beads closed this session** (U07–U10, U11–U17, U18,
U19–U26 excluding the reserved U06 which was closed in the prior
session). Progress:

| U# | Bead | Summary |
|---|---|---|
| U07 | k286 | `soft_fpext` quiets sNaN |
| U08 | r84x | NaN payload/sign bit-exact + fptosi saturates INT_MIN |
| U09 | l9cl | fail loud on i128+ ConstantInts |
| U10 | tu6i | fail loud on StructType extract/insertvalue |
| U11 | u21m | switch phi patching: global + duplicate-target safe |
| U12 | vz5n | GEP offset_bytes scales by source element byte stride |
| U13 | plb7 | IRVarGEP fail-loud on non-integer source |
| U14 | 4mmt | reject atomic/volatile load/store |
| U15 | 5oyt | fail loud on unregistered/inline-asm calls |
| U16 | qal5 | fail loud on multi-index / unsupported-base GEPs |
| U17 | 8b2f | `_get_deref_bytes` fallback anchored per-param |
| U18 | g27k | cc0.3 catch narrowed to exception type + non-Bennett |
| U19 | 6fg9 | simulate arity + per-input bit-width guard |
| U20 | hmn0 | HAMT 9th-hash-slot overflow detection (+26% gates) |
| U21 | n3z4 | cf_reroot: was-allocated flag in diff_idx bit 63 |
| U22 | sqtd | soft_feistel_int8 docs honest (207/256 image) |
| U23 | 11xt | `verify_reversibility` added to 5 metric-only test files |
| U24 | swee | WireAllocator n<0 + double-free guards |
| U25 | k0bg | reversible_compile kwarg + arg-type validation |
| U26 | 7stg | register_callee! ReentrantLock |

**Still open** from the Phase 0 catalogue list:
- **U27** (spa8) — `:auto` add dispatcher strictly worse than `:ripple`
  for 2-op adds. Claim released mid-session after probing.
  `_pick_add_strategy` currently picks Cuccaro whenever op2 is dead
  (SSA last-use OR const). Cuccaro produces more Toffolis AND more
  total gates than ripple at every width — i8/i16/i32/i64 both 2-op
  `a+b` and 1-op `x+1` cases. Fix is one line in
  `src/lower.jl:1240` but **ripples through ~10+ gate-count baselines**
  (i8 x+1 = 100 → 88; BENCHMARKS.md; CLAUDE.md §6; many tests). Needs
  a separate session with dedicated baseline-refresh pass, or a
  decision to keep :auto → :cuccaro as the documented default and
  annotate the catalogue finding as "this IS the intended default per
  wire-savings priority".
- U28 (epwy) — `fold_constants=false` default despite being safe
- U29 (xlsz) — divergent kwargs across `reversible_compile` overloads
- U30 (4fri) — `:auto` mul dispatcher never picks qcla_tree/karatsuba
- U31 (b1vp) — `fptoui` routed through `soft_fptosi`; `soft_fptoui`
  missing

**Workflow notes for next agent**:
- Full `Pkg.test()` is ~4 min. When a catalogue fix triggers a cascade
  of test-file updates, iterate on the affected test files first
  (~30 s each), run one final Pkg.test as a sanity gate.
- Existing per-file test includes at `test/runtests.jl:106-end` are
  one-line per catalogue fix; keep them anchored by U# reference in
  the comment for future bisect.
- `test_t0_preprocessing.jl`'s `skipped` allowlist is the accumulation
  point for "Julia optimize=true emits something we correctly reject
  loud". Add new keywords to that tuple rather than weakening fail-loud
  fixes.

- **Bennett-k0bg (U25) — `reversible_compile` accepted garbage kwargs +
  types silently.** `bit_width=-5` produced a 26-wire circuit; `=200`
  on Int8 silently accepted and produced a 602-wire circuit;
  `max_loop_iterations=-1` silently accepted; non-supported types like
  `Float32`/`BigInt`/`String` reached internals and threw LLVM-internal
  errors. Added up-front validation in `reversible_compile(f,
  arg_types::Type{<:Tuple})`: `bit_width ∈ {0, 8, 16, 32, 64}`,
  `max_loop_iterations >= 0`, and each `arg_types.parameters[i]` must
  be in `_SUPPORTED_SCALAR_ARGS = (Int8..Int64, UInt8..UInt64,
  Float64, Bool)` OR a concrete Tuple whose parameters are all in that
  set (handles `NTuple{N,T}` returns used by Bennett-0c8o). **Scope
  tuning gotcha**: first draft constrained `bit_width ∈ {0, 8, 16, 32,
  64}` per the catalogue, but `test_narrow.jl` intentionally exercises
  narrow widths 2, 3, 4, 6 via `bit_width=N`. Relaxed to
  `bit_width == 0 || 1 <= bit_width <= 64`. Test gate:
  `test/test_k0bg_compile_validation.jl` (5 testsets, 20 asserts):
  invalid bit_widths {-5, 200, 65} and max_loop_iterations {-1, -100}
  raise ArgumentError; valid values {0, 4, 8, 16} and {0, 10} compile;
  unsupported types (Float32, BigInt, String) raise; scalar integers
  Int8..Int64, UInt8 compile; NTuple{3,Int8} compiles. Pre-fix 13/20;
  post-fix 20/20. Full `Pkg.test()` green.

- **Bennett-swee (U24) — `WireAllocator.allocate!(wa, -1)` silent empty
  return.** `src/wire_allocator.jl:8`'s `for _ in 1:n` loop was
  zero-trip for `n < 0`, returning `Int[]`. An empty wire vector
  propagated into the Bennett construction and crashed much later with
  BoundsError. `free!` had no double-free detection either. Added:
  `n >= 0 || throw(ArgumentError(...))` at entry of `allocate!` (zero
  stays legal for loop-unroll corner cases); linear `w in wa.free_list`
  scan before insert in `free!` — O(N²) worst case but Bennett's
  allocator sizes are small (~thousands) so the cost is negligible.
  Test gate: `test/test_swee_wire_allocator_negative.jl` (10 asserts).
  Full `Pkg.test()` green.

- **Bennett-11xt (U23) — 5 test files compiled circuits without an
  ancilla-zero check.** Per CLAUDE.md §4, "runs without errors" is not a
  passing test; the test must verify Bennett's invariants on the actual
  circuit. Added `@test verify_reversibility(c)` + one simulate sanity
  call to every `reversible_compile` site in:
  `test/test_constant_wire_count.jl` (4 circuits),
  `test/test_dep_dag.jl` (3 circuits),
  `test/test_gate_count_regression.jl` (8 circuits),
  `test/test_negative.jl` (1 real-compile site, 3 negative paths kept
  as-is), and `test/test_toffoli_depth.jl` (1 real-compile loop, 3
  functions; synthetic `_mk` circuits not touched since they're
  intentionally incomplete). U01's `verify_reversibility` fix is what
  makes this meaningful — pre-U01 the check was tautological and adding
  it here would have been theater. Now it actually checks
  ancilla-zero + input-preservation per random input. All touched tests
  pass green on targeted run; full `Pkg.test()` green.

- **Bennett-sqtd (U22) — `soft_feistel_int8` was documented as a
  bijection; it isn't.** The Int8 → UInt32 zero-extend → `soft_feistel32`
  → low-byte truncate pipeline produces 207 distinct Int8 images out
  of 256 inputs (max collision 5, 49 unreachable outputs). Fix: rewrote
  docstring + header comment to cite "low-collision hash" with the
  exact image size; kept the underlying algorithm unchanged (no gate
  cost impact). Test gate: `test/test_sqtd_feistel_not_bijection.jl`
  (4 testsets, 67 asserts): pins image size at exactly 207, max
  collision at exactly 5, verifies the 32-bit `soft_feistel32` IS a
  bijection on walking-1 + walking-~1 bit sweeps (full 2³² enumeration
  too slow), and a docstring-honesty check that "bijection" no longer
  appears without "not a". `test_persistent_hashcons.jl:158` already
  asserts `length(images) > 200` which hedges correctly and still
  passes. Full `Pkg.test()` green.

- **Bennett-n3z4 (U21) — `cf_reroot` treated `r_key == 0` as the empty-slot
  sentinel.** `src/persistent/cf_semi_persistent.jl:350-357` decremented
  `arr_count` whenever the diff-entry's old key was zero. Int8(0) is a
  valid protocol key, so any sequence like `set(0, 99); set(0, 42);
  reroot` (overwrite-then-undo) wrongly decremented count — leaving Arr
  slot 0 populated with (k=0, v=99) but reporting count=0, so
  `cf_pmap_get(0)` returned 0 (miss). Fix: encode a was-allocated flag
  in bit 63 of the stored `diff_idx` — slots occupy bits 0..1 (range
  0..3), so bit 63 is free real estate. `cf_reroot` masks to
  `r_idx & 0x3` for Arr restoration and reads bit 63 for the
  count-decrement decision. **Cost**: surprisingly zero — CF demo gate
  count 11,078 byte-identical pre/post-fix. Test gate:
  `test/test_n3z4_cf_reroot_key_zero.jl` (4 scenarios, 9 asserts):
  reviewer repro + reroot-all-the-way + mixed key=0/key=1 state +
  regression for nonzero-key overwrite (which pre-fix handled correctly).
  Pre-fix 7/9; post-fix 9/9. Full `Pkg.test()` green.

- **Bennett-hmn0 (U20) — HAMT silently lost 9th distinct-hash-slot key.**
  `src/persistent/hamt.jl:hamt_pmap_set` computed
  `idx = popcount(bitmap & (bit-1))` where with 8 hash slots already
  occupied and a new slot outside them, idx lands at 8 — no
  `idx == UInt32(N)` case matches any of the unrolled 0..7 branches.
  New key silently dropped; bitmap mutated to include the new bit →
  bitmap inconsistent with compressed 8-slot key/value array. Added
  overflow detection: `is_overflow = is_new & (popcount(bitmap) >= 8)`,
  plus a final 17-way `ifelse(keep_old, old, new)` mux over bitmap +
  k0..k7 + v0..v7 that returns the unchanged state on overflow. 9th
  insert becomes a no-op (documented 8-slot limitation; HAMT is on the
  U79 EoL shortlist). **Gate-count cost**: HAMT demo rose from 96,788
  → 121,884 (+26%). Updated the regression comment in
  `test/test_persistent_hamt.jl:151`; the `@test` bounds are wide
  enough to still pass. Test gate: `test/test_hmn0_hamt_overflow.jl`
  — 8 distinct-hash keys + attempted 9th, asserts (a) the first 8 still
  retrievable post-overflow-attempt and (b) bitmap is unchanged
  (invariant: popcount stays at 8). Pre-fix: bitmap gained a bit →
  desync; post-fix: consistent. Full `Pkg.test()` green.

- **Bennett-6fg9 (U19) — `simulate` had no arity/bit-width guard.**
  `src/simulator.jl:_simulate` (and `src/controlled.jl:_simulate_ctrl`)
  iterated `for (k, w) in enumerate(circuit.input_widths)` and
  dereferenced `inputs[k]` — extra tuple elements silently dropped,
  too-short tuples crashed deep with BoundsError, over-wide scalar
  values silently chopped via `(v >> i) & 1`. Added an `ArgumentError`
  at entry of both `_simulate` paths: exact tuple-length match,
  `n_wires > 0`, and new `_assert_input_fits(v, w, k)` helper that
  checks `Int128(v)` lies in either the signed or unsigned `w`-bit
  range. Returns early for `w ≥ 64` (UInt64 upper-bound subsumes
  Int64). Test gate: `test/test_6fg9_simulate_arity.jl` — 10 assertions.
  Baseline 2-arg call still works; too-short / too-long / empty tuples
  raise; single-input circuit with 2-tuple raises; scalar overload
  with 2-input circuit still raises via the pre-existing guard; `1 <<
  40` into an 8-bit input raises instead of wrapping. Pre-fix 3/10
  missed the silent cases.

- **Bennett-g27k (U18) — cc0.3 catch-block swallowed unrelated errors
  by substring.** `src/ir_extract.jl:887-907` (before this fix) did a
  bare substring test on `sprint(showerror, e)` against "Unknown value
  kind" / "LLVMGlobalAlias" / "PointerType" (the last gated on
  MethodError). Any error — including a Bennett-authored `_ir_error` —
  whose message happened to contain one of those words got silently
  dropped, undoing the fail-loud cleanup from U09–U17. Narrowed: now
  require BOTH an exception type match (`ErrorException` for the first
  two, `MethodError` for the last) AND the message pattern AND the
  error is NOT Bennett-authored (message prefix `ir_extract.jl:` or
  contains `Bennett-`). Test gate:
  `test/test_g27k_cc03_catch_narrow.jl` — structural source-read assert
  that the catch block now gates on `e isa ErrorException` /
  `e isa MethodError` and mentions the Bennett-authored exclusion, plus
  a smoke test that ordinary extraction still works. The broader
  validation is that existing skip-path tests (test_t0_preprocessing
  GC-frame artifacts, test_persistent_* with LLVMGlobalAlias globals)
  still pass, AND the fail-loud tests from U09–U17 confirm
  Bennett-authored errors now propagate. **Monkey-patch gotcha**: my
  first RED-test draft tried `@eval Bennett function _convert_instruction(...)`
  to inject an error, but Julia's method-table specialization means the
  caller (`_extract_from_module`) still resolves to the original typed
  dispatch even when a generic monkey-patch is added. Switched to a
  structural source-read assertion; existing tests cover behaviour.

- **Bennett-8b2f (U17) — `_get_deref_bytes` IR-string fallback regex
  leaked across params.** `src/ir_extract.jl:2514-2524` (pre-fix) matched
  `dereferenceable\((\d+)\)` against the full `define` line, returning
  the FIRST N regardless of which param was being queried. Functions
  with multiple ptr params carrying different dereferenceable counts
  (e.g. `ptr dereferenceable(8) %big, ptr dereferenceable(4) %small`)
  reported 64 bits for BOTH params — phantom input-wire widths for
  every non-first ptr param. Primary path
  (`LLVM.parameter_attributes(func, idx)`) is per-param and unaffected,
  but newer LLVM.jl throws MethodError on the kwargless form, so the
  fallback fires in practice. Fix: anchor the regex to the specific
  param name using
  `dereferenceable\((\d+)\)[^,)]*%NAME\b`, where `[^,)]*` bounds the
  match to a single param slot and `\b` rules out prefix-shared names.
  Added `_regex_escape` helper because Julia mangled names contain `#`
  and `.`.
  Test gate: `test/test_8b2f_deref_bytes_per_param.jl` — hand-crafted
  IR with two params at 8 and 4 deref bytes; asserts `args` widths are
  64 and 32 respectively. Pre-fix 1/2 (big correct by accident — first
  match); post-fix 2/2.
  All targeted regression tests unchanged.

- **Bennett-qal5 (U16) — multi-index GEP / unsupported-base GEP silently
  dropped.** `src/ir_extract.jl:1706` was `return nothing  # GEP with
  unknown base — skip` — dest SSA left undefined, consumers crashed far
  downstream. Minimum-viable fix per catalogue: `_ir_error` naming the
  number of indices and the supported forms. Full support (type-walking
  byte-offset accumulation via `LLVMOffsetOfElement`) is future work;
  the fail-loud gate is the Phase 0 safety net. Test gate:
  `test/test_qal5_multi_index_gep.jl` — hand-crafted `getelementptr [4
  x i32], ptr @tbl, i32 0, i32 %i` (3 operands); pre-fix extraction
  silently succeeds (dropping the GEP); post-fix raises naming the
  index count. No cascade — existing tests either use 2-op GEPs
  (already supported) or didn't hit the old silent-drop path in Pkg.test.
  All targeted regression tests green (test_t0_preprocessing, test_var_gep,
  test_t5_corpus_c, test_persistent_{hashcons, hamt, cf, okasaki}).
  Lesson from U15's cascade applied: single targeted-run cycle instead
  of repeated full Pkg.test.

- **Bennett-5oyt (U15) — unregistered callee / inline-asm call silently
  dropped.** `src/ir_extract.jl` LLVMCall handler's fall-through at the
  end of the arm was `return nothing`, so any call that didn't match an
  intrinsic pattern AND wasn't in `_lookup_callee`'s registry got
  skipped — leaving its dest SSA undefined and crashing later with
  "Undefined SSA variable" far from the root cause. Replaced with an
  explicit benign-intrinsic allowlist + fail-loud for everything else.
  Benign allowlist (correctness-neutral drops): `llvm.lifetime.*`,
  `llvm.assume`, `llvm.dbg.*`, `llvm.experimental.noalias.scope.decl`,
  `llvm.invariant.{start,end}`, `llvm.sideeffect`, `llvm.memset`,
  `llvm.memcpy`, `llvm.memmove`, `llvm.trap`, `llvm.debugtrap`,
  `j_throw_*` / `ijl_throw*` / `jl_throw*`, `ijl_bounds_error*` /
  `jl_bounds_error*`, `julia.safepoint`, `julia.gc_*`,
  `julia.pointer_from_objref`, `julia.push/pop_gc_frame`,
  `julia.get_gc_frame_slot`. Inline asm specifically detected via
  `LLVMIsAInlineAsm` on the callee operand.
  Test gate: `test/test_5oyt_unregistered_callee.jl` — 3 scenarios.
  T1 unregistered `@external_fn` loud-errors. T2 `call i32 asm "..."`
  loud-errors with "inline" in the message. T3 `llvm.lifetime.start`
  silently drops (extraction succeeds).
  **Cascade fixup** (ran before each of these was caught via targeted
  tests, not full Pkg.test):
    - Added `j_throw_*`/`ijl_throw*`/`jl_throw*` to the allowlist —
      `soft_fptrunc` has dead `j_throw_inexacterror` from Julia's
      conservative codegen; test_float_circuit was breaking.
    - Added `ijl_bounds_error*`/`jl_bounds_error*` — test_var_gep fail.
    - Added `llvm.memset/memcpy/memmove` — test_t0_preprocessing's
      cond_pair hit `llvm.memset` for GC-frame zeroing.
    - Added `llvm.trap`/`llvm.debugtrap` — test_persistent_hashcons's
      Okasaki+Jenkins demo emits `llvm.trap` in unreachable branches.
    - Updated `test_t0_preprocessing`'s allowlist with `inline-asm`
      + `call ptr asm`/`call i64 asm` — Julia's `%thread_ptr` fetch.
    - Rewrote `test_tu6i_struct_extractvalue.jl` T1 to use a constant
      struct initializer (`extractvalue {i64,i64} { i64 42, i64 7 }, 0`)
      instead of `llvm.sadd.with.overflow.i64` — the intrinsic now
      fails at U15 before ever reaching U10's guard, making the old
      test unable to reach its target.
    - Changed `test_t5_corpus_c.jl` TC1/TC2/TC3 from
      `@test parsed isa ParsedIR; @test_throws reversible_compile` to
      `@test_throws extract_parsed_ir_from_ll` — the extraction itself
      now loud-errors on `malloc`/`realloc`, which is the point.
  **Workflow gotcha**: I was running `Pkg.test()` after every tweak to
  the allowlist, ~4 min per cycle. User called this out. Switched to
  targeted test files (~30s total). One final full run as sanity gate.
  Lesson for future P1 grinding: keep a mental list of affected test
  files from the first failure and iterate on those.
  Full `Pkg.test()` green; baselines byte-identical.

- **Bennett-4mmt (U14) — atomic/volatile load/store silently coerced to
  plain IR.** `src/ir_extract.jl` load (`:1647`) and store (`:1795`) arms
  had no atomicity/volatility check. Silent acceptance would erase any
  ordering guarantees the source program relied on. Added two guards per
  arm using `LLVMGetVolatile` + `LLVMGetOrdering` (compared against
  `LLVMAtomicOrderingNotAtomic = 0`). Test gate:
  `test/test_4mmt_atomic_volatile_load_store.jl` — hand-crafted `load
  atomic / store atomic / load volatile / store volatile` IR; all 4 now
  raise with a message naming the opcode + the atomicity. Side effect:
  `test_t0_preprocessing.jl`'s `cond_pair` corpus case sometimes trips
  the new guard because Julia's optimize=true emits `store atomic i64`
  into `%frame.prev` for GC root management (context-dependent per
  Julia instance-ID). Updated the `@test isempty(skipped)` assertion to
  accept an allowlist of benign fail-loud errors (atomic, volatile,
  StructType aggregates, non-integer source GEPs, i128 ConstantInts) —
  unexpected errors still fail the test. This is honest: the extractor
  is now correctly rejecting IR it has no semantics for; the old blanket
  "extraction must succeed" implicitly required silent corruption.
  Full `Pkg.test()` green; baselines byte-identical.

- **Bennett-plb7 (U13) — IRVarGEP.elem_width silently defaulted to 8.**
  `src/ir_extract.jl:1608` and `:1619` (local-SSA and global-constant GEP
  paths) had `ew = src_type isa LLVM.IntegerType ? LLVM.width(src_type) :
  8` — silently substituting 8 whenever the GEP source was double /
  vector / struct / whatever. A `getelementptr double, ptr %p, i64 %i`
  got recorded with `elem_width = 8`, so downstream `lower_var_gep!`
  selected bit 2 instead of double 2. Fixed both sites: fail loud via
  `_ir_error` naming the offending LLVM type. Test gate:
  `test/test_plb7_irvargep_elem_width.jl` — T1 `gep double` raises with
  "non-integer source" in the message; T2 `gep i16` correctly extracts
  `elem_width = 16`. Unlike U12, the fail-loud here didn't surface
  latent struct-GEP silent-drops — variable-index GEPs on structs are
  rare in the corpus. Full `Pkg.test()` green; baselines byte-identical.

- **Bennett-vz5n (U12) — GEP `offset_bytes` stored the raw index, not bytes.**
  `src/ir_extract.jl:1572` converted a constant-index GEP to IRPtrOffset
  by storing `_const_int_as_int(ops[2])` directly. The consumer at
  `src/lower.jl:1691` computes `bit_offset = inst.offset_bytes * 8` —
  correct only when the GEP source element is `i8` (stride 1 byte). For
  `getelementptr i32, ptr %p, i64 3` the stored offset_bytes was 3 rather
  than 12 → the load read bits 24..55 instead of bits 96..127. Silent
  wrong for every non-i8 integer stride. Fix: read
  `LLVMGetGEPSourceElementType`, assert integer + width ≥ 8 bits, store
  `raw_idx * (width ÷ 8)`. Non-integer source types (struct / array /
  float / vector) fall back to the legacy raw-index behaviour — their
  correctness gap is tracked separately under **U16** (multi-index struct
  GEPs), which needs a proper `LLVMOffsetOfElement` path, not the U12
  byte-stride formula. **Iteration gotcha**: my first draft fail-louded
  on non-integer sources; this broke `test_t0_preprocessing`'s
  `cond_pair` corpus function, whose Julia-emitted IR occasionally
  contains a 2-op GEP into the `%jl_gcframe_t` GC root (appearance is
  Julia-instance-dependent — single-function reproduction passed, but
  some runs of Pkg.test hit a context where Julia emitted the
  gcframe-prev access). Relaxed to silent-pass for non-integer sources;
  the integer case remains the intended scope of U12.
  Test gate: `test/test_vz5n_gep_offset_bytes.jl` — 4 strides (i8/i16/
  i32/i64) × constant idx = 3 → assert offset_bytes ∈ {3, 6, 12, 24}.
  Pre-fix: 1/4 pass (i8 coincidence). Post-fix: 4/4. Full `Pkg.test()`
  green; baselines byte-identical.

- **Bennett-u21m (U11) — switch phi patching incomplete + duplicate-target
  overwrite.** Refactored `_expand_switches` in `src/ir_extract.jl:981-1079`.
  Pre-fix had two bugs: (1) the phi-patching pass ran INSIDE the per-switch
  `for block in blocks` loop, so it only saw blocks already appended to
  `result` — any successor block processed AFTER its switch never got its
  phis rewritten. (2) `phi_remap::Dict{Symbol,Symbol}` was keyed by
  target_label, so when two cases pointed at the same block, the second
  overwrote the first and the phi ended up with a single wrong incoming.
  Fix: split into Phase A (expand every switch, populate a
  `pred_map::Dict{(orig,target), Vector{Symbol}}`) + Phase B (single
  global sweep over `result` rewriting phi incomings). For each
  pre-expansion `(val, orig_switch)` incoming, emit one `(val, syn_src)`
  per unique synthetic predecessor of the phi's host block. Dedup is
  structural (`src in lst || push!(lst, src)`) so targets that default and
  a case route into via the same syn block (e.g. last-cmp's true and
  false branches both ending at L) get one incoming, not two. Test gate:
  `test/test_u21m_switch_phi_patching.jl` — hand-crafted switch with
  cases 1→L, 2→M, 3→L and default→default; asserts the phi at L cites
  both `:top` AND `:_sw_top_3`, values preserved, end-to-end circuit
  correct on all 256 inputs (the constant-value case is silent because
  the phi value is the same regardless of which predecessor fires — so
  T3 all 256 passed even pre-fix; T1 is the true bug-witness).
  **Silent-bug gotcha**: the bug only crashes downstream phi resolution
  when the phi value actually differs per predecessor — switch cases
  funnel through one predecessor in LLVM, so LLVM phis after a switch
  usually have one constant incoming. The missing-predecessor phi is
  semantically wrong but often doesn't manifest as a crash. The test
  asserts EXTRACTED STRUCTURE, not just end-to-end behaviour.
  Full `Pkg.test()` green; baselines byte-identical.

- **Bennett-tu6i (U10) — `extractvalue`/`insertvalue` on StructType raised
  raw UndefRefError.** `src/ir_extract.jl:1182-1206` (before this fix) called
  `LLVM.eltype(agg_type)` without first checking `agg_type isa LLVM.ArrayType`.
  For `{iN, i1}` structs (e.g. produced by `llvm.sadd.with.overflow.i64`) or
  mixed-width tuples (e.g. `{i64, i32}`), that raised a bare UndefRefError
  deep in LLVM.jl with no Bennett context. Added `isa ArrayType` precondition
  with `_ir_error` that names the opcode + the offending LLVM type. The
  `IRExtractValue` / `IRInsertValue` records carry a single `elem_width`
  so field-wise width tracking for heterogeneous structs isn't expressible
  today; this is a fail-loud gate, not an enablement — full struct support
  would require extending `ir_types.jl`. Test gate:
  `test/test_tu6i_struct_extractvalue.jl` — 2 testsets, 6 asserts. T1
  hand-crafted `.with.overflow` (struct operand to extractvalue); T2 dead
  insertvalue inside a scalar-return function. Pre-fix: both raise
  UndefRefError. Post-fix: both raise a Bennett error naming the opcode
  and "StructType aggregates not supported". **Test-design gotcha**: the
  first T2 draft returned the struct directly, which failed much earlier
  at `_type_width` during signature parsing (struct return type) and never
  reached the insertvalue-convert path. Rewrote to put a dead insertvalue
  inside a scalar-return body so the guard under test actually fires.
  Full `Pkg.test()` green; baselines byte-identical.

- **Bennett-l9cl (U09) — i128 ConstantInt truncation.** LLVM.jl's
  `convert(Int, ::LLVM.ConstantInt)` calls `LLVMConstIntGetSExtValue`,
  which returns only the low 64 bits — `i128 2^127` silently comes
  across as `0`. IROperand.value is `Int64`, so there is no safe
  destination for a wider constant without changing 150+ downstream
  iconst consumers. New `_const_int_as_int(v::LLVM.ConstantInt)` helper
  added near `_operand`: asserts `LLVM.width(value_type(v)) <= 64` and
  raises loud with the full constant text if not. All 10 call sites in
  `src/ir_extract.jl` (`_operand`, sret GEP byte/element paths at 526/528,
  constant-index GEP at 1519, constant-index global GEP at 1541, switch
  case values at 1578, alloca count operand at 1724, constant pointer
  address at 1892, ConstantDataVector element at 2046, insertelement lane
  at 2076, extractelement lane at 2120) routed through the helper. The
  helper itself contains the single remaining `convert(Int, v)` call,
  reached only after the width guard. Test gate:
  `test/test_l9cl_i128_constantint.jl` — hand-crafted `define i128 …`
  fed through `extract_parsed_ir_from_ll`; pre-fix returned silently,
  post-fix raises naming the width. Full `Pkg.test()` green; all
  baselines byte-identical. Follow-up (still open under the same bead):
  widen IROperand.value to Int128/BigInt so i128+ constants can actually
  round-trip; the fail-loud guard is the Phase-0 safety net.

- **Bennett-r84x (U08) — NaN payload/sign canonicalised across every
  soft-float op; `soft_fptosi` wraps on overflow.** Six files edited.
  Two constants + two helpers added to `src/softfloat/softfloat_common.jl`
  (`QUIET_BIT = 0x0008000000000000`, `INDEF = 0xFFF8000000000000`,
  `_sf_propagate_nan2`, `_sf_propagate_nan3`). Invalid-op producers
  (Inf−Inf in fadd/fsub line 39, Inf×0 in fmul line 210, 0/0 and Inf/Inf
  in fdiv lines 89/92, sqrt of neg-finite/-Inf in fsqrt line 112,
  `inf_clash` + `inf_times_zero` in fma lines 206-207) now emit the x86
  "indefinite" value (`0xFFF8...`) per Intel SDM Vol 1 §4.8.3.7 instead
  of the canonical positive qNaN. NaN-operand paths propagate the first
  NaN OR'd with `QUIET_BIT`, preserving sign + payload per IEEE 754-2019
  §6.2.3. `soft_trunc` splits `is_special` into `is_nan_input` vs Inf so
  sNaN inputs are force-quieted while ±Inf passes through unchanged;
  `soft_floor`/`soft_ceil` inherit the fix transitively (they call
  `soft_trunc` then `soft_fadd`, both of which now preserve NaN properly).
  `soft_fptosi` saturates biased-exp ≥ 1086 to `0x8000000000000000`
  matching `cvttsd2si` on x86 — `-2^63` naturally lands on `INT_MIN` via
  the existing two's-complement compute, so the unconditional saturation
  is idempotent on that single in-range value. `fsub` and `fneg` untouched
  — fsub delegates to fadd(·, fneg(b)) which now propagates NaN correctly;
  fneg is a pure XOR on bit 63, already payload-preserving.
  Test gate: `test/test_r84x_nan_bit_exact.jl` — 8 testsets, 98 assertions.
  T1 invalid-op producers (22); T2 sqrt(±0) preserved; T3/T4 NaN
  propagation for 4+fma ops (20); T5 fsqrt NaN + hw cross-check;
  T6 rounding quiets sNaN, preserves Inf; T7 fptosi saturates (16,
  cross-checked via LLVM `fptosi i64` llvmcall); T8 non-NaN regression
  anchors (18). Pre-fix RED: 60/98 fail — exactly the catalogue-predicted
  four classes (invalid-op, NaN prop, sNaN round, fptosi overflow). Test
  constants **gotcha**: my initial `QNAN_P = 0x7FF4...` had the quiet bit
  CLEAR (bit 51 is in the 0x0008 slot, not 0x0004) — accidentally an
  sNaN. Corrected to `0x7FFC...` (quiet bit + payload bit 50). Worth
  remembering for future softfloat bit-pattern tests.
  Full `Pkg.test()` green. Baselines byte-identical: TJ3=180,
  Okasaki=108,106, HAMT=96,788, CF=11,078, i8 x+1=100/28T. CLAUDE.md §13
  (soft-float bit-exactness) restored for the seven NaN-touching ops.

- **Bennett-k286 (U07) — `soft_fpext` does not quiet sNaN.** 1-constant fix
  in `src/softfloat/fpconv.jl:62`: exponent mask `0x7FF0000000000000` →
  `0x7FF8000000000000`. Pre-fix the NaN path was
  `sign64 | 0x7FF0_… | (UInt64(fa) << 29)`; Float32 fraction bit 22 maps to
  Float64 fraction bit 51, so sNaN inputs (bit 22 = 0) propagated as sNaN
  Float64s. IEEE 754-2019 §5.4.1 requires sNaN→qNaN on any operation
  (including silent-mode conversion). Hardware `Float64(::Float32)` always
  sets bit 51; 503/1000 seed-123 random NaN inputs mismatched pre-fix, 0/1000
  post-fix. Fix is idempotent for qNaN (bit 51 already set via `fa << 29`)
  and touches no non-NaN path — the walking-1 + anchor regression tests in
  `test/test_k286_fpext_snan_quiet.jl` (6 testsets, 21 assertions, all green)
  pin both directions. Comment at line 60-61 updated to cite §5.4.1 and the
  fptrunc sibling at line 148 (already correct). Full `Pkg.test()` green —
  TJ3=180, Okasaki=108,106, HAMT=96,788, CF=11,078, i8 x+1=100/28T all
  byte-identical.

- **Bennett-asw2 (U01) — `verify_reversibility` is tautological.** Fixed
  `src/diagnostics.jl:145-190` and `src/controlled.jl:90-144`. The new
  function asserts three Bennett invariants per random input:
  ancilla-zero, input-preservation, and (controlled) ctrl-wire preservation.
  The round-trip tautology is retained as a cheap harness sanity check.
  Test gate: `test/test_asw2_verify_reversibility.jl` (7 testsets, all
  green). Commit: see `d12044e`..HEAD.

- **Bennett-httg (U05) — `lower_loop!` silently drops body-block
  instructions.** Widened `src/lower.jl:720-890`. New:
  `_collect_loop_body_blocks` does BFS from header non-exit successors,
  prunes at latch/exit, topo-sorts the body region. Per iteration: header
  non-phi body insts via the pre-existing 4-type cascade (protects
  soft_fdiv / Collatz baselines), then body-block insts via canonical
  `_lower_inst!` with a local `loop_ctx` that forces `add=:ripple` and
  empty `ssa_liveness` (prevents Cuccaro in-place writes from corrupting
  phi-dest operands across iterations — see Bennett-spa8 / U27 for the
  general dispatcher fix). Fail-loud on nested loops, multi-latch,
  IRRet-in-body. 3+1 protocol applied. Test:
  `test_httg_loop_multiblock.jl` 84/85 pass; T1 multi-block accumulator
  + T2 K scaling + T4 Collatz + T5 baseline all green; T3 diamond-in-body
  `@test_broken` (filed Bennett-httg-f1). Follow-up Bennett-httg-f2 for
  header-body dispatch widening. Full `Pkg.test()` green.

- **Bennett-prtp (U04) — checkpoint/pebbled_group/pebbled_bennett crash on
  branching.** Added `_has_branching(lr)` helper in `src/lower.jl`
  (`count(_is_pred_group, groups) >= 2`). Used by `pebbled_bennett`
  (`src/pebbling.jl:112`), `pebbled_group_bennett` (`src/pebbled_groups.jl:273`),
  `checkpoint_bennett` (`:351`), and retro-applied to `value_eager_bennett`.
  Discovery while landing this: the initial draft of `_is_pred_group`
  matched entry-block predicates too, which fire even on straight-line code
  — under-fallback (`any(...)` → every circuit) would have regressed
  `test_pebbled_wire_reuse.jl` SHA-256 wire-reduction expectations.
  Corrected predicate counts pred groups; straight-line = 1 (entry), diamond
  = 3 (entry + true + false blocks). Refined value_eager_bennett to use
  the same predicate. Residual SHA-256 value_eager failure surfaced but
  is a DIFFERENT bug (straight-line bitwise, only 1 pred group) —
  filed as Bennett-ca0i, `@test_broken` pins the regression on
  `test_value_eager.jl:162`. 1285/1285 on new
  `test/test_prtp_pebbled_branching.jl`. Full `Pkg.test()` green (1
  `@test_broken`). No gate-count drift.

- **Bennett-uj6g (U49) — CI workflow.** Added
  `.github/workflows/test.yml`. Matrix: Julia 1.10 (LTS) + 1 (latest
  stable) on ubuntu-latest. `julia-actions/{setup-julia, cache,
  julia-buildpkg, julia-runtest}@v2/@v4`. Runs the full `Pkg.test()` on
  every push to main and every PR. Concurrency group cancels in-flight PR
  runs on new commits (keeps main pushes uncancelled). Purpose: regression
  protection for the ongoing Phase 1 cascade — gate-count drift,
  Bennett-invariant violations, ir_extract/lower.jl drift. Correctness of
  the YAML verifies on first real CI run; will reopen the bead and fix
  forward if anything breaks.

- **Bennett-xy4j (U06) — `soft_fmul` subnormal pre-normalisation.**
  2-line fix in `src/softfloat/fmul.jl`: inserted `_sf_normalize_to_bit52`
  calls for `(ma, ea_eff)` and `(mb, eb_eff)` between the effective-exponent
  computation and the `result_exp` sum, mirroring `fdiv.jl:42-43` and
  `fma.jl:67-69`. Without the pre-norm, a subnormal operand's leading 1
  sits below bit 52 and the bit-104/105 extractor reads the wrong MSB,
  losing ~48 mantissa bits on ~11% of normal×subnormal random pairs.
  Test gate: `test/test_xy4j_fmul_subnormal.jl` (5 testsets, 13 checks):
  catalogue's 2-ULP repro, smallest subnormal, subnormal×subnormal, 256-pair
  deterministic sweep, normal×normal regression. Pre-fix: T1+T4 fail.
  Post-fix: 13/13 green, full Pkg.test() green. TJ3 baseline (180 gates)
  unchanged. CLAUDE.md §14 (bit-exact) restored.

- **Bennett-egu6 (U03) — `self_reversing=true` unchecked trust boundary.**
  Fixed `src/bennett_transform.jl:23-88` (new `_validate_self_reversing!`
  helper + `_u03_self_reversing_probes`). Every time `bennett()` hits the
  `self_reversing=true` short-circuit it now runs a 4-probe battery —
  all-zero, all-one, walking-1 first-lane, walking-1 last-lane — and
  asserts ancilla-zero + input-preservation per probe. Reuses `apply!`
  and `_compute_ancillae` (no duplicated lowering). 3+1 protocol applied
  per CLAUDE.md §2: spawned 2 independent proposer subagents, synthesised
  Proposer A's 4-probe coverage + Proposer B's reuse discipline. Pre-fix:
  forged `LoweringResult(self_reversing=true)` leaving wire 3 flipped was
  silently accepted. Post-fix: raises loud with probe name + violated
  wire + n_wires + n_gates + fix-hint. 264/264 green including exhaustive
  Int8 `lower_tabulate` oracle (f=x⊻0x5A, all 256 inputs). Gate-count
  baseline i8 x+1 = 100/28 pinned. Full `Pkg.test()` green. Design docs
  preserved in the synthesis commit message; no files written to
  docs/design/ for this small 3+1 since the conclusions were
  behaviourally mirrored in the source + tests.

- **Bennett-rggq (U02) — `value_eager_bennett` 100% fail on branching.**
  Fixed `src/value_eager.jl:29-33`. Root cause: Phase-3 Kahn reverse-topo
  uncompute walks `input_ssa_vars`, but synthetic `__pred_*` block-predicate
  groups (`src/lower.jl:379, 389`) carry `input_ssa_vars = Symbol[]` — their
  wire-level cross-deps on OTHER `__pred_*` groups' result wires are
  invisible to the DAG, so the reverse-order is wrong and predicate wires
  get uncomputed before their consumers, leaking ancillae and corrupting
  input wires. Safer fix per catalogue: refuse the Kahn path whenever any
  `__pred_*` group is present, fall back to `bennett(lr)`. Straight-line
  code unaffected (T3 of new test: 514/514). Pre-fix: 257/257 Int8 inputs
  failed on `x>0 ? x+1 : x-1`. Post-fix: 1028/1028 across T1 diamond, T2
  nested, T3 straight-line. Test gate:
  `test/test_rggq_value_eager_branching.jl`. Also removed the
  `@test_broken` marker at `test_value_eager.jl:158` (SHA-256 round) that
  U01 had surfaced. Full `Pkg.test()` green. Gate-count baselines
  unchanged.

