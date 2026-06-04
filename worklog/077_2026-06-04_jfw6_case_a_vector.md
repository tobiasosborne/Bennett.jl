# 077 — 2026-06-04 — jfw6: `mem=:vm` Case A Memory recognizer (dynamic Vector)

**Beads:** `Bennett-jfw6` (recognizer) + `Bennett-bal6`, `Bennett-msob` (hardening),
all CLOSED. **Design:** BennettVM `docs/adr/0016-case-a-mem-vm-recognizer.md` (a
Rule-6 Core 2+1 design pass). Cross-repo with BennettVM (`m9i` ingest, already
proven on the C `frtN.ll`). Orchestrated from BennettVM (Opus 4.8).

## What landed

`src/extract/vector_vm{,_walk,_emit,_cfg,_term}.jl` (5 files, ≤127 code-LOC each,
literate) + routing in `module_walk.jl` (the `mem=:vm` Case A branch, replacing the
prior loud reject) + `ir_extract.jl` includes. Strips the Julia GC/GenericMemory
skeleton (`jl_alloc_genericmemory_unchecked`, the `julia.gc_loaded` data-pointer
launder, MemoryRef `{ptr,ptr,size}` chains, bounds/inexact throw diamonds, the
`%fs:0`/`julia.get_pgcstack` TLS read) and emits the language-neutral
`IRAlloca(dyn)+IRVarGEP+IRLoad/IRStore` shape BennettVM ingests. A dynamic Julia
`Vector{T}(undef,n)`+indexed write/read loop now round-trips end-to-end from source
under `target=:reversible_vm` (BennettVM `test/test_vec_vm_roundtrip.jl`; full
BennettVM `Pkg.test` **4722/4722**).

## Key decisions / lessons

- **`optimize=false` only.** At `-O2` the loop is SIMD-vectorized and the read-loop
  is deleted (return from a `llvm.vector.reduce`) — structurally unrecognizable.
  Extract via the existing `optimize=false` kwarg (no `entry.jl` change); reject the
  O2/`VectorType` signature loud.
- **A PARTITION recognizer, not purely subtractive** (the element data is *live into
  the return*, unlike the `:heap` M1 dead-skeleton case). Reuses heap.jl's M2/M3
  machinery — `_partition_skeleton`, `_prove_partition_sound`, `_build_rerooted_slice`,
  `_HeapArray.data_roots`, `_ElemAccess` (Law 2) — with the re-root base = the
  `DynAlloca`. heap.jl's soundness proofs (P-return/P-escape/P-noload/P-callee) are
  generalized to the partition.
- **`n_elems` = the element COUNT** read from the Memory length-field store
  (triple-witnessed vs the byte-size `smul` and the source arg), NOT the byte size.
  **byte-offset → element index via the RECOGNIZED stride**, never a hardcoded ÷8
  (the cell-addressed VM wants the element index; ADR 0016 D6).
- **P-callee allowlist must include the unmangled runtime throw entries**
  (`ijl_bounds_error_int`, `jl_throw`, `ijl_throw`, `jl_bounds_error`,
  `j_throw_*`, `*argument_error`) — they are dead-diamond skeleton. A first cut with
  a narrow allowlist over-rejected the NORMAL path; the regression was caught by the
  fresh-subprocess `Pkg.test` (a stale-cache standalone `julia test/file.jl` run had
  reported a false green). Lesson: gate on `Pkg.test()`, never a standalone file run.
- Routing strictly gated behind `mem===:vm` + a Vector-recognition check, so
  `:auto`/`:heap`/Case-B-Dict are byte-identical.

## Scope / next (Bennett.jl side)

Single dynamic array (Case A). Remaining: `push!`-grown Vector (`Bennett-jfw6`
sibling + BennettVM `xkl`); Case B Dict route-(b) needs the multi-array lift (two
GenericMemory backings keys+vals → BennettVM `uil`); `soft_frem` (`Bennett-tfx`);
IRPtrOffset `elem_width` (`Bennett-xv0u`); multi-index GEP (`Bennett-8e1f`); struct
aggregates (`Bennett-6bu3`); the Dict determinism guard (`Bennett-klgz`). RULE 14
`src/` changes under standing user approval.
