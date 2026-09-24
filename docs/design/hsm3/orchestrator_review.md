# Bennett-hsm3 (+ gcf7 D1/D3/D4, fnxh) — orchestrator review of proposals A and B

2026-09-24. Maintainer decision (explicit): semantic certification of `jl_global#N` literals,
with a BennettVM ADR 0021 Decision 3 amendment.

## Consensus (both proposers, verified in-session)
- Root cause: three+ consumers trust the NAME `jl_global#N` (seed in `_extract_const_globals`
  ×2, load alias arm, `_5viz_singleton_load`). Every interned heap literal has that name (Ref,
  struct/tuple boxes, Strings, non-empty Memory). New executed counterexample (B): `const M3 =
  Memory{Int}([7,8,9]); length(M3)+x` → BVM 10 vs 13, reverses cleanly.
- The live corpus (push!, fdict, rehash!, Dict{Int64,Int64}) binds ONLY empty GenericMemory
  singletons in surviving IR; non-singleton literals (throw-path Strings) live only in blocks the
  ptr_cells pruner drops ⇒ the fix does not re-wall the corpus.
- Classification runs in the producing session inside a GC-disabled window opened before
  emission; .ll/.bc ingest certifies nothing by default; imaging-mode (`external`) slots refused;
  `_parsed_ir_cache` is ptr_cells=false only; ParsedIR carries no address ⇒ caching sound.

## Decisions (synthesis)
1. **Classifier = A's membership test, no dereference.** Enumerate live empty GenericMemory
   singletons (`T.instance` over the GenericMemory TypeName cache(s), with A's self-test and
   version guard) and admit K iff K ∈ that set. Never `unsafe_pointer_to_objref` an extracted
   address (A: codegen temp roots are dropped after emission on the reflection path; membership
   is equally precise, since two live objects cannot share an address inside the GC-off window,
   and it cannot crash on garbage/foreign addresses). Diagnostics ("it is a `Base.RefValue{S2}`")
   via A's `_src_literal_types` (no deref), best-effort.
2. **Where it fails = B's use-directed scan + object-key rename.** Seed certified objects under
   `jl_global#N.obj` (B); record refused objects; after the walk, `_assert_no_refused_jl_global_use`
   over `compute_ssa_use_counts` fails loud on any surviving use of a refused object OR of a raw
   SLOT name. Keep the klgz GOT classifier and 3vf2 dead-use drop unchanged. Thread through a
   wrapper so every return point of the walk (dict_vm, vec_vm, heap_skel, normal) is covered.
3. **Slot/object guards (B):** scalar load of the slot, GEP Case B / array Case C on the slot,
   memcpy G5 from the slot → loud `_ir_error`s. All new errors via `_ir_error` (B risk 7:
   module_walk's benign-error swallow).
4. **O1 / Bennett-fnxh (B):** a load straight through `@"jl_global#N.jit"` (optimize=true folded
   the slot load) fails loud.
5. **5viz:** `_5viz_singleton_load` consults the certificate (three-state per B); a refused src
   gives a 5viz/hsm3-named message (fixes gcf7 D4 for this class).
6. **D3 = A's sentinel, B's clamp as fallback.** Seed the data-pointer cell with A's non-null
   `_EMPTY_MEMORY_DATA_SENTINEL` (inside BVM's globals trap band; identical across the set, so
   base-cancelling arithmetic is unchanged). Verify on BennettVM (push!/Dict E2E + a MemoryLoad
   at the sentinel traps). If ANY BVM divergence: fall back to keeping 0 + B's `[0,8)` 5viz clamp
   and file the faithful-pointer bead.
7. **.ll/.bc ingest:** default refuse; opt-in kwarg `jl_globals = :live_session` (B's name) that
   runs A's membership test (safe even for foreign addresses). Delete
   `_is_singleton_data_global_name` (tripwire test).
8. **ADR 0021 Amendment B:** merge both texts — classification-only use of the address at
   extraction time in the producing session; membership in the live singleton set; never
   dereferenced, never emitted, never read by the floor; `jl_global` naming is not evidence;
   no live session ⇒ nothing certified; the 416r.13 "structural" argument withdrawn; the D3 model.

## Tests (union of A §4 and B §7)
RED first: h1–h4, k1, m3, `const EA = Int[]` if applicable — throw with `Bennett-hsm3` in both
`extract_parsed_ir_set_from_julia` and `extract_parsed_ir` (ptr_cells=true); positives u1/he
(user-held empty Memory) extract with exactly one `.obj` key; thr (throw-path String) extracts with
no jl_global key; classifier units (A's six-address module incl. malloc/interior/garbage; B's
near-misses: unsafe_wrap length-0 Memory refused, Memory{Nothing}(undef,5), atomic/union
singletons certified); .ll ingest refuse/live_session/external; slot guards; O1 at optimize=true;
GC state restored; mutation proofs (A M1–M3). Migrate 5viz / bvmd (C) / 416r13 / foz5 fixtures to
live addresses + `:live_session`. Green bar: the 8 markers, 5viz, 416r13, 3vf2, 9n3y, klgz, t9rh,
c6ex, gate_count_regression. BennettVM: new E2E test (h1/h3/m3 throw at extraction; u1 runs and
reverses; sentinel trap), and re-run the existing Julia-extraction VM tests one at a time.
