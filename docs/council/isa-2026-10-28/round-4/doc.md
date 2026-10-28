# Bennett Virtual ISA — Specification, draft 0.4

**Date:** 2026-10-28. **Status:** fourth normative draft, for council
iteration (reports: `docs/council/isa-2026-10-28/round-{1,2,3}/`;
editor's responses in `round-*/response.md`). Founding text of
`bennett-isa-spec` (`Bennett-NorthStar.md` §4.4, §6.1); the north star
governs where this draft is silent. Nothing is implemented. MUST, MUST
NOT, SHOULD, MAY are normative; *(non-normative)* explains; *(deferred)*
names items left open and asserted non-semantic.

**Versioning.** ISA 0.4, object 0.4, launch 0.4, sched 0.4, cert 0.4,
coverage 0.4, target 0.4.

---

## 1. Scope and conformance

### 1.1 What the ISA is

A program model for classical, reversible and coherent computation with
one semantics, executed by the VM (`bennett-vm`) and the circuit
specialiser (`bennett-circuits`), produced by the plugin
(`bennett-plugin`) through the dialect's reference semantics, scheduled
through §11, described for hardware by target descriptions (§8). Nothing
here refers to LLVM.

### 1.2 Conformance classes

| Class | Who | Obligation |
|---|---|---|
| Executor | VM, specialiser, hardware stacks | §3–§7, §14 exactly; suites A–E, H |
| Producer | plugin, library compilers | well-formed objects (§9, §16) and regions (§5, §6); suite F |
| Scheduler | `bennett-sched` and competitors | §11; only schedules valid under §6; suite H |
| Checker | `bennett-conformance` | validates certificates (§12) without trusting producers |
| Target author | vendors | target descriptions (§8); suite E |

### 1.3 Deferred *(asserted non-semantic)*

Binary encodings (§16 text is the interchange form); mechanisation of
§14; device models beyond §7.3; the gate-name registry process; the
**memory layout** of the opaque C objects of §10–§11 (their constructors,
accessors and destructors are normative and listed).

## 2. Terminology

- **Tier.** CC, R, Q. **Wire**, **bundle** `wire[N]` (little-endian).
- **Location** `reg[N]`: a named mutable cell of an oracle or lproc
  register file. **Pseudo-location**: an oracle interface input, readable
  in lifted code, never written.
- **Region**: a Q function with a declared interface: **lifted oracle**
  (§5.2) or **quantum action** (§5.3); **permutation action** (§5.3).
- **lproc**: a lifted procedure with its own locations (§3.7).
- **Budget**: classical (B, heap_limit, stack_limit, depth_limit).
- **Frame**: per machine step, retained displaced values, flag, succ.
- **Basis configuration**: classical values on every component of a
  region's domain D (§5.2).
- **Gate classes.** Permutation: `x cx ccx mcx swap`. Diagonal: `s sdg t
  tdg cz rz`. Non-diagonal: `h rx ry`.
- **Control context** of an invocation: the multiset of control wires
  inherited transitively from every enclosing predicate stack and `ctl`;
  its size is the **inherited control count** (§6.4).

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call/uncall)       CC ──calls──▶ Q regions
  R  ──calls──▶ R functions, Q regions          Q  ──calls──▶ Q regions (§5.5); oracle bodies call lprocs
```

CC runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a
control or scheduling decision that depends on the value of a wire**
except through predication (§3.5). Gate angles are finite `f64` literals
or classical arguments fixed at region entry.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical environment | CC, R | dynamic SSA instances (§7.4), block parameters, activation stack |
| classical memory | CC, R | byte-addressed, little-endian, sparse; allocation table (§7.1) |
| effect tape, entropy tape | R | §7.3 |
| run history | CC, R | one frame per executed instruction (§7.4) |
| wire store | Q (CC via register ids) | live wires with roles `input target fault borrowed mutable workspace location cell` |
| quantum memory | Q | regions of `wire[W]` cells: local (§4.6) or interface (§5.1) |
| register file | Q | locations of the active oracle and its lproc closure (§3.7) |
| predicate stack | Q | wires; the active predicate is their conjunction |
| oracle step state | Q | `pc, pc' : wire[P]`; `faulted : wire`; `code : wire[F]`; counters (§3.7); B frames |
| budget | Q | classical: B, heap_limit, stack_limit, depth_limit |

### 3.3 Types, ownership, operand schema

```
  iN (1 ≤ N ≤ 128)   ptr (width ptr_width, an object header constant)   f64   token
  wire   wire[N]      linear values in structured code and interfaces
  reg[N]              a location (oracle bodies, lprocs); not linear
  region[A,W]         an interface quantum memory region (2^A cells of wire[W])
```

**Linear SSA with implicit versioning** (structured code and CC region
calls): a `wire`/`wire[N]` value is produced once and consumed once. Mode
`in` consumes and re-produces a successor of the **same name**;
`consume` consumes; `produce` creates. A name is not used after
`consume`. **Regions are threaded the same way**: a region name used by
an instruction or call is consumed and re-produced (its cells' versions
advance as §6.1 states). **Indexed operand** `w[i]` (literal i) borrows
wire i for one instruction. **Disjointness**: the wire operands of one
instruction are pairwise distinct; a region's interface bundles and
regions are pairwise disjoint; a location is never both read and written
by one assignment row except through the displaced slot.

**Per-opcode operand schema.** Every opcode has a fixed arity and operand
kinds; the canonical text (§16) writes results first (`w = op a b`), then
operands in the order of the form in §4; modes are fixed by the opcode
and never written. Width rules: `binop`/`icmp` operands have equal width;
`select` arms equal width; `zext`/`sext` to a strictly wider type,
`trunc` to a strictly narrower one; `load.iN`/`store.iN`/`lift.load.iN`/
`lift.store.iN` require N ∈ {8, 16, …, 128}; `measure` of `wire[n]` with
n ≤ 128 yields `in`, wider registers are measured in chunks of ≤ 128;
signed division truncates toward zero; literals are decimal integers,
finite floats, or labels.

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow and allocation.
Every executed instruction pushes a run-history frame (§7.4); `uncall`
pops frames in LIFO order (T4).

### 3.5 Predication

Every Q instruction with unitary semantics executes controlled on the
active predicate. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. Allocation, borrowing, release,
region creation and image gates are **unconditional**; only gates
(including those inside copy/XOR/exchange/memory instructions) are
controlled.

### 3.6 The predicated step machine

**Index space.** An oracle's instruction list `I[0..n)` is: the oracle's
blocks in text order, each contiguous; then the blocks of every lproc in
its **lproc closure** (every lproc reachable through `lift.call`,
including linked ones), lprocs ordered by closure hash (§9.2) with SCC
members in SCC index order, each lproc's blocks in text order. `HALT =
n`; 2^P > n. Branch and call targets are **labels**; executors assign
indices; `w = lift.label ^b` is the only way a location obtains an
index, so no producer writes raw indices and executors MAY re-index
extensionally. **Terminators**: `qjump qbranch qjumpr lift.ret lift.
retval fault`; every block ends in one; fallthrough is ill-formed; no
label names HALT; **only `lift.retval` reaches HALT with success**.

**Row classes.** Each §4.2 row is an **assignment** (its written
locations/cells receive values computed out of place into the frame's
`disp_j` slots, then exchanged in, so `disp_j` retains the displaced old
value) or a **direct** row (a controlled permutation executed in place,
no displaced value). Rows with a **flag** compute it into `frame.flag`
from the old state first, then perform their effects controlled on `flag`
or `¬flag`; conditional-fault rows additionally perform `faulted ^= flag`
and `code ^= flag · C` (direct). Rows with a data-dependent successor
compute it into `frame.succ`.

**Frame layout** (fixed per oracle): `(old_pc : wire[P], disp_1..disp_
{k_max}, flag : wire, succ : wire[P])`, `k_max` and the widths `W_j` from
the widest write sets used.

**Machine step** t (1 ≤ t ≤ B), reads referring to the state at the
start of the step:

1. **Dispatch.** `at_k = (pc == k)` for k = 0..n into clean scratch.
2. **Execute.** For each k < n: push `at_k`; run `I[k]`'s row: compute
   `flag` (if any) into `frame_t.flag`; compute `succ` (if data-
   dependent) into `frame_t.succ`; for assignment rows compute every
   written value into its `disp_j`, **all of them before any exchange**
   (so `lift.parmov` cycles are correct), then exchange each `disp_j`
   with its destination; for direct rows apply the permutation; apply
   the fault writes; pop `at_k`.
3. **Successor.** For each k < n, under `at_k`: XOR the row's successor
   into `pc'` (constant label index under `flag`/`¬flag` as the row
   states, or `frame_t.succ`). Under `at_HALT`: XOR `HALT` into `pc'`
   (**halted branches self-loop**).
4. **Commit pc.** `qexch pc pc'`; `qexch pc' frame_t.old_pc`.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

**Inverse of a step** (used by prefix reversal): recompute `at_k` from
`frame_t.old_pc`; undo step 4; for each row under `at_k`: undo the fault
writes and direct permutations (the same controlled operations, since
the retained `flag` still selects them), exchange every `disp_j` back,
then uncompute `flag` and `succ` from the restored old state; clean
`at_k`. The step is a permutation; executors implement it or an
extensionally identical transformation (§5.7, T6). B = 0 is legal.

### 3.7 Register files, procedures, counters, stack

An oracle declares `regs { name : reg[N], … }` and `result : reg[T]`;
each lproc declares `params`, `result`, `regs`. Interface inputs are
pseudo-locations readable by any read operand of lifted rows (never
written). All locations are clean at entry.

**Counters and sizes.** Region sizes are exponents: `mem` has 2^H byte
cells, `alloctab` 2^A_tab entries, the stack 2^S_cells cells. Counter
widths are **separate and wider**: `heap_used : wire[Hc]` with Hc ≥ H + 1,
`atop : wire[Ac]` with Ac ≥ A_tab + 1, `sp, fp : wire[Sc]` with Sc ≥
S_cells + 1, `depth : wire[Dc]` with Dc ≥ ⌈log₂(depth_limit+2)⌉; every
budget comparison is computed at counter width with no wrap; `bennett_
budget` (§10) rejects limits exceeding the region's capacities
(`heap_base + heap_limit ≤ 2^H`, `stack_limit ≤ 2^S_cells`, `depth_limit
< 2^Dc`).

**Activation records.** `lift.call @f (args) → w` pushes onto the stack
(cells of width `W_cell = max(P, Sc, Did, W_max)`) the record `(ret_index
: P, prev_fp : Sc, dest : Did, L_f[0], …, L_f[m−1])`, where `dest` is the
constant identifier of the destination location `w` (locations of the
oracle and its closure are numbered in index-space order; Did bits) and
`L_f` are **all** locations of `@f` in declaration order, each padded to
one cell, moved into the record by exchange (so `@f` starts clean, which
makes recursion correct). `R_f = 3 + m` cells. The stack is **monotonic**:
records are never popped; `sp` only grows; `fp` links records. Callee
instructions are charged to the caller's budget individually; `lift.call`
and `lift.ret` are one step each. Executors MAY inline extensionally.

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `r = const c` | |
| `add sub mul and or xor shl lshr ashr` | `r = op a b` | wrap; shift ≥ N → 0 |
| `udiv urem sdiv srem` | `r = op a b` | divisor 0, or signed MIN/−1: CC trap; R fault record (§7.4) |
| `icmp` | `r = icmp.{eq,ne,ult,ule,slt,sle} a b` | |
| `select` | `r = select p a b` | |
| `zext sext trunc ptrtoint inttoptr` | `r = op a` | |
| `load` | `r = load.iN addr` | N/8 consecutive bytes, little-endian, unaligned allowed; outside every live allocation: CC trap / R fault record |
| `store` | `store.iN addr v` | |
| `alloc` / `free` | `p = alloc n` ; `free p` | §7.1 |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | parallel block-parameter assignment |
| `call` / `uncall` / `ret` | `results = call @f args` ; `uncall` ; `ret vals` | §9.4 |
| `trap` | `trap` | CC trap; R fault record |
| `measure` | `r = measure w` | CC only; Born rule (§14.2); w consumed |
| `effect` | `results = effect dev.op args` | R only (§7.3) |
| `hostcall` | `rlen = hostcall service ptr len` | CC only (§10): raises HOST_REQUEST synchronously with the `len` bytes at `ptr` as payload; the host's reply (≤ `len` bytes) is written at `ptr`; `rlen` is its length; the run resumes after `bennett_reply`. In R or Q: ill-formed |

### 4.2 Lifted rows (oracle bodies and lprocs)

Columns: **Class** (A = assignment, D = direct), **Reads**, **Writes**
(assignment rows: displaced values in order `disp_1..`; direct rows: the
permutation), **Flag/fault**, **Succ**. Every row is one budget step;
`k` is the row's own index. Conditional-fault rows also perform `faulted
^= flag`, `code ^= flag·C` (direct) with C the named code.

| Row | Form | Class | Reads | Writes | Flag / fault | Succ |
|---|---|---|---|---|---|---|
| `lift.const` | `w = lift.const c` | A | – | w | – | k+1 |
| `lift.binop` | `w = lift.{add,…,ashr} a b` | A | a, b | w | – | k+1 |
| `lift.div` | `w = lift.{udiv,urem,sdiv,srem} a b` | A | a, b | w (under ¬flag) | flag = (b=0) ∨ (signed ∧ a=MIN ∧ b=−1); C = `FAULT_UB_DIV0` or `FAULT_UB_SDIV_OVERFLOW` | ¬flag: k+1; flag: HALT |
| `lift.icmp` | `w = lift.icmp.{pred} a b` | A | a, b | w:reg[1] | – | k+1 |
| `lift.select` | `w = lift.select p a b` | A | p, a, b | w | – | k+1 |
| `lift.cast` | `w = lift.{zext,sext,trunc} a` | A | a | w | – | k+1 |
| `lift.mov` | `w = lift.mov a` | A | a | w | – | k+1 |
| `lift.parmov` | `(w_1..w_m) = lift.parmov (a_1..a_m)` | A | a_i | w_1..w_m (all computed, then all exchanged) | – | k+1 |
| `lift.label` | `w = lift.label ^b` | A | – | w (the index of ^b) | – | k+1 |
| `lift.boundscheck` | `lift.boundscheck p n` | D | p, alloctab | – | flag = ¬∃ i < atop: live_i ∧ base_i ≤ p ∧ p + n ≤ base_i + size_i (no wrap); C = `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT |
| `lift.load` | `w = lift.load.iN a` | A | the N/8 byte cells at a..a+N/8−1 (§7.2 dispatch) | w | – | k+1 |
| `lift.store` | `lift.store.iN a v` | A | v | the N/8 byte cells at a.. (displaced: their old N bits) | – | k+1 |
| `lift.alloc` | `w = lift.alloc n` | A | n, heap_used, atop | under ¬flag: w ← heap_base + heap_used; heap_used ← heap_used + max(n,1); atop ← atop + 1; alloctab[atop] ← (base = heap_base + heap_used, size = n, live = 1, pinned = 0) (4 displaced) | flag = (heap_used + max(n,1) > heap_limit) ∨ (atop ≥ 2^A_tab); C = `FAULT_BUDGET_HEAP` | ¬flag: k+1; flag: HALT |
| `lift.free` | `lift.free p` | D | p, alloctab | match_i = (i < atop) ∧ (base_i = p) (computed from base only, into scratch); under ¬flag: live_i ^= match_i for all i; match_i uncomputed | flag = ¬∃ i: match_i ∧ live_i ∧ ¬pinned_i; C = `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT |
| `lift.faultif` | `lift.faultif p code` | D | p | – | flag = p; C = code | ¬flag: k+1; flag: HALT |
| `lift.call` | `w = lift.call @f (a_1..a_m)` | A+D | a_i, sp, fp, depth, L_f | under ¬flag: record cells ← (k+1, fp, id(w), L_f) by exchange (direct; the cells are clean); fp ← sp; sp ← sp + R_f; depth ← depth + 1 (3 displaced); params of @f ^= copies of a_i (direct) | flag = (depth + 1 > depth_limit) ∨ (sp + R_f > stack_limit); C = `FAULT_BUDGET_DEPTH` | ¬flag: entry label of @f; flag: HALT |
| `lift.ret` | `lift.ret v` | A+D | v, fp, record at fp, depth | under ¬flag: succ ← record.ret_index; exchange record's L_f cells ↔ @f's locations (direct); for every location ℓ of the closure: ℓ ^= record.v under (record.dest = id(ℓ)) (direct); fp ← record.prev_fp; depth ← depth − 1 (2 displaced) | flag = (depth = 0); C = `FAULT_UB_TRAP` | ¬flag: `succ`; flag: HALT |
| `lift.retval` | `lift.retval v` | D | v | result ^= v | – | HALT |
| `lift.oracle_call` | `lift.oracle_call @o tk (ins..) tgt fr (mem..) (args..)` | D | ins, tgt, fr, mem | tgt ^= payload; fr ^= code (callee contract); mem `in` regions unchanged | – | k+1 |
| `lift.oracle_uncall` | `lift.oracle_uncall @o tk (ins..) tgt fr (mem..) (args..)` | D | as above | the matched inverse (§5.5): identical permutation | – | k+1 |
| `lift.perm_call` | `lift.perm_call @a (mut..) (ins..) (mem..) (args..)` | D | ins, mut, mem | mut ← P(mut, ins, mem) in place | – | k+1 |
| `qjump` | `qjump ^b` | D | – | – | – | ^b |
| `qbranch` | `qbranch p ^b1 ^b2` | D | p | – | – | p: ^b1; ¬p: ^b2 |
| `qjumpr` | `qjumpr a` | D | a | succ ← a | flag = (a ≥ n); C = `FAULT_UB_TRAP` | ¬flag: `succ`; flag: HALT |
| `fault` | `fault C` | D | – | code ^= C; faulted ^= 1 | – | HALT |

Rules: `lift.retval` is ill-formed inside an lproc; `lift.ret` is ill-
formed in an oracle body outside lprocs (static), and faults at depth 0
(dynamic, when reached through `qjumpr`). `lift.oracle_call`/`uncall`
and `lift.perm_call` carry the complete callee interface: `mem` operands
name the caller's mapped interface regions (§7.2) and `args` are
classical literals or the oracle's classical arguments. `tk` is a
classical argument of the calling oracle, so a nested budget is part of
the caller's F_B.

**Reference body and binding.** Every oracle carries its **reference
body**: the stream the dialect's versioned mapping produced from the
materialised source (a fixed, versioned sequence of rows per source
instruction, `lift.boundscheck` before every access and `lift.parmov` on
every edge included), hashed into `interface_hash` (§9.2). **F_B and the
budget unit are defined solely by the reference interpreter (§14.1) on
the reference body**; the object holds only the reference body; every
executor optimisation is a transformation extensionally equal to it on D
(T6). The fault set depends only on (reference body with its envelope,
budget, dialect-mapping version).

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `w = qalloc cls n` | n clean wires of class `cls` or `any`; unconditional |
| `qborrow` | `w = qborrow cls n` | n wires in unknown state; usable only inside a borrow frame (§5.6) |
| `qfree` | `qfree w` | release a `qalloc`ed bundle clean on every basis configuration |
| `qreturn` | `qreturn w` | matched inverse of `qborrow` after its frame |

### 4.4 Gates

Matrices (computational basis, |0⟩ = (1,0)ᵀ, bundles little-endian):

```
  x = [[0,1],[1,0]]   h = (1/√2)[[1,1],[1,-1]]   s = diag(1,i)   sdg = diag(1,-i)
  t = diag(1,e^{iπ/4})  tdg = diag(1,e^{-iπ/4})   cz = diag(1,1,1,-1)
  rx(θ) = exp(-iθX/2)   ry(θ) = exp(-iθY/2)   rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff all controls are |1⟩ (exact, no phase)    swap: exact exchange
```

Forms: `x a`, `cx c t`, `ccx c1 c2 t`, `mcx (c_1..c_k) t`, `swap a b`,
`h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`, `ry θ a`, `rz θ
a`; operands `in`, pairwise distinct; all controlled on the active
predicate. **Realisation**: permutation status is a property of the
realised unitary at the gate boundary (an exact Clifford+T `ccx` is a
permutation gate); conformant iff equal to the specified unitary exactly
including global phase (ε = 0) or within declared ε in operator norm.
**Oracles and permutation actions require ε = 0** for every gate they
execute; actions MAY use ε > 0, accounted per §12. A relative-phase
Toffoli is never a conformant `ccx`.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `d = qcopy s` | d allocated clean (unconditional); `cx s[i] d[i]` under the predicate |
| `quncopy` | `quncopy s d` | `cx s[i] d[i]` under the predicate; `qfree d` |
| `qxor` | `qxor s t` | `cx s[i] t[i]` |
| `qexch` | `qexch a b` | `swap a[i] b[i]` |
| `qinplace` | `qinplace @g @ginv tk x` | `@g`, `@ginv` total permutation oracles on the n-bit encoding with certificates that under `tk` the fault code is `FAULT_NONE` on every input and `g∘ginv = ginv∘g = id`. Sem: `t = qalloc any n; f = qalloc any F; oracle_call @g tk (x) t f; qexch x t; oracle_call @ginv tk (x) t f; qfree t; qfree f` |

### 4.6 Quantum memory, predication, structure

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A W [image]` | function-local region of 2^A cells of `wire[W]`, created at function entry (unconditional allocation, X gates from the object's data image, default zero), MUST be back at its image before exit where the image gates are reversed and cells released clean; scope is the function; the adjoint reverses creation and release |
| `qload` | `d = qload name a` | d clean; for each cell i: under `a == i`, `qxor cell_i d` (comparators computed and uncomputed inside) |
| `qunload` | `qunload name a d` | inverse |
| `qstore` | `qstore name a v` | for each i: under `a == i`, `qxor v cell_i` |
| `qexchm` | `qexchm name a v` | for each i: under `a == i`, `qexch v cell_i` |
| `qpred`/`qunpred` | | §3.5 |
| `qif` | `qif w { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w` |
| `qloop` | `qloop n { body }` | body n times |
| `qloop … while` | `qloop n while cond { body }` | `cond : wire[n]` of permutation-provenance wires computed before the loop from wires the body does not modify; flags `c_1..c_n` allocated clean; `cx cond[0] c_1`; iteration i runs under `qpred c_i`; after iteration i < n, `ccx c_i cond[i] c_{i+1}`; flags uncomputed in reverse order and freed |

Interface regions (§5.1) are accessed by name with the same instructions.

### 4.7 Region calls (structured code and CC)

`oracle_call @o tk (ins..) tgt fr (mem..) (args..)`; `action_call @a
(mut..) (ins..) (mem..) (args..)`; `adj action_call …`; `adj oracle_call
…` ≡ `oracle_call …`; `ctl w <call>` ≡ the call under `qpred w` (for a
whole action, the controlled unitary of §5.3).

## 5. Regions

### 5.1 Interfaces and common well-formedness

Signatures list roles: `oracle @o (in a: wire[8]) (tgt t: wire[8]) (fault
f: wire[4]) (mem db: region[10,8] in) (args n: i64)`. **Interface
regions** are caller-owned, passed by name, role `in` (returned to their
entry contents on every basis configuration) or `mut` (actions only). A
region MUST NOT contain `measure effect br call uncall trap hostcall` or
classical memory instructions, nor lifted rows outside oracle bodies.
Predicate stack empty at entry and exit. Every `qalloc` matched by a
`qfree` of a clean bundle, every `qborrow` by a `qreturn` after its
frame, every local `qregion` restored, by **explicit cleanup instructions
in the text**; the schedule chooses only realisations. **`in` wires in
actions** appear only as controls, as targets of diagonal gates, as
`qcopy`/`qxor` sources, or as `in` arguments of calls (suite F). Action
call graphs are acyclic; recursion exists only through `lift.call`.

### 5.2 Lifted oracle

**Body**: lifted and control rows over its locations and lproc closure;
**exact-permutation only** (every gate executed by the body, lprocs,
`lift.perm_call` targets and nested oracles has ε = 0).

**Contract** on every x ∈ D: `ins` unchanged; `tgt` final = initial ⊕
payload(F_B(x)); `fr` final = initial ⊕ code(F_B(x)); `in` regions
unchanged; borrowed bundles returned (§5.6); workspace, locations, local
regions, step state clean / at image. **F_B(x)** = `(f(x), 0)` if the
reference interpreter reaches `lift.retval` within B steps without a
fault, else `(0, code)` with `code` the first fault in sequential order,
or `FAULT_BUDGET_STEPS` if not halted after B steps. The oracle is an
**involution** on `(ins, tgt, fr)` and its own adjoint.

**Construction** (normative; executors are extensionally fixed to it):
(1) allocate step state, locations, local regions (image gates),
`alloctab` with its pre-entries (§7.2), B frames; (2) run B steps; (3)
**commit**: `at_HALT = (pc == HALT)`; under `at_HALT ∧ ¬faulted`: `qxor
result tgt`; under `faulted`: `qxor code fr`; under `¬at_HALT`: XOR the
constant `FAULT_BUDGET_STEPS` into `fr`; uncompute `at_HALT`; (4)
**prefix reversal**: invert (2) then (1); the commit writes persist.

**Domain D**: every value of each `ins`, of `tgt`, of `fr`, of every cell
of every `in` region, of every borrowed bundle; `qalloc`ed wires at 0;
local regions at image.

### 5.3 Quantum action

**Semantics.** The body denotes a unitary U on mut ⊗ ins ⊗ mem_mut ⊗
(borrowed), block-diagonal in the computational basis of `ins` and of
`in`-region cells, identity on borrowed and external reference systems
(§5.6), workspace returned clean. No fault outcome of its own. An action
with coherent internal control is its padded unitary under its declared
bounds, which are part of its identity. **Permutation action**: realised
unitary a permutation matrix (ε = 0, permutation gates only,
transitively); the only kind of action an oracle may call.

**Body**: gates; `qcopy quncopy qxor qexch qinplace`; `qload qunload
qstore qexchm`; `qpred qunpred qif qloop`; `oracle_call action_call`;
`qalloc qborrow qfree qreturn`; `qregion`.

**Adjoint table** (reverse order, each instruction replaced, versions
renumbered; well-formed by construction):

```
  rx/ry/rz(θ) ↦ (−θ)   s ↔ sdg   t ↔ tdg   x cx ccx mcx swap h cz: self-adjoint
  qalloc ↔ qfree   qborrow ↔ qreturn   qregion creation ↔ release   qcopy ↔ quncopy   qload ↔ qunload
  qxor qexch qstore qexchm: self-adjoint   qinplace @g @ginv ↦ qinplace @ginv @g   oracle_call ↦ oracle_call
  action_call @b ↦ adj action_call @b   qpred/qunpred pairs reversed as a whole
  qif w {A}{B} ↦ qif w {adj A}{adj B}   qloop n {A} ↦ qloop n {adj A}
  qloop n while cond {A} ↦ flags computed forward as §4.6; adj A for i = n..1 under c_i; flags uncomputed
```

**Control.** `ctl w @a` is controlled-U: workspace, regions and flags
allocated unconditionally; every gate of the body and of its cleanup
runs under `w` in addition to the active predicate.

### 5.4 Budgets and fault codes

Budget = (B, heap_limit, stack_limit, depth_limit), classical, validated
at `bennett_budget` against the region's capacities (§3.7). B is
enforced by running exactly B steps; heap, stack and depth are wire
counters compared at full width. Fault precedence within a row is the
row's flag definition.

```
  0 FAULT_NONE            4 FAULT_UB_TRAP            8 FAULT_EFFECT_UNMODELLED
  1 FAULT_BUDGET_STEPS    5 FAULT_UB_DIV0            9 FAULT_CALLEE
  2 FAULT_BUDGET_HEAP     6 FAULT_UB_SDIV_OVERFLOW  10 FAULT_ENTROPY_EXHAUSTED (R only)
  3 FAULT_BUDGET_DEPTH    7 FAULT_UB_MEMFAULT
```

F ≥ 4. R-tier fault records carry these same codes (§7.4).

### 5.5 Nesting and matched cleanup

A `lift.oracle_call` supplies a caller location `fr'`, clean when
computing a fresh outcome. **No automatic propagation**: the dialect
emits `p = lift.icmp.ne fr' 0; lift.faultif p FAULT_CALLEE` where the
source requires it. To clear `fr'`, the producer emits `lift.oracle_
uncall @o` with the **same token, same callee, the same `ins` and `mem`
values** (unchanged since the call: suite F checks that no row between
the two wrote those locations or cells) **and the successor versions of
`tgt` and `fr'`** produced by the call; the two rows share a dynamic
invocation identity (the pair is matched statically). Alternatively
`fr'` is retained until the prefix reversal.

### 5.6 Borrowed systems and borrow frames

**Requirement.** A region's completed operation equals its declared
operation ⊗ identity on every borrowed bundle and on any external system
entangled with it. Basis restoration alone is insufficient (`cx b a; s a;
cx b a` applies `s` to borrowed b).

**Rule (suite F).** Borrowed wires are **touched** (as control or target)
only inside **borrow frames**: maximal contiguous permutation-only
subcircuits from the first to the last instruction touching the frame's
borrowed wires. The frame's realised permutation P_F on its wires (the
borrowed wires and every wire any frame instruction touches) MUST factor
as `P_F = P' ⊗ I_borrowed`. This is established either by a T3 claim over
the frame's full domain (exhaustive, or a library certificate, §12
`borrow_frames`), or **structurally by the toggling lemma**: the frame
has the form `V; W; V⁻¹; W` where (i) V consists of permutation gates
that XOR into borrowed wires only functions of a wire set X, and W
writes no wire of X; (ii) W's targets lie outside X, outside the borrowed
set, and outside W's own controls; (iii) every gate of W has at most one
borrowed control, so W's effect is affine in the borrowed values; (iv)
V⁻¹ is the exact inverse sequence of V. Then the net effect is
independent of the borrowed values and restores them (the dirty-ancilla
MCX pattern of Gidney and Häner–Roetteler–Svore). The earlier `V; W; V⁻¹`
rule is withdrawn (`cx b y; cx y z; cx b y` leaves z ⊕= y ⊕ b). Oracles
are one frame verified by their own T3 claim over D.

### 5.7 Executor transformations

Inlining, structure recovery, re-indexing of labels and any
simplification MUST produce on every x ∈ D the same final interface tuple
as §5.2's construction on the reference body (T6).

## 6. Uncomputation validity (static discipline)

### 6.1 Provenance, dependency sets, transfer

Every workspace bundle version, location version and cell version has
provenance `perm` (computed by permutation gates from its **dependency
set** S of versions) or `other`. Cell versions `(region, i, v)` advance on
every write to the cell. Π denotes the active predicate stack plus the
inherited control context. Transfer rules (suite F):

| Instruction | Effect |
|---|---|
| `qalloc` | perm, S = ∅ |
| `d = qcopy s` | d: perm, S = {s} ∪ Π |
| `d = qload r a` | d: perm, S = {a} ∪ cells(r) ∪ Π |
| `qxor s t` | t: perm with S_t ∪ S_s ∪ Π if both perm, else other |
| `qexch a b` (predicated) | each output: perm with S_a ∪ S_b ∪ Π if both perm, else other (the output is selected by the predicate) |
| `qstore r a v` | cell versions of r advance: each cell (r,i): perm with S_cell ∪ S_v ∪ {a} ∪ Π if both perm, else other |
| `qexchm r a v` | v and every cell: perm with S_v ∪ ⋃S_cells ∪ {a} ∪ Π if all perm, else other; cell versions advance |
| permutation gate, controls C, target t | t: perm with S_t ∪ C ∪ ⋃S_c ∪ Π iff t was perm, else other |
| diagonal gate on u | unchanged |
| non-diagonal gate on u | u: other; closes the window of every value whose S contains u |
| `oracle_call @o (ins) tgt fr (mem)` | tgt, fr: perm with S = ins ∪ {tgt, fr} ∪ cells(every `in`/`mut` region passed) ∪ Π; `in` regions unchanged |
| `lift.perm_call` / permutation `action_call` | each mut: perm with S = mut ∪ ins ∪ cells(regions passed) ∪ Π; `mut` region cells advance with the same S |
| non-permutation `action_call` | every mut and every `mut`-region cell: other |
| `qinplace @g @ginv x` | x: perm with S_x ∪ Π |
| lifted rows | each written location/cell: perm with the union of its read operands' sets ∪ Π; written cells' versions advance |

### 6.2 Window and obligations

A perm value g with set S is **in its window** from its computation until
the first of: a non-diagonal gate on a wire in S or in g; a version
advance of a cell in S; a non-permutation action call touching a wire in
S; a permutation change to a wire in S not undone before g's cleanup.
Each cleanup is **bound to the exact computing sequence** (`quncopy` to
its `qcopy`, `qunload` to its `qload`, an adjoint sequence to its
sequence, `lift.oracle_uncall` to its call) and requires the versions
that sequence read to be current. Every perm value MUST be cleaned
within its window and before its region exits; a region in which some
value cannot be is **ill-formed** (closed-window measurement-based
cleanup is not admitted in this draft). `other` values are released only
by the adjoint of the sequence that produced them.

### 6.3 T5 restated

Cleaning g within its window returns g's wires to |0⟩ and factorises
them from the remaining state; diagonal uses of g or of its dependencies
have applied the corresponding diagonal phases to the remainder, which
is part of the program's declared semantics.

### 6.4 Control context and measurement-based realisation

The inherited control count of an invocation is the number of wires in
its control context. A **measurement-based realisation** of an in-window
cleanup is legal only in a schedule whose bindings state an inherited
control count of 0 and whose target declares `mbu: true`; the fixup is
computed for the actual schedule and verified by suite D (channel
claim). Schedules and certificate cleanup entries are keyed by `(region
hash, variant, inherited control count)`; a region reachable under a
non-empty control context MUST have a unitary-cleanup schedule for that
key.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse. The address space is partitioned
by the object's `layout`: a **null region** `[0, null_size)` never
allocated (null_size ≥ 1); globals at fixed bases with images; the heap
`[heap_base, heap_base + heap_limit)` above the globals. `p = alloc n`
returns the bump pointer, records `(base, size = n, live = 1, pinned =
0)` and advances the pointer by `max(n, 1)`, so bases are pairwise
distinct and zero-size allocations have no accessible byte. Globals have
pre-entered pinned live entries. An access is valid iff its whole byte
range lies in one live entry. `free p` marks the unique entry with base
p dead; pinned entries cannot be freed; storage is never reclaimed.

### 7.2 Lifted memory of an oracle

`mem` is one byte region of 2^H cells (H ≤ ptr_width); `alloctab` has
2^A_tab entries `(base, size, live, pinned)`; the stack has 2^S_cells
cells. The `layout` fixes `null_size`, each global's base and image,
`heap_base` (equal to the comparison link's shim heap base), and for
each **interface region** of the oracle (W = 8 required) a base address
in the lifted address space, all ranges disjoint and within `[0, 2^H)`.
At oracle entry `alloctab` is initialised with one **pinned live** entry
per global and per mapped interface region (counted against 2^A_tab).
`lift.load`/`lift.store` dispatch by address range to `mem` or to the
mapped interface region (which preserves roles: `in` regions are
unchanged at exit by the construction). A ptr holds `ptr_width` bits; the
address circuits use the low H bits and `lift.boundscheck` guarantees
the range lies in a live entry, hence within `[0, 2^H)`.

### 7.3 Device models and tapes (R)

Device operations take classical-memory arguments `(ptr, len)` with the
same bounds rules as `load`/`store`; results are written to memory.

| Device | State (initial) | Operations | Failure | Reversal |
|---|---|---|---|---|
| `console` | byte sequence (empty) | `write(ptr, len)` | – | pop `len` bytes |
| `clock` | `c: u64` (0) | `read() → u64`: returns c, then c += 1 | – | c −= 1 |
| `entropy` | position `p` (0) into the **entropy tape** supplied at launch (§10) | `read(ptr, len)`: copies tape[p..p+len) to ptr; p += len | p + len > length: R fault `FAULT_ENTROPY_EXHAUSTED` | p −= len |
| `block` | sector map (from the object's `block` data image, else empty); 512-byte sectors; missing sectors read as zero | `read(sector, ptr)`; `write(sector, ptr)` (history records the overwritten sector) | – | restore the sector |

Each `effect` appends `(dev, op, args, results)` to the effect tape;
reversal pops and applies the inverse delta. Reversal restores device
state; it cannot retract an observation of the console.

### 7.4 Run history (CC and R) and the dynamic SSA model

The classical environment holds **dynamic instances**: every executed
defining instruction creates a new instance retained in the run history
until reversal; a name denotes its most recent instance. Each executed
instruction pushes one frame:

| Instruction | Frame |
|---|---|
| any defining instruction | its defined instance |
| `br` | predecessor block, prior block-parameter instances |
| `store` | address, width, overwritten bytes |
| `alloc` / `free` | the table entry written / its old live bit |
| `call` | invocation boundary (callee, args) |
| `ret` | the callee's entire activation and the frame link |
| `effect` | tape index |
| `hostcall` (CC) | payload bytes and the reply bytes |
| `oracle_call` / `action_call` | (region hash, variant, inherited control count, classical args, register ids) — reversed by re-application / adjoint, **exactly once, by this frame** |
| fault record | cause (§5.4 code), location; terminal faulted state, reversed like any prefix |

`uncall` reverses the most recent unreversed `call` whose frames are the
top of the history (LIFO). T4 is stated over these frames.

## 8. Target descriptions (target 0.4)

### 8.1 Format and expressions

A target is a **JSON document in RFC 8785 canonical form**; `target_hash`
= SHA-256 of those bytes. Numbers are parsed as **exact rationals** from
their decimal text. Cost expressions are a closed **JSON AST**:

```
  expr := number | {"var": "k" | "eps" | "a" | "w" | "c"} | {"op": "+"|"-"|"*"|"/"|"max"|"min"|"ceil"|"log2inv_eps", "args": [expr, ...]}
        | {"table": "<name>", "index": "k" | "eps_decade"}
```

Variables: `k` the gate's own control/parameter count, `eps` the
assigned synthesis ε, `a` the address width and `w` the cell width of a
memory operation, `c` the total control count (own controls + predicate
depth + inherited). `log2inv_eps` at eps = 0 is a load-time error unless
the entry's `epsilon` is 0. Division by zero is a load-time error. Tables
are declared under `"tables"` as arrays indexed by exact k or by ε decade
(⌊log₁₀(1/ε)⌋). Costs MUST be nonnegative and finite.

### 8.2 Resources, aggregation, timing

```
  "resources": { "<name>": { "kind": "count"|"time"|"occupancy"|"peak", "unit": "<string>" } }
```

Mandatory: `qubit_second` (occupancy, per class), `time`, `peak_qubits`
(peak, per class). `count` sums; `time` is the schedule makespan;
`occupancy` integrates live qubits per class over scheduled time; `peak`
takes the maximum. Classical instructions and effects take the declared
`"classical_step_time"` each. **Timing model**: sequential in program
order unless the schedule assigns start times; a gate occupies its wires
for its `time`; gates on disjoint wires MAY overlap unless `max_parallel`
or a topology is declared; all-to-all over logical wires. A wire's
interval runs from `qalloc`/`qborrow` to `qfree`/`qreturn`; interface
wires are charged to the caller for the call's duration; borrowed wires
are charged to the borrower at `dirty_rate`, replacing the owner's charge.

### 8.3 Classes, gates, schemes, capabilities

```
  "ptr_widths_supported": [32, 64],
  "classes": { "<cls>": { "qubit_second": n, "dirty_rate": n, "capacity": n | "unbounded" } },
  "gates": [ { "op": "<gate>", "classes": ["<cls>"|"*", ...], "controls": {"min": n, "max": n | "unbounded"},
               "params": ["theta"]?, "epsilon": expr, "cost": { "<resource>": expr, "time": expr } }, ... ],
  "schemes": { "<name>": { "params": ["k"], "template": [ { "gate": "<op>", "wires": ["c0", "t"], "repeat": {"var": "i", "from": expr, "to": expr}? }, ... ],
                           "epsilon": expr, "cost": { ... } } },
  "qram": null | { "load": { "cost": {...} }, "store": { "cost": {...} }, "exch": { "cost": {...} } },
  "capabilities": { "measurement": {"mid_circuit": bool, "feedforward_latency": n}, "mbu": bool,
                    "max_parallel": n | "unbounded", "max_predicate_depth": n | "unbounded", "classical_step_time": n },
  "objective": { "weighted": { "<resource>": n } } | { "lexicographic": [ "<resource>", ... ] },
  "tables": { "<name>": [ n, ... ] },
  "imports": { "<model>": { "version": "...", "map": { "<quantity>": ["<resource>", factor] } } }
```

**Matching.** An executed gate with opcode o, operand classes, total
control count c and parameters matches the **first** `gates` entry in
array order whose `op`, class pattern (`*` matches any) and `controls`
range cover it; otherwise the first `schemes` entry whose template
(expanded with its parameters) realises it; otherwise load-time error.
`controls.min/max` are inclusive bounds on the total control count. A
scheme's `template` is a parametric gate sequence over symbolic wire
names with `repeat` ranges; a schedule MAY reference only schemes
declared in the target.

### 8.4 Space budget

The scheduler's capacity constraint is peak live qubits per class,
separate from `qubit_second`.

## 9. Objects, identity, linking, reversible ABI (object 0.4)

### 9.1 Sections and schemas

Order is fixed: `symbols imports functions data devices layout schedule
certificate coverage`; each at most once; unknown sections are errors;
unknown fields in metadata objects are errors. Metadata sections are one
JCS line each, an **object** with these fields:

```
  symbols:  { "<local index>": { "name", "kind": "cc"|"r"|"oracle"|"action"|"perm_action"|"lproc"|"data",
                                 "signature": <sig>, "interface_hash" } }
  imports:  { "<name>": { "signature": <sig>, "pinned_closure_hash"?: hex } }
  devices:  { "<dev>": { "version": "0.4" } }      services: inside devices as { "services": { "<reverse-dns id>": { "version" } } }
  layout:   { "ptr_width", "H", "A_tab", "S_cells", "null_size", "heap_base", "heap_limit_max",
              "globals": { "<name>": { "base", "size", "image": "<data name>" } },
              "interface_regions": { "<oracle>": { "<region>": { "base" } } }, "block_image"?: "<data name>" }
  schedule: §11      certificate: §12      coverage: { "entries": [ §13 ] }
  <sig> = { "tier", "kind", "in": [widths], "tgt": w, "fault": F, "mut": [widths], "mem": [ { "A", "W", "role" } ],
            "args": [types], "bounds"?: [...], "abi": "0.4" }
```

Integers that may exceed 2^53 are encoded as **decimal strings** in
JSON. `data` lines are `NAME SP HEX`.

### 9.2 Identity

**Canonical function bytes**: the function's text from its header line
through its last instruction line, lines joined by LF, **no trailing
LF**. **Semantic envelope** of a symbol = the concatenation, each part
followed by LF: (1) `"isa=" MAJOR`; (2) `"ptr_width=" INT`; (3) its JCS
signature; (4) its canonical function bytes; (5) for every `data` entry
and every `layout` sub-entry it reaches (its local regions' images, the
globals and interface-region mappings it addresses, the oracle's H,
A_tab, S_cells, null_size, heap_base), sorted by name, the JCS line of
that entry (data: `NAME SP HEX`); (6) for every referenced symbol, in
order of first reference, its hash (64 lowercase hex) — the **interface
hash** uses interface hashes of defined symbols and `SHA-256(name ‖ 0x00
‖ JCS signature)` for unresolved imports; the **closure hash** uses
closure hashes. In parts (4)–(5) every `@name` reference token is
replaced in place by `@` followed by the referenced symbol's 64-hex hash.
**SCCs**: members ordered by name; intra-SCC references replaced by
`@$<decimal index>`; `scc_hash` = SHA-256 over the concatenated member
envelopes in that order; member identity = SHA-256(`scc_hash` hex ‖ `:` ‖
decimal index). **object_hash** = SHA-256 of the canonical object text
with the `schedule`, `certificate` and `coverage` sections deleted
together with the blank line preceding each. `reference_program_hash` of
an oracle = its interface hash. `params_hash` = SHA-256 of the JCS array
of classical parameter values; `schedule_hash` = SHA-256 of the
schedule's JCS bytes. **Program-point id** = `(symbol interface hash,
block name, instruction ordinal within the block counting nested
instruction lines in text order)`.

### 9.3 Linking

Imports resolve by name + signature (mismatch: link error; pinned hash:
equality required); resolved closure hashes are recorded in the linked
certificate. Equal-closure-hash duplicates deduplicate; unequal under one
name, or conflicting `devices`/`layout`/`data` entries: link error.
Linking = resolution, validation, certificate composition (§12.3),
rebinding to closure hashes.

### 9.4 Reversible ABI

- CC/R calls: classical frame; callee frames follow the call boundary on
  the run history; `uncall` reverses LIFO (§7.4).
- Region calls: interface bundles and regions passed in declared order,
  caller-owned; callee owns its workspace, returns it clean, local regions
  at image, borrowed bundles returned.
- **Frame descriptor** (certificate): interface slots (role, width,
  class), scratch by class and cleanliness, retained history (oracles: B ×
  frame width), borrow requirement, **parameterised by inherited control
  count** (scratch for controlled variants is stated as a function of c or
  as a declared bound with its proof). Shared frames only with disjoint
  live ranges (suite F); callees `qborrow` only from the caller's
  designated idle set.

## 10. Launch ABI (launch 0.4)

**Model.** A run executes a device CC entry. The host passes classical
arguments, budgets, register ids and the entropy tape; receives classical
results, fault codes and declared measurements; host services are
reached by `hostcall` (§4.1) with reverse-DNS service ids declared in the
object's `devices.services`. Host code never holds a wire.

**Invocation tree.** A run record is a tree whose leaves are CC
segments, R calls and Q calls; an R call's subtree is owned by its R
history (§7.4), so a Q call inside an R call is reversed exactly once, by
that history. `bennett_reverse` reverses the tree post-order: CC segments
by their run history (stores, allocs, register operations, `hostcall`
replies), R calls by `uncall`, top-level Q calls by re-application /
adjoint with recorded arguments and register ids.

**States.** `CREATED → RUNNING → (SUSPENDED ⇄ RUNNING) → (HOST_REQUEST ⇄
RUNNING) → COMPLETED | FAILED`; `COMPLETED → REVERSED`; any of
`COMPLETED/FAILED/REVERSED → CLOSED`. A run owns the registers and
memory it touches exclusively while not CLOSED. **Reverse eligibility**:
`COMPLETED` only; no `measure` executed; no register it touched has been
prepared, freed or used by another run since (preparing a touched
register invalidates reversal); otherwise `E_NOT_REVERSIBLE`.
Measurement consumes its wires; the register id is invalidated.

```c
/* launch 0.4 — all objects opaque; every *_new/_get returning an object transfers ownership to the caller,
   released with the matching *_free. Status: 0 = BENNETT_OK, else one of the enum values below. */
typedef enum { BENNETT_OK=0, BENNETT_E_VERSION, BENNETT_E_PTR_WIDTH, BENNETT_E_DEVICE_MISSING, BENNETT_E_GATE_UNSUPPORTED,
  BENNETT_E_TARGET, BENNETT_E_BUDGET, BENNETT_E_QREG_NOT_CLEAN, BENNETT_E_INVALID_STATE, BENNETT_E_NOT_REVERSIBLE,
  BENNETT_E_SCHEDULE_INFEASIBLE, BENNETT_E_ARG, BENNETT_E_NOMEM } bennett_status;
typedef struct bennett_program_t bennett_program_t;   typedef struct bennett_args_t bennett_args_t;
typedef struct bennett_result_t bennett_result_t;     typedef struct bennett_request_t bennett_request_t;
typedef struct bennett_estimate_t bennett_estimate_t; typedef struct bennett_coverage_t bennett_coverage_t;
typedef struct bennett_tape_iter_t bennett_tape_iter_t;
typedef uint64_t bennett_qreg; typedef uint64_t bennett_token; typedef uint64_t bennett_run_id;
typedef enum { BENNETT_ARG_INT, BENNETT_ARG_F64, BENNETT_ARG_QREG, BENNETT_ARG_TOKEN } bennett_arg_kind;

bennett_status bennett_load(const uint8_t* object, size_t len, const uint8_t* target_jcs, size_t tlen, bennett_program_t** out);
void           bennett_unload(bennett_program_t*);
bennett_status bennett_budget(bennett_program_t*, const char* region, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth, bennett_token* out);
bennett_status bennett_qreg_new(bennett_program_t*, const char* cls, uint32_t n, bennett_qreg* out);
bennett_status bennett_qreg_prepare(bennett_program_t*, bennett_qreg, const uint8_t* bits, size_t nbits);
bennett_status bennett_qreg_free(bennett_program_t*, bennett_qreg);
bennett_status bennett_args_new(size_t n, bennett_args_t** out);
bennett_status bennett_args_set_int(bennett_args_t*, size_t i, uint32_t width, const uint8_t* le_bytes);
bennett_status bennett_args_set_f64(bennett_args_t*, size_t i, double);
bennett_status bennett_args_set_qreg(bennett_args_t*, size_t i, bennett_qreg);
bennett_status bennett_args_set_token(bennett_args_t*, size_t i, bennett_token);
void           bennett_args_free(bennett_args_t*);
bennett_status bennett_run(bennett_program_t*, const char* cc_entry, const bennett_args_t*, const uint8_t* entropy, size_t entropy_len, bennett_run_id* out);
bennett_status bennett_wait(bennett_program_t*, bennett_run_id, bennett_result_t** result_out, bennett_request_t** request_out); /* COMPLETED, FAILED or HOST_REQUEST */
bennett_status bennett_reply(bennett_program_t*, bennett_run_id, const uint8_t* payload, size_t len);
bennett_status bennett_suspend(bennett_program_t*, bennett_run_id);   /* takes effect at the next CC boundary outside any region */
bennett_status bennett_resume(bennett_program_t*, bennett_run_id);
bennett_status bennett_reverse(bennett_program_t*, bennett_run_id);
bennett_status bennett_run_close(bennett_program_t*, bennett_run_id);
size_t         bennett_result_nvalues(const bennett_result_t*);
bennett_status bennett_result_get(const bennett_result_t*, size_t i, bennett_arg_kind* kind, uint32_t* width, uint8_t* le_bytes_out, size_t cap);
size_t         bennett_result_nfaults(const bennett_result_t*);   uint64_t bennett_result_fault(const bennett_result_t*, size_t i);
size_t         bennett_result_nmeasurements(const bennett_result_t*);
bennett_status bennett_result_measurement(const bennett_result_t*, size_t i, bennett_qreg* reg, uint8_t* bits_out, size_t cap, size_t* nbits);
uint64_t       bennett_result_tape_length(const bennett_result_t*);   void bennett_result_free(bennett_result_t*);
const char*    bennett_request_service(const bennett_request_t*);
const uint8_t* bennett_request_payload(const bennett_request_t*, size_t* len);   void bennett_request_free(bennett_request_t*);
bennett_status bennett_tape_open(bennett_program_t*, bennett_run_id, bennett_tape_iter_t** out);
bennett_status bennett_tape_next(bennett_tape_iter_t*, const char** dev, const char** op, const uint8_t** args, size_t* alen, const uint8_t** results, size_t* rlen); /* E_INVALID_STATE at end */
void           bennett_tape_free(bennett_tape_iter_t*);
bennett_status bennett_estimate_run(bennett_program_t*, const char* region, bennett_token, bennett_estimate_t** out);
size_t         bennett_estimate_nresources(const bennett_estimate_t*);
bennett_status bennett_estimate_get(const bennett_estimate_t*, size_t i, const char** name, const char** value_decimal);
const uint8_t* bennett_estimate_certificate(const bennett_estimate_t*, size_t* len);   void bennett_estimate_free(bennett_estimate_t*);
bennett_status bennett_coverage_get(bennett_program_t*, bennett_coverage_t** out);
const uint8_t* bennett_coverage_jcs(const bennett_coverage_t*, size_t* len);   void bennett_coverage_free(bennett_coverage_t*);
```

## 11. Scheduling interface (sched 0.4)

```c
bennett_status bennett_sched_request_new(bennett_sched_request_t** out);
bennett_status bennett_sched_request_set_object(bennett_sched_request_t*, const uint8_t*, size_t);
bennett_status bennett_sched_request_set_target(bennett_sched_request_t*, const uint8_t* jcs, size_t);
bennett_status bennett_sched_request_set_region(bennett_sched_request_t*, const char* interface_hash_hex, const char* variant, uint32_t inherited_controls);
bennett_status bennett_sched_request_set_budget(bennett_sched_request_t*, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth);
bennett_status bennett_sched_request_set_params(bennett_sched_request_t*, const uint8_t* params_jcs, size_t);
bennett_status bennett_sched_request_set_accuracy(bennett_sched_request_t*, const char* epsilon_decimal);
bennett_status bennett_sched_request_set_capacity(bennett_sched_request_t*, const char* cls, uint64_t peak_qubits);
void           bennett_sched_request_free(bennett_sched_request_t*);
bennett_status bennett_sched_schedule(const bennett_sched_request_t*, bennett_sched_response_t** out);
typedef enum { BENNETT_SCHED_OK, BENNETT_SCHED_INFEASIBLE, BENNETT_SCHED_UNSUPPORTED } bennett_sched_outcome;
bennett_sched_outcome bennett_sched_response_outcome(const bennett_sched_response_t*);
const char*    bennett_sched_response_reason(const bennett_sched_response_t*);
const uint8_t* bennett_sched_response_schedule(const bennett_sched_response_t*, size_t* len);     /* JCS */
const uint8_t* bennett_sched_response_certificate(const bennett_sched_response_t*, size_t* len);  /* JCS */
void           bennett_sched_response_free(bennett_sched_response_t*);
```

**Schedule document** (JCS; the object's `schedule` section):

```
  { "bindings": { "closure_hash", "target_hash", "region", "variant", "inherited_controls", "budget": [B,heap,stack,depth],
                  "params_hash", "epsilon", "scheduler": { "name", "version" } },
    "entries": [ { "path": [ { "symbol": hex, "point": "<block>:<ordinal>" }, ... ],   /* invocation path from the region's entry */
                   "iteration": n | "*", "phase": "fwd" | "rev" | "*",
                   "generated": "dispatch" | "history" | "gate" | "cleanup" | "comparator" | "*",
                   "kind": "cleanup" | "gate" | "alloc" | "start",
                   /* kind-specific, required: */
                   "cleanup": { "realisation": "reverse" | "recompute" | "mbu" },
                   "gate":    { "realisation": "native" | "<scheme name>", "epsilon_share": decimal },
                   "alloc":   { "class": "<cls>" },
                   "start":   { "time": decimal } } ] }
```

Entries are hierarchical: an entry applies to every generated operation
matching its `path`, `iteration`, `phase` and `generated` selectors;
more specific entries override less specific ones; a schedule MUST cover
every cleanup and every ε > 0 gate of the region under its bindings
(defaults: `reverse`, `native`, `any`, sequential). **Obligations**:
satisfy §6; respect capacity; report every declared resource; be
reproducible from the request plus scheduler version. A consumer
validates every binding (closure hash, target, variant, inherited
controls, budget, params, ε) and every path against the object, then
executes the schedule **verbatim** or rejects it and requests a
replacement; it never alters program semantics. The VM uses this
interface at run time.

## 12. Certificate (cert 0.4; JCS)

### 12.1 Claims

| kind | payload | checker obligation |
|---|---|---|
| `exhaustive` | `domain` (§12.2); `expected`: `"oracle"` \| `{ "table": [outputs in domain enumeration order] }` \| `{ "program": interface_hash }` | re-execute every domain element on the reference interpreter / the expected program and compare full tuples |
| `sampled` | `domain`; `sampler`: `{ "algorithm": "xoshiro256**", "seed": [4 × u64 as decimal strings], "count": n }`; each 64-bit output is consumed in domain-component order (bundles, then borrowed, then region cells, each in declared order, cells by index), mapped to `[lo, hi]` by rejection sampling on `output mod 2^⌈log₂(hi−lo+1)⌉` | replay; **evidence** |
| `structural` | `{ "rule": "toggling_lemma" \| "inverse_pair_library" \| "adjoint_table", "subclaims": [claim indices within this entry], "witness": { rule-specific fields: for `toggling_lemma`: the wire sets V, W, X and the frame's point range } }` | check the rule's side conditions syntactically against the object and the subclaims' results |
| `numerical` | `{ "widths", "metric": "operator_norm" \| "diamond", "bound": decimal, "method": "interval_arithmetic", "precision_bits": n, "witness": { "intervals": [...] } }` | recompute the stated intervals at the stated precision; a claim without a witness is **evidence** |

### 12.2 Domains

`"domain": { "bundles": [ { "name", "width", "lo": decimal, "hi": decimal } ], "borrowed": [ same ], "regions": [ { "name", "cells": "all" | [ { "index", "lo", "hi" } ] } ] }`,
all bounds inclusive; enumeration order is the listed order, last
component fastest. The checker verifies the domain equals D (§5.2) for a
`proof` label, else the claim is labelled `evidence` with the fraction
covered.

### 12.3 Schema and composition

```
  versions; bindings { object_hash, interface_hash, closure_hash?, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer { name, version, materialisation { llvm_version, pipeline, normaliser_version } }
  regions { <interface_hash>: { kind, signature, bounds, frame (§9.4), resources { name: decimal }, gates_used { gate: { count, scheme?, epsilon? } },
            claims: [ <claim> ... ],  verification: { oracle: i, borrow_frames: [i], inverse_pairs: [ { g, ginv, claim: i } ], channel: [i],
                                                      fault_rate: { domain, faults_by_code, undefined_excluded, layout_dependent_excluded } },
            cleanup: { "<variant>:<inherited_controls>": [ { path, realisation } ] },
            error: { local: { metric, value }, inclusive: { metric, value } },  definedness_assumptions: [ids] } }
  composition { multiplicities: { <hash>: n (derived from the realised schedule) }, epsilon_total: { metric: "diamond", value }, method: "sum_over_multiplicities" }
```

`inclusive(R) = local(R) + Σ_callees n_c × inclusive(c)`; an operator-
norm value converts to diamond by ×2 **once**, at the point where it is
first combined with a diamond value. A measurement-assisted realisation
requires a `channel` claim; a controlled unitary variant requires an
`operator_norm` claim. Linking recomputes `composition`.

## 13. Coverage (coverage 0.4)

`{ "entries": [ { "point": <program-point id>, "source": "<dialect-spec stable id>", "classification": "lowered" | "trapped" | "shimmed", "reason", "fault_code"?, "shim_hash"?, "count" } ] }`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

Executes an oracle's reference body per basis configuration: locations
and cells are bit-vectors, pseudo-locations are read-only, predication
is `if`, each §4.2 row is its classical function (assignment rows
assign; the stack and `alloctab` are arrays), `fault` records the code
and halts, `lift.retval` halts with success, the step counter counts
executed rows, counters are unbounded integers compared exactly. It
**defines** F_B and the budget unit and rejects any body that executes a
non-permutation gate.

### 14.2 Quantum state semantics

The state of a Q region is a vector in ⊗ over live wires in allocation
order (bundles little-endian). `qalloc` tensors |0⟩; `qfree` removes
clean factors; `qborrow` introduces a factor in unknown state, possibly
entangled with a reference system R, and the region's operation must be
U ⊗ I on it (§5.6); gates act by §4.4 under the active predicate;
`measure` (CC) is the projective computational-basis measurement with
Born probabilities, consuming the wires.

### 14.3 Theorems

- **T1 (totality).** For every well-formed oracle, budget and x ∈ D the
  reference interpreter halts within B + 1 rows and F_B(x) is unique.
- **T2 (prefix reversal).** For every executor whose realisation is a
  composition of ε = 0 permutation gates implementing §5.2 steps 1–4, on
  every x ∈ D every non-interface wire is clean after step 4 and borrowed
  bundles hold their initial values. *(Steps 1–2 are a permutation Π;
  step 3 acts on tgt, fr controlled on workspace; step 4 applies Π⁻¹.)*
- **T3 (permutation theorem).** If the realised unitary V of a circuit on
  span(D) is a permutation matrix and the final basis tuple equals P(x)
  for every x ∈ D, then V|span(D) = P. Applied to oracles, permutation
  actions and borrow frames (P = P' ⊗ I).
- **T4 (round trip).** For every finite valid CC/R trace with retained
  run history and tapes, LIFO reversal restores the classical
  environment, memory, allocation table, device-model state and history
  to entry values; observed external events are not retracted.
- **T5.** As §6.3.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on one
  target with the same schedule produce on every x ∈ D the same final
  tuple for every oracle (exact) and, for every action, unitaries within
  `inclusive₁ + inclusive₂` in operator norm (channels: diamond, after the
  single ×2 conversion).

### 14.4 Mechanisation *(deferred)*

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA; run history and LIFO reversal with loops, recursion, effects, hostcall, fault records (T4) |
| B | Executor | oracle totality and prefix reversal: every fault code; B = 0; boundary halts; recursion via `lift.call`; matched `lift.oracle_uncall`; interface regions restored; pre-entered allocations; `lift.free` on pinned entries |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs, borrow frames; T6 agreement among VM, specialiser, re-indexed/inlined/structure-recovered forms and the reference interpreter |
| D | Executor | channel and unitary comparison (Choi state with reference system) for ε > 0 realisations and measurement-based cleanups; controlled-interference tests; numerical witnesses |
| E | Target author, Executor | JCS parsing; AST evaluation in exact rationals; matching rules; scheme expansion; aggregation per kind; timing model; import maps |
| F | Producer | versioning and disjointness; operand schema; row classes, write sets and frame sizing; index-space flattening; terminators; permutation-only oracles; §6 transfer and windows; adjoint table; borrow-frame rule and toggling-lemma side conditions; `in`-wire use; acyclic action graphs; grammar; schemas; hashes; linking; frame-descriptor live ranges |
| G | Launch | every §10 entry point and state transition; HOST_REQUEST/reply; suspend at CC boundaries; reverse eligibility and tree order; ownership |
| H | Scheduler | §6 validity; capacity; reproducibility; hierarchical schedule validation and verbatim execution; INFEASIBLE/UNSUPPORTED |

## 16. Canonical textual form (normative)

### 16.1 Lexical

UTF-8; LF line endings; one instruction per line; tokens separated by
exactly one space; no trailing spaces; exactly one blank line before
each `section` line and none elsewhere. `NAME := [A-Za-z_][A-Za-z0-9_.]*`;
`INT := -?(0|[1-9][0-9]*)`; `FLOAT :=` shortest round-trip decimal with
`.` or exponent, finite; `STRING := "…"` with escapes `\"`, `\\`, `\n`
only; `HEX := ([0-9a-f]{2})*`. Metadata lines are RFC 8785 canonical
JSON objects.

### 16.2 Grammar

```
  object    := header NL section*
  header    := "bennett-object" SP "isa=" VER SP "object=" VER SP "launch=" VER SP "sched=" VER SP "cert=" VER SP "coverage=" VER SP "target=" VER SP "ptr_width=" INT
  section   := NL "section" SP SECTNAME NL body
  SECTNAME  := "symbols" | "imports" | "functions" | "data" | "devices" | "layout" | "schedule" | "certificate" | "coverage"
  body      := jsonline | dataline* | function*        (jsonline for all metadata sections; dataline* for data; function* for functions)
  jsonline  := JCS-canonical JSON object NL
  dataline  := NAME SP HEX NL
  function  := fhead NL regs? block+
  fhead     := ("fn" SP ("cc"|"r") | "oracle" | "action" | "perm_action" | "lproc") SP "@" NAME SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")"
               -- oracle: (in..) (tgt) (fault) (mem..) (args..) ; action: (mut..) (in..) (mem..) (args..) () ; lproc: (params..) (result) () () () ; fn: (params..) (results..) () () ()
  plist     := (param ("," SP param)*)?
  param     := NAME ":" type (SP ("in"|"mut"))?
  type      := "i" INT | "ptr" | "f64" | "token" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "region[" INT "," INT "]"
  regs      := "regs" SP "{" SP (NAME ":" type ("," SP NAME ":" type)*)? SP "}" (SP "result" SP NAME)? (SP "bounds" SP "{" INT ("," SP INT)* "}")? NL
  block     := "^" NAME "(" plist "):" NL instr+
  instr     := (lhs SP "=" SP)? OPCODE (SP operand)* (SP "{" NL instr+ "}" (SP "{" NL instr+ "}")?)? NL
  lhs       := NAME | "(" NAME ("," SP NAME)* ")"
  operand   := NAME | NAME "[" INT "]" | "@" NAME | "^" NAME ("(" (NAME ("," SP NAME)*)? ")")? | INT | FLOAT | STRING | "(" (NAME ("," SP NAME)*)? ")"
  OPCODE    := a mnemonic of §4 with its dotted suffix; its operand count and kinds are fixed by §4's form (results on the lhs)
  VER       := INT "." INT
```

### 16.3 Example objects

**Example 1** (`inc8`): one oracle, no lprocs, no memory.

```
bennett-object isa=0.4 object=0.4 launch=0.4 sched=0.4 cert=0.4 coverage=0.4 target=0.4 ptr_width=32

section symbols
{"0":{"interface_hash":"05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9","kind":"oracle","name":"inc8","signature":{"abi":"0.4","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[],"mut":[],"tgt":8,"tier":"q"}}}

section functions
oracle @inc8 (x:wire[8] in) (t:wire[8]) (f:wire[4]) () ()
regs { one:reg[8], r:reg[8] } result r
^entry():
one = lift.const 1
r = lift.add x one
lift.retval r
```

Its envelope (§9.2) is `isa=0` LF `ptr_width=32` LF the JCS signature LF
the four function lines joined by LF (no reference tokens, no data or
layout reached), and its interface hash is `05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9`. With B ≥ 3 every x
yields `(x + 1 mod 256, 0)`; with B = 2 every x yields `(0, FAULT_BUDGET_
STEPS)`.

**Example 2** (`sum_db`): an oracle reading an interface region through
lifted memory, with a recursive lproc and a global.

```
bennett-object isa=0.4 object=0.4 launch=0.4 sched=0.4 cert=0.4 coverage=0.4 target=0.4 ptr_width=32

section symbols
{"0":{"interface_hash":"f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535","kind":"oracle","name":"sum_db","signature":{"abi":"0.4","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[{"A":4,"W":8,"role":"in"}],"mut":[],"tgt":8,"tier":"q"}},"1":{"interface_hash":"5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2","kind":"lproc","name":"sum","signature":{"abi":"0.4","args":[],"in":[8,8],"kind":"lproc","tgt":8,"tier":"q"}}}

section functions
oracle @sum_db (n:wire[8] in) (t:wire[8]) (f:wire[4]) (db:region[4,8] in) ()
regs { base:reg[32], acc:reg[8], r:reg[8] } result r
^entry():
base = lift.const 4096
acc = lift.const 0
r = lift.call @sum (n, acc)
lift.retval r
lproc @sum (n:reg[8], acc:reg[8]) (r:reg[8]) () () ()
regs { z:reg[1], p:reg[32], idx:reg[32], one:reg[8], v:reg[8], acc2:reg[8], n2:reg[8] } result r
^entry():
z = lift.icmp.eq n zero
qbranch z ^done ^more
^more():
one = lift.const 1
n2 = lift.sub n one
idx = lift.zext n2
p = lift.add base idx
lift.boundscheck p 1
v = lift.load.i8 p
acc2 = lift.add acc v
r = lift.call @sum (n2, acc2)
lift.ret r
^done():
lift.ret acc

section data
zero 00

section layout
{"A_tab":4,"H":13,"S_cells":8,"globals":{"zero":{"base":16,"image":"zero","size":1}},"heap_base":32,"heap_limit_max":8160,"interface_regions":{"sum_db":{"db":{"base":4096}}},"null_size":16,"ptr_width":32}
```

Here `zero` is a 1-byte global at address 16 read by name as a pseudo-
location in `@sum` (a global's name denotes a lifted load of its image
width at its base; the dialect emits the `lift.boundscheck` for it, and
`@sum`'s `base` reference resolves to the oracle's location since lprocs
read the enclosing oracle's locations as pseudo-locations). The interface
region `db` is mapped at 4096; `alloctab` starts with pinned entries for
`zero` (16, 1) and `db` (4096, 16). With sufficient budget F_B(n) = (Σ_{i<n}
db[i] mod 256, 0) for n ≤ 16; for n > 16 the bounds check faults with
`FAULT_UB_MEMFAULT` at i = 16; with a small B the result is `FAULT_
BUDGET_STEPS`; with `depth_limit < n` it is `FAULT_BUDGET_DEPTH`. `5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2`
is `@sum`'s interface hash (its envelope reaches the `zero` data and
layout entries); `f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535` is `@sum_db`'s, with the `@sum` reference token
replaced by `@` + 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2. `@sum` references itself, so it is an SCC of one member: its
intra-SCC reference is written `@$0`, its envelope is hashed to `scc_hash`
and 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2 = SHA-256(`scc_hash` ‖ `:0`). The layout sub-entries an lproc or
oracle reaches are written one per line as `<dotted name> SP <JCS or INT>`
(here `A_tab`, `H`, `S_cells`, `globals.zero`, `heap_base`, `null_size`, and
for the oracle also `interface_regions.sum_db.db`), sorted by name. The
hashes below are computed by that rule:

```
05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9 = 05a871bb58aeccd0d4f107ff2f6e6f25af6647bc50ccd3f0688a662dfe8e8ad9
5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2 = 5ced2c33438316a5f9c0da90312795c1e3ca9872977c74ed4af6dfdd6f72c6e2
f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535 = f059b9fde993afa37b3a519df2fecb928245071fee652bde04fc3c3e3c12a535
```

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding. 2. Gate-name registry. 3. Further device models.
4. Mechanisation. 5. Memory layout of the opaque C objects.
