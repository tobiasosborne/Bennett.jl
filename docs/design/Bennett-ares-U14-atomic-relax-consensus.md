# Bennett-ares — CW-D2 lever 1: VM-gated U14 atomic relaxation (3+1 consensus)

Orchestrator-reviewer decision after 2 independent proposers (A, B) + a skeptical
live closure scan (Rule 10). Date 2026-06-19.

## Decision
- **Gate:** reuse the existing `ptr_cells::Bool` flag threaded into
  `_convert_instruction` (sole setter `module_walk.jl`; the closed-world/VM
  cell-model switch; defaults false; `reversible_compile` never passes it).
  Both proposers independently rejected a new flag and `mem===:vm` (the latter
  is unreachable — it routes to `_dict_vm_extract`/`_vec_vm_extract` before the
  block-conversion loop). Justification for relaxation is a property of the
  CONSUMER (BennettVM: deterministic, single-threaded, history-reversible → no
  concurrent observer → ordering contract vacuous), and `ptr_cells=true` is set
  only by VM/closed-world producers.
- **Accepted ordering band under the gate:** `{NotAtomic, Unordered, Monotonic,
  Acquire, Release}` = LLVM enum `{0,1,2,4,5}`.
- **Still fail-loud under the gate:** `AcquireRelease(6)`, `SequentiallyConsistent(7)`,
  and `volatile` (under BOTH gates — volatile is an I/O-effect contract, not an
  ordering one).
- **Circuit path (`ptr_cells=false`): BYTE-IDENTICAL.** The else-arm is the
  original guard verbatim; same `_ir_error` text (the VM-only explanatory suffix
  is appended only when `ptr_cells` is true). Baselines hold: i8 x+1=58,
  gate_count 39/39, lf14 GATE-A pins.

## Ground truth (skeptical live scan, optimize=false, this machine, 2026-06-19)
- setindex!:               7× load/unordered;            2× fence
- rehash!:                 4× load/unordered; 6× store/release; 2× fence
- ht_keyindex2_shorthash!: 7× load/unordered;            2× fence
- atomicrmw=cmpxchg=0 everywhere; volatile=0 everywhere.

Proposer A's narrow {Unordered,Monotonic} band would re-wall the closure at
rehash!'s 6 release stores → adopt B's wider band. The closure emits ONLY
`unordered`+`release`; monotonic/acquire are conservative vacuous duals.

## NEW finding (neither proposer): 2 `fence` per callee
`fence` is a standalone barrier opcode (LLVMFence), a SEPARATE lever from U14
load/store. Likely the next wall after this lever (or interleaved). Include
"fence" in the GATE-D wall-advance disjunction; file a follow-up bead.

## Critical implementation note (from Proposer A)
Integer load/store fall-through (`rt isa IntegerType` arm) is GATE-INDEPENDENT.
The relaxation predicate MUST be `ptr_cells && relaxable(ord)` — relaxing
integer atomics ungated would change ptr_cells=false integer-atomic behavior
(byte-identity violation). GATE-C of the test locks this.

## Edits (both guards, instructions.jl ~2382 load / ~2628 store)
Helper `_vm_relaxable_ordering(ord) = ord ∈ {NotAtomic,Unordered,Monotonic,
Acquire,Release}`. Each guard: volatile fail-loud (unchanged) THEN
`if ptr_cells; relaxable || _ir_error(...); else; ord==NotAtomic || _ir_error(...); end`.
Relaxed accesses fall through to the EXISTING cell IRLoad/IRStore branches
(ptr→width 64) and integer IRLoad/IRStore — no new lowering.

## Tests — test/test_ares_atomic_vm_relax.jl (RED-GREEN)
- (a) cells=true accepts unordered LOAD + release STORE (and monotonic/acquire)
      as IRLoad/IRStore (hand-built .ll; assert width + shape, not just no-throw).
- (b) cells=false same fixtures still fail loud, U14 text, NO VM suffix (byte-id).
- (c) acq_rel/seq_cst + volatile fail loud under BOTH gates; integer atomic under
      cells=false still walls.
- (d) real setindex! advances PAST U14 under cells=true (negative + inclusive
      disjunction of successors incl. fence/inline-asm/sret/genericmemory/void/
      closed-world); cells=false still walls (earlier ptr-return wall). Registry
      snapshot/restore (no _known_callees leak — Rule 7).
- test_4mmt + test_lf14 + test_gate_count_regression unchanged & green.
