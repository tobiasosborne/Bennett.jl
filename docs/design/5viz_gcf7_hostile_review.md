# Bennett-gcf7 — hostile review of 6a1f91d (Bennett-5viz), 2026-09-24 — verbatim

Probes/logs (ephemeral): session scratchpad gcf7/.

## Bennett-gcf7 hostile review of 6a1f91d (Bennett-5viz, wall 11): FAIL

The arm is structurally careful. Canonicalisation, clobber handling, 6c/6d/7/8, circuit-path gating and the marker discriminators all held up under testing. But it is unsound on the root it certifies. It trusts the global's name (`jl_global#N`) to mean "the empty GenericMemory singleton", and that name does not establish it. I executed a silent miscompile with ordinary Julia code. Pristine (6a1f91d~1) refuses these programs loudly. The current tree extracts them, and they run and reverse on BennettVM with wrong results.

Setup: I fast-forwarded the worktree to b18ff95 (includes t9rh and stwr). Between 6a1f91d and HEAD, the 5viz code path is unchanged; the only edits in `instructions.jl` are prefix-string hygiene. For execution I used a scratch env with this worktree's Bennett and `/home/user/BennettVM.jl` dev'd in. Nothing was committed or pushed, I did not run `bd`, and both temporary worktrees are removed.

### Defects

**D1 — CRITICAL (silent miscompile, executed).** The src certification admits any `load ptr, ptr @"jl_global#N"`, and Julia names every heap-object literal that way, not just empty-Memory singletons.
- **Where:**
  - `src/extract/instructions.jl:2906-2921`: `_5viz_singleton_load` gates on `_is_singleton_data_global_name`, which is a name regex, `constexpr.jl:158`.
  - `instructions.jl:3040`: the DIRECT shape.
  - The certified global is then read as the `(zeros(UInt64,16), 8)` blob from `module_walk.jl:1018`.
- **Evidence:** probes `gcf7/probes/p3.jl`, `p4_vm.jl` and `p5_vm.jl` in the scratchpad. `code_llvm(optimize=false)` shows `memcpy(%.x, %"jl_global#N", 8|16)` straight off the loaded literal.

```julia
struct W1; a::Int; end; const RW = Ref(W1(42)); h2(x::Int) = RW[].a + x
struct S2; a::Int; b::Int; end; const R = Ref(S2(3,4)); h1(x::Int) = R[].a + x
const T1 = Ref((77,)); h4(x::Int) = T1[][1] + x
```

| program | pristine | current tree | BennettVM, x = 0 / 10 / -5 | oracle | reverses? |
|---|---|---|---|---|---|
| h1 | rejected at Predicate-6 src (37mt/8bys) | extracted | 0 / 10 / -5 | 3 / 13 / -2 | yes, exactly |
| h2 | rejected | extracted | 0 / 10 / -5 | 42 / 52 / 37 | yes |
| h4 | rejected | extracted | 0 / 10 / -5 | 77 / 87 / 72 | yes |

- **Variants:** `k1`/`k2`/`k3` (the ref boxed first) fold back to the same direct shape and give the same mismatch.
- **Why the tests stay green:** every 5viz fixture hand-writes `@"jl_global#93"` with an unreadable initializer. No test asserts a value or runs anything, and the BVM end-to-end gate was never written.
- **Pre-existing assumption this builds on:** the 416r.13 comment at `module_walk.jl:1000-1004` says the empty-vs-non-empty guard "is structural". That is false: `Ref`, `Memory` and `Array` literals all have the same opaque `.jit` alias initializer (probe `p1.jl`).
- **The scout's claims are corpus facts, not something the predicate enforces:** "S-A root identity via `.globals`" and the D1-class-hazard argument both assume the global is the empty singleton.
- **Fix suggestion:** certify "empty GenericMemory singleton" semantically, not by name.
  - Option (a): the closed-world Julia producer, which has the live session, resolves each `jl_global#N` alias address to its object at extraction time and seeds `.globals` only when `x isa GenericMemory && length(x) == 0`. Every other literal fails loud at the load site. This needs an ADR 0021 D3 amendment; D3 only forbids baking the address into the result, not classifying with it.
  - Option (b), minimum: until (a) exists, refuse 5viz admission for the DIRECT shape. Also require the canonicalisation path to pass through a `memory_ref`-shaped `{ptr, ptr}` field-1 store. This narrows the attack surface but does not prove emptiness, so treat it as an interim measure.
  - Either way, add an executed BVM test with a non-empty `const Ref` literal that must fail loud.
  - Do not add the bead's BVM end-to-end gate until this is fixed; on the fixtures it would pass vacuously.

**D2 — MAJOR (pre-existing, same root cause, not introduced by 5viz; needs its own bead).**
- **What:** at `ptr_cells=true`, a direct scalar read of a non-empty literal miscompiles without 5viz involved: `const RI = Ref(42); h3(x) = RI[] + x` becomes `IRLoad(.x, jl_global#N, 64)` off the zero blob.
- **Result:** BennettVM returns 0 / 10 / -5 against oracle 42 / 52 / 37, and reverses cleanly (`p4_vm.jl`). Behaviour is identical in pristine and current.
- **Fix:** the same semantic certification as D1, applied in `_extract_const_globals` and the `_handle_load` alias arm (`instructions.jl:~7420`).

**D3 — MINOR (modelling scope widened without re-justification).**
- **What:** the 416r.13 zero blob sets the data pointer at byte 8 to 0. The shipped justification says this "feeds only a compile-time len-0 memset — inert".
- **Why that no longer holds:** 5viz now admits memcpys reading [8,16), fixtures (b) and (c), which copy that fake null pointer into arbitrary allocas and arena cells. The real empty singleton's data pointer is non-null (measured `0x00007f33f4ca4e20`), so a later pointer compare against null diverges silently.
- **Fix:** restrict the 5viz src range to the length field [0,8) until the data pointer has a faithful model, or register the (global, 8, 64) field in `synth_ptr_provenance` so the land-ptrload guard catches uses.

**D4 — MINOR (fail-loud message quality).** When `_5viz_global_src_root` partly succeeds and then declines, the user gets the unchanged "src operand is not alloca-backed … Bennett-37mt" text, which is misleading. Examples: canonicalisation reaches a `jl_global` load but `names[v] !== gname`, or the global is missing from `.globals`. It is still loud, so not a soundness issue. Fix: a distinct 5viz-named reject when canonicalisation reached a GlobalVariable load but a later clause failed.

**D5 — NIT (wrong test comment).**
- **Where:** `test/test_5viz_loaded_ptr_src_memcpy.jl:461-462` says gate (a) is 6d's mutation test ("flipping `<=` to `<` reddens (a)").
- **Why it's wrong:** (a) is `0+8 <= 16` and is not flush. The flush case is (c) (`8+8 == 16`), and (c) is what goes red under that mutation. The `occursin("16", msg)` assertion is also weak.
- **Fix:** repoint the comment to (c) and pin the `[8, 24)` range text instead.

**D6 — NIT (marker positive doesn't pin the site).** The wall-12 positives (`Bennett-p06b` + `_p06b_cell_ptr_target_kind` + `SILENTLY SKIPS`) do not identify which aggregate store failed. A regression that walls at a different `alloca {ptr,ptr}` store would still read as wall 12. The negatives are sound, so this is acceptable under Rule 5, but record it.

**D7 — PROCESS (known).** `test_5viz_loaded_ptr_src_memcpy.jl` is still not registered in `test/runtests.jl` at HEAD, and the BennettVM end-to-end gate is unwritten. Both are gcf7 items 1 and 2.

### What held up under attack
- **Canonicalisation and clobber hygiene, the 57hd D1 lesson** (`p6_clobber.jl`, hand-written `.ll` with a noalias `gc_alloc_obj`). An escaping call, a store through a loaded pointer, a self-store, a byte-GEP same-slot store, a memcpy into the box, an i64 overwrite and a partial i32 overwrite each fall back to the unchanged 37mt wall. A store through an Argument is admitted, which is correct because an argument cannot alias the fresh box.
- **Canon-block trap:** mutation M1 (canonicalise in `LLVM.parent(base)`, the extractvalue's block) turns (a), (b), (c), (d), (g), (h) and (j) red, so the three-block fixtures really control for it. Note that the corpus gate (k) stays green under M1, because in the real corpus the extractvalue and the load share `%top`.
- **Capacity (the sy29 D2 lesson):** 6d is enforced with the doih G8 formula. (c) is flush and admitted; (g) overshoots and is rejected. Alignment and negative offsets are refused, and Predicate 8's 64-bit value width is correct.
- **No existing check weakened:** the only relaxation is the src-naming check, and it is justified by the alias the load arm installs. Circuit-path (`ptr_cells=false`) gating is intact per (i).
- **Wall-12 `.mem` discriminator:** all eight marker files carry `!Bennett-37mt` and `!new::Array.ref.mem` with the suffix. In pristine, exactly the 3 positives and 2 negatives fail in each file, and sy29's `!new::Array.size_ptr` stays true there, so the wall-11-versus-wall-9 discrimination really fires.

### RED verification (all runs `--check-bounds=yes`)

| file | pristine 6a1f91d~1 + new tests | current b18ff95 | claimed |
|---|---|---|---|
| test_5viz_loaded_ptr_src_memcpy | 50 pass, 17 fail, 5 error | 91/91 | 91 |
| test_sy29_arena_src_memcpy | 93 pass, 5 fail (gate i) | 98/98 | 98 |
| test_57hd_value_identity | 96 pass, 5 fail (W) | 101/101 | 101 |
| test_40ys_instanceless_callees | 130 pass, 5 fail | 135/135 | 135 |
| test_7wsz_ptr_sret_fields | 108 pass, 5 fail | 113/113 | 113 |
| test_bvmd_root_scale | 86 pass, 5 fail | 91/91 | 91 |
| test_foz5_confined_bounds | 65 pass, 5 fail | 70/70 | 70 |
| test_p06b_aggregate_store | 619 pass, 5 fail | 624/624 | 624 |
| test_vau9_variable_memmove | 71 pass, 5 fail | 76/76 | 76 |
| test_gate_count_regression | — | 39/39 | 39 |

Every claimed count reproduces, and every advance is genuinely red in pristine.

### t9rh and stwr interaction
- **stwr:** no interaction.
- **t9rh:** no interaction with the 5viz path. The closed-world producer extracts bodies at `optimize=false`, and every corpus marker is green after t9rh.
- **Separate finding (O1, pre-existing, not from t9rh or 5viz):** at `optimize=true`, `h2` extracts to a single `IRBinOp` whose operand `.x.0.copyload` is never defined. The IR is `load i64, ptr @"jl_global#72.jit"`, and the load arm skips that GlobalAlias operand silently, which breaks CLAUDE.md §1. It is the same in pristine. Worth a bead.

### What I could not check
- A real-Julia instance of the store-forward (non-DIRECT) shape with a non-empty global. Julia folds the boxing away even at `optimize=false`, so only the DIRECT shape was executed. The root cause is the same.
- The BennettVM end-to-end gate (unwritten) and the full suite (out of protocol).
- A 6d `<` mutation run. I reasoned it from the arithmetic instead.
- Whether the push! corpus itself can ever bind a non-singleton `jl_global`.

Probes and logs are in `/tmp/claude-0/-home-user-Bennett-jl/3321b1e1-b9ad-5f3e-aa45-12923102bdac/scratchpad/gcf7/`: `probes/p1`–`p7`, `summary.txt`, `log_*`, `log_mut_M1.txt`, and `vmenv/`.