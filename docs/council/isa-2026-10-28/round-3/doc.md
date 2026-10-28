# Bennett Virtual ISA — Specification, draft 0.3

**Date:** 2026-10-28. **Status:** third normative draft, for council
iteration (reports: `docs/council/isa-2026-10-28/round-{1,2}/`; editor's
responses in `round-*/response.md`). Founding text of `bennett-isa-spec`
(`Bennett-NorthStar.md` §4.4, §6.1); the north star governs where this
draft is silent. Nothing is implemented. MUST, MUST NOT, SHOULD, MAY are
normative; *(non-normative)* explains; *(deferred)* names items left open
and asserted non-semantic.

**Versioning.** ISA 0.3, object 0.3, launch 0.3, sched 0.3, cert 0.3,
coverage 0.3, target 0.3, each semantically versioned and declared by
every conformant implementation.

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
| Producer | plugin, library compilers | well-formed objects (§9) and regions (§5, §6); suite F |
| Scheduler | `bennett-sched` and competitors | §11; only schedules valid under §6; suite H |
| Checker | `bennett-conformance` | validates certificates (§12) without trusting producers |
| Target author | vendors | target descriptions (§8); suite E |

### 1.3 Deferred *(asserted non-semantic)*

Binary encodings (the canonical text of §16 is the interchange form);
mechanisation of §14; device models beyond §7.3; the gate-name registry
process; the bit layout of the opaque launch/scheduler objects (their
accessors are normative, §10–§11).

## 2. Terminology

- **Tier.** CC (classical-control), R (reversible), Q (coherent).
- **Wire**, **bundle** `wire[N]` (little-endian, wire 0 least significant).
- **Location** `reg[N]`: a named mutable register-file cell of an oracle
  or lifted procedure (§3.7).
- **Region**: a Q function with a declared interface: **lifted oracle**
  (§5.2) or **quantum action** (§5.3). **Permutation action**: an action
  whose realised unitary is a permutation matrix (§5.3).
- **Lifted procedure** (`lproc`): a lifted sub-program with its own
  locations, callable from oracle bodies (§4.2).
- **Budget**: classical (steps B, heap limit, stack limit, depth limit).
- **Frame**: per machine step, the workspace retaining displaced values.
- **Basis configuration**: classical values on every wire of a region's
  interface, interface memory and borrowed bundles.
- **Gate classes.** Permutation gates: `x cx ccx mcx swap`. Diagonal
  gates: `s sdg t tdg cz rz`. Non-diagonal gates: `h rx ry`.
- **Control context** of an invocation: the conjunction of the caller's
  active predicate stack, every enclosing `ctl` wire, and the caller's
  own control context, transitively (§6.4).

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call/uncall)      CC ──calls──▶ Q regions (oracle_call / action_call)
  R  ──calls──▶ R functions, Q regions         Q  ──calls──▶ Q regions (§5.5), lprocs (oracle bodies only)
```

CC runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a
control or scheduling decision that depends on the value of a wire**
except through predication (§3.5). Gate angles are finite classical
`f64` fixed at region entry; non-finite angles are ill-formed.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical registers | CC, R | SSA values; within an activation immutable except block parameters |
| classical memory | CC, R | byte-addressed, little-endian, sparse; allocation metadata (§7.1) |
| effect tape, entropy tape | R | §7.3 |
| R history | R | stack of frames, one per executed R instruction (§7.4) |
| wire store | Q (CC via register ids) | live wires, each with a role: `input`, `target`, `fault`, `borrowed`, `mutable`, `workspace`, `location`, `cell` |
| quantum memory | Q | regions of `wire[W]` cells: function-local (§4.6) or interface (§5.1) |
| register file | Q | the locations of the active oracle and its lprocs (§3.7) |
| predicate stack | Q | wires; the active predicate is their conjunction |
| oracle step state | Q | `pc, pc' : wire[P]`; `faulted : wire`; `code : wire[F]`; counters `heap_used : wire[Hc]`, `sp : wire[Sc]`, `fp : wire[Sc]`, `depth : wire[Dc]`, `atop : wire[Ac]`; B frames |
| budget | Q | classical: B, heap_limit, stack_limit, depth_limit |

### 3.3 Types and ownership

```
  iN (1 ≤ N ≤ 128)   ptr (width = object.ptr_width)   f64   token        classical
  wire   wire[N]      linear values in structured code and interfaces
  reg[N]              a location (oracle bodies and lprocs); not linear
  region[A,W]         a quantum memory region of 2^A cells of wire[W] (interface parameter type)
```

**Linear SSA with implicit versioning.** In structured code (actions and
CC region calls) every `wire`/`wire[N]` value is produced once and
consumed once. An operand in mode `in` is consumed and a successor value
of the **same name** is produced by the instruction (the name always
denotes its latest version); `consume` consumes without a successor;
`produce` creates. A name MUST NOT be used after a `consume`. **Indexed
operand** `w[i]` (0 ≤ i < N, i a literal) borrows wire i of bundle `w` for
one instruction and reproduces `w`. **Disjointness:** the operands of one
instruction are pairwise disjoint wires; the interface bundles and
interface regions of a region are pairwise disjoint. Signed division
truncates toward zero. `measure` of `wire[n]` yields `in`.

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow and allocation. In
R every executed instruction pushes a history frame per §7.4; `uncall`
pops frames in LIFO order (T4).

### 3.5 Predication

Every Q instruction with unitary semantics executes controlled on the
active predicate. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. **Allocation, borrowing,
release, region creation and image gates are unconditional resource
operations**; only gates (including the gates inside copy/XOR/exchange/
memory instructions) are controlled.

### 3.6 The predicated step machine

An oracle body is a sequence `I[0..n)`, n ≥ 1, of lifted and control
instructions (§4.2) over the oracle's locations and its lprocs' locations;
`HALT = n`; P satisfies 2^P > n. **Well-formedness:** the last instruction
of the body and of every lproc is a terminator (`lift.retval`, `lift.
ret`, `qjump`, `qjumpr`, `fault`); falling off the end is ill-formed.

**Frame layout** (fixed per oracle, derived from §4.2's write sets):
`(old_pc : wire[P], disp_1 … disp_{k_max}, flag : wire)` where `k_max` is
the maximum number of displaced values of any instruction and each
`disp_j` has the maximum width of the j-th displaced value over all
instructions (`W_j`).

**Machine step** t (1 ≤ t ≤ B), from the state at the start of the step
(all reads refer to it):

1. **Dispatch.** Compute `at_k = (pc == k)` for k = 0..n into clean scratch.
2. **Execute.** For each k < n: push `at_k`; execute `I[k]` per its row in
   §4.2: each written location or cell receives its new value by **out-
   of-place compute into `disp_j`, then `qexch disp_j, destination`**, so
   `disp_j` retains the displaced old value; the row's `flag` (if any) is
   computed into `frame_t.flag`; pop `at_k`. Exactly one `at_k` is 1 on
   any basis branch.
3. **Successor.** For each k < n, under `at_k` XOR the successor index
   given by the row (and by `flag` for conditional rows) into `pc'`.
   Under `at_HALT` XOR `HALT` into `pc'` (**halted branches self-loop and
   change no state**).
4. **Commit pc.** `qexch pc pc'`; `qexch pc' frame_t.old_pc`.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

The step is a permutation; its inverse is the same sequence backwards
with each row's inverse (§4.2). An executor MUST implement this
transition or a transformation extensionally identical on every basis
configuration (§5.7, T6). B = 0 is legal: commit yields `FAULT_BUDGET_
STEPS` on every input.

### 3.7 Register files, procedures, the stack

An oracle declares `regs { name : reg[N], … }` and `result : reg[T]`; each
`lproc @f` declares its own `regs` and `params`/`result`. Locations are
clean at entry; interface inputs are `qcopy`ed into their locations at
entry (inputs are never written). Block parameters are lowered by the
dialect to `lift.parmov` on edges.

**Procedures.** `lift.call @f (args) → w` and `lift.ret v` implement calls
with **activation records on a monotonic stack** (§4.2 rows): the record
holds the return index, the caller's `fp`, and *all* locations of `@f`
exchanged out (so `@f` starts clean, which makes recursion correct); the
stack is never popped (records are history; `sp` only grows), `fp` links
records. Callee instructions are charged to the **caller's budget**
individually; `lift.call` and `lift.ret` are one step each. Executors MAY
inline extensionally (§5.7). Counter widths: `Hc ≥ ptr_width + 1`, `Sc`,
`Dc`, `Ac` large enough that every limit and every single increment are
representable without wrap; budget comparisons are over the full width.

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `const c:iN → r` | |
| `add sub mul and or xor shl lshr ashr` | `op a b → r` | wrap; shift ≥ N → 0 |
| `udiv urem sdiv srem` | `op a b → r` | divisor 0, or signed MIN/−1: CC traps; R fault record (§7.4) |
| `icmp` | `eq ne ult ule slt sle a b → r:i1` | |
| `select` | `select p a b → r` | |
| `zext sext trunc ptrtoint inttoptr` | | |
| `load` | `load.iN addr → r` ; `load.iN.{s,z}` sub-width | N/8 consecutive bytes, little-endian, unaligned allowed; out of any live allocation: CC trap / R fault record |
| `store` | `store.iN addr v` | |
| `alloc` / `free` | `alloc n → p` ; `free p` | monotonic bump allocator with metadata (§7.1); invalid free: trap / fault record |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | block parameters assigned in parallel |
| `call` / `uncall` / `ret` | `call @f args → results` ; `uncall` (R, §9.3) ; `ret vals` | |
| `trap` | | CC traps; R fault record |
| `measure` | `measure w:consume wire[n] → r:in` | CC only; Born rule (§14.2) |
| `effect` | `effect dev.op args → results` | R only (§7.3) |

### 4.2 Lifted instructions and control (oracle bodies and lprocs)

Notation: `r` read location/cell, `w` written location/cell, `c`
classical literal. **Write set** lists the displaced values in order
(`disp_1 …`). **Succ** is the successor index (k = own index). **Inverse**
is what a reversed step does for this row. Every row is one budget step.

| Row | Form | Reads | Writes (displaced) | Flag / fault | Succ | Inverse |
|---|---|---|---|---|---|---|
| `lift.const` | `lift.const c → w` | – | w | – | k+1 | exch back |
| `lift.binop` | `lift.{add,sub,mul,and,or,xor,shl,lshr,ashr} a b → w` | a, b | w | – | k+1 | exch back |
| `lift.div` | `lift.{udiv,urem,sdiv,srem} a b → w` | a, b | w (under ¬flag) | flag = (b=0) ∨ (signed ∧ a=MIN ∧ b=−1); under flag: fault `FAULT_UB_DIV0` / `FAULT_UB_SDIV_OVERFLOW` | ¬flag: k+1; flag: HALT | exch back |
| `lift.icmp` | `lift.icmp.{pred} a b → w:reg[1]` | a, b | w | – | k+1 | exch back |
| `lift.select` | `lift.select p a b → w` | p, a, b | w | – | k+1 | exch back |
| `lift.cast` | `lift.{zext,sext,trunc} a → w` | a | w | – | k+1 | exch back |
| `lift.mov` | `lift.mov a → w` | a | w | – | k+1 | exch back |
| `lift.parmov` | `lift.parmov (w_1..w_m) ← (a_1..a_m)` | a_i | w_1..w_m (atomic, parallel) | – | k+1 | exch back |
| `lift.boundscheck` | `lift.boundscheck p n:c` | p, alloctab | – | flag = ¬∃ i < atop: live_i ∧ base_i ≤ p ∧ p+n ≤ base_i+size_i (no wrap); under flag: fault `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT | – |
| `lift.load` | `lift.load.iN a → w` | bytes a..a+N/8−1 of `mem` | w | – | k+1 | exch back |
| `lift.store` | `lift.store.iN a v` | v | bytes a..a+N/8−1 (displaced: the N old bits) | – | k+1 | exch back |
| `lift.alloc` | `lift.alloc n → w` | n, heap_used, atop | w, heap_used, atop, alloctab[atop] (base,size,live) (under ¬flag) | flag = (heap_used+n > heap_limit) ∨ (atop = 2^Ac) (widened); under flag: fault `FAULT_BUDGET_HEAP` | ¬flag: k+1; flag: HALT | exch back |
| `lift.free` | `lift.free p` | p, alloctab | live_i ^= 1 for the unique i with live_i ∧ base_i = p (controlled-X, no displaced value) | flag = no such i; under flag: fault `FAULT_UB_MEMFAULT` | ¬flag: k+1; flag: HALT | same op |
| `lift.faultif` | `lift.faultif p code:c` | p | – | flag = p; under flag: fault `code` | ¬flag: k+1; flag: HALT | – |
| `lift.call` | `lift.call @f (a_1..a_m) → w` | a_i, sp, fp, depth, all locations L_f of @f | stack[sp..sp+R_f) ← (k+1, fp, L_f) by exchange (displaced: the old cell contents, clean); fp ← sp; sp ← sp+R_f; depth ← depth+1; params of @f ← copies of a_i | flag = (depth+1 > depth_limit) ∨ (sp+R_f > 2^Sc ∨ sp+R_f > stack_limit); under flag: fault `FAULT_BUDGET_DEPTH` | ¬flag: entry index of @f; flag: HALT | all exch back, copies un-XORed |
| `lift.ret` | `lift.ret v` | v, fp, record at fp | exchange record's L_f cells with @f's locations (restores the caller's view of them; the record now holds @f's final locations, including v); caller's `w` of the matching call ^= record's v; fp ← record.prev_fp; depth ← depth−1 | – | record.ret_index (read from the record before the exchange) | reverse of each sub-step |
| `lift.retval` | `lift.retval v` | v | result ^= v | – | HALT | un-XOR |
| `lift.oracle_call` | `lift.oracle_call @o tk:c (ins..) tgt fr` | ins, tgt, fr | tgt ^= payload, fr ^= code (callee contract) | – | k+1 | re-call (involution) |
| `lift.perm_call` | `lift.perm_call @a (mut..) (ins..)` | ins, mut | mut ← P(mut, ins) in place (callee is a permutation action) | – | k+1 | adjoint call |
| `qjump` | `qjump k':c` | – | – | – | k' | – |
| `qbranch` | `qbranch p k1:c k2:c` | p | – | – | p: k1; ¬p: k2 | – |
| `qjumpr` | `qjumpr a` | a | – | flag = (a ≥ n); under flag: fault `FAULT_UB_TRAP` | ¬flag: a; flag: HALT | – |
| `fault` | `fault code:c` | – | code ^= code; faulted ^= 1 | – | HALT | un-XOR |

`mem` is the oracle's byte region (§7.2); `alloctab` and the stack are
oracle regions declared by the producer with `Ac`, `Sc`. `k_max` and the
`W_j` of §3.6 are derived from the widest write set actually used
(`lift.call` and `lift.alloc` typically determine them). Nested
`lift.oracle_call` runs the callee under the token `tk`, a classical
argument of the calling oracle, so its budget is part of the caller's
F_B definition; the call is one step.

**Reference body and binding.** Every oracle in an object carries its
**reference body**: the instruction stream the dialect's versioned
mapping produced from the materialised source (a fixed, versioned
*sequence* of lifted instructions per source instruction, including the
`lift.boundscheck` before every memory access and the `lift.parmov` on
every edge), hashed as `reference_program_hash`. **F_B and the budget
unit are defined solely by the reference interpreter (§14.1) on the
reference body.** The object holds only the reference body; every
executor optimisation (structure recovery, inlining, simplification,
pebbling) is a transformation that MUST be extensionally equal to it on
D (T6). The fault set therefore depends only on (reference body, budget,
dialect-mapping version).

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `qalloc cls:c n:c → w:produce wire[n]` | n clean wires of class `cls` or `any`; unconditional |
| `qborrow` | `qborrow cls:c n:c → w:produce wire[n]` | n wires in unknown state, possibly entangled with an external system; usable only inside a borrow frame (§5.6) |
| `qfree` | `qfree w:consume wire[n]` | release a `qalloc`ed bundle that is clean on every basis configuration |
| `qreturn` | `qreturn w:consume wire[n]` | return a `qborrow`ed bundle after its borrow frame (the matched inverse of `qborrow`; the borrowed state is preserved by §5.6) |

### 4.4 Gates

Matrices, computational basis, |0⟩ = (1,0)ᵀ, bundles little-endian:

```
  x = [[0,1],[1,0]]    h = (1/√2)[[1,1],[1,-1]]    s = diag(1,i)   sdg = diag(1,-i)
  t = diag(1,e^{iπ/4})   tdg = diag(1,e^{-iπ/4})     cz = diag(1,1,1,-1)
  rx(θ) = exp(-iθX/2)    ry(θ) = exp(-iθY/2)          rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff all controls are |1⟩; identity otherwise (exact, no phase)
  swap: exact exchange
```

Forms: `x a`, `cx c t`, `ccx c1 c2 t`, `mcx (c_1..c_k) t`, `swap a b`,
`h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`, `ry θ a`,
`rz θ a`; all operands `in`, pairwise distinct wires; all execute
controlled on the active predicate.

**Realisation and legality.** A target realises a gate natively or by a
declared decomposition (§8.3). *Permutation status is a property of the
realised unitary at the gate boundary*: an exact Clifford+T realisation
of `ccx` is a permutation gate even though its interior contains `h` and
`t`. A realisation is conformant if its unitary equals the specified
unitary **exactly, including global phase** (`epsilon = 0`), or within a
declared ε in operator norm. **Oracles and permutation actions require
ε = 0 realisations** for every gate they execute (their contract is
exact equality); actions MAY use ε > 0 realisations, accounted per §12. A
relative-phase Toffoli is never a conformant `ccx`.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `qcopy s:in wire[n] → d:produce wire[n]` | d allocated clean (unconditional); `cx s[i] d[i]` for all i under the predicate |
| `quncopy` | `quncopy s:in d:consume` | `cx s[i] d[i]` under the predicate; `qfree d` |
| `qxor` | `qxor s:in t:in` | `cx s[i] t[i]` |
| `qexch` | `qexch a:in b:in` | `swap a[i] b[i]` |
| `qinplace` | `qinplace @g @ginv tk:c x:in wire[n]` | `@g`, `@ginv` are **total permutation oracles** on the n-bit encoding with certificates (§12) that under budget `tk` the fault code is `FAULT_NONE` on every basis input and `g∘ginv = ginv∘g = id`. Sem: `t = qalloc any n; f = qalloc any F; oracle_call @g tk (x) t f; qexch x t; oracle_call @ginv tk (x) t f; qfree t; qfree f`. (After the exchange x holds g(x₀) and t holds x₀; ginv(g(x₀)) = x₀ XORed into t clears it; f stays clean by the certificate.) |

### 4.6 Quantum memory, predication, structure

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A:c W:c [image]` | **function-local** region of exactly 2^A cells of `wire[W]`; created at function entry by unconditional allocation and X gates from the object's data image for `(function, name)` (default all zero); MUST be back at its image before exit, where the image gates are reversed and the cells released clean; name scope is the function; nested calls do not see it; the adjoint reverses creation and release |
| `qload` | `qload name a:in wire[A] → d:produce wire[W]` | d clean; for each cell i: under `a == i`, `qxor cell_i d` (address comparators are computed and uncomputed inside the instruction) |
| `qunload` | `qunload name a:in d:consume` | inverse of `qload` |
| `qstore` | `qstore name a:in v:in` | for each i: under `a == i`, `qxor v cell_i` |
| `qexchm` | `qexchm name a:in v:in` | for each i: under `a == i`, `qexch v cell_i` |
| `qpred` / `qunpred` | | §3.5; nested; the wire is not modified in between |
| `qif` | `qif w:in { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w` |
| `qloop` | `qloop n:c { body }` | body n times (n ≥ 0) |
| `qloop … while` | `qloop n:c while cond:in wire[n] { body }` | `cond` is a bundle of permutation-provenance wires (§6) computed before the loop from wires the body does not modify. Flags `c_1..c_n` are allocated clean; `c_1 ^= cond[0]`; iteration i (1..n) runs the body under `qpred c_i`; after iteration i < n, `ccx c_i cond[i] c_{i+1}`; after the loop the flags are uncomputed in reverse order (`ccx` then `cx`) and freed; n = 0 is the empty loop |

Interface regions (§5.1) are accessed with the same instructions by name.

### 4.7 Region calls (structured code and CC)

| Instruction | Form |
|---|---|
| `oracle_call` | `oracle_call @o tk:c (ins:in..) tgt:in fr:in (mem:in..) args:c..` |
| `action_call` | `action_call @a (mut:in..) (ins:in..) (mem:in..) args:c..` |
| `adj` | `adj action_call …` (§5.3); `adj oracle_call …` ≡ `oracle_call …` |
| `ctl` | `ctl w:in <call>`: the call under `qpred w` (for a whole action: the controlled unitary of §5.3) |

## 5. Regions

### 5.1 Interfaces and common well-formedness

Signatures list roles explicitly: `oracle @o (in a: wire[8], in b:
wire[8]) (tgt t: wire[8]) (fault f: wire[4]) (mem db: region[10,8] in)
(args n: i64)`. **Interface regions** (`mem`) are caller-owned quantum
memory regions passed by name: role `in` (returned to its entry contents
on every basis configuration; legal in oracles and actions) or `mut`
(transformed in place; actions only). A region MUST NOT contain
`measure`, `effect`, `br`, `call`, `uncall`, `trap`, classical memory
instructions, or (outside oracle bodies) lifted instructions. Predicate
stack empty at entry and exit. Every `qalloc` is matched by a `qfree` of a
clean bundle, every `qborrow` by a `qreturn` after its borrow frame, every
local `qregion` restored to its image, by **explicit cleanup instructions
in the program text**; the schedule chooses only realisations (§11).
Action call graphs MUST be acyclic; recursion exists only through
`lift.call` under the depth and stack budgets.

### 5.2 Lifted oracle

**Body.** Lifted and control instructions (§4.2) over its locations and
lprocs; **exact-permutation only**: every gate executed by the body, its
lprocs, every `lift.perm_call` target and every nested oracle is realised
with ε = 0 (§4.4). Suite F rejects anything else.

**Contract** on every basis configuration x ∈ D: `ins` unchanged; `tgt`
final = initial ⊕ payload(F_B(x)); `fr` final = initial ⊕ code(F_B(x));
interface regions of role `in` unchanged; borrowed bundles returned
(§5.6); workspace, locations, local regions, step state clean / at
image. **F_B(x)** = `(f(x), 0)` if the reference interpreter on the
reference body reaches `lift.retval` within B steps without a fault,
else `(0, code)` with `code` the first fault in sequential order, or
`FAULT_BUDGET_STEPS` if not halted after B steps. The oracle is an
**involution** on `(ins, tgt, fr)` and its own adjoint.

**Construction** (normative; T6 fixes every executor to it extensionally):

1. Allocate step state, locations, local regions (image gates), the B
   frames; `qcopy` each input into its location.
2. Run B machine steps (§3.6).
3. **Commit.** `at_HALT = (pc == HALT)` into scratch; under `at_HALT ∧
   ¬faulted`: `qxor result tgt`; under `faulted`: `qxor code fr`; under
   `¬at_HALT`: XOR the constant `FAULT_BUDGET_STEPS` into `fr`. The cases
   are exclusive (`fault` jumps to HALT). Uncompute `at_HALT`.
4. **Prefix reversal.** Invert step 2 then step 1. The commit writes are
   outside the reversed prefix and persist.

**Domain D**: every value of each `ins`, of `tgt`, of `fr`, of every cell
of every `in` region, of every borrowed bundle; `qalloc`ed wires at 0;
local regions at image.

### 5.3 Quantum action

**Semantics.** The body denotes a unitary U on mut ⊗ ins ⊗ mem_mut ⊗ (borrowed)
that is **block-diagonal in the computational basis of `ins` and of
`mem in` cells** (their basis values are unchanged; phases and
entanglement with `mut` are U's declared behaviour), is the identity on
borrowed systems and any external reference system (§5.6), and returns
all workspace clean and unentangled. An action has no fault outcome; a
fallible computation is an `oracle_call` whose `fr` it declares among
its `mut` wires. An action with coherent internal control (`qif`, `qloop
… while`) is, by definition, its padded unitary under its declared
bounds, which are part of its identity (§9.2). **Permutation action**:
an action whose realised unitary is a permutation matrix (all gates ε =
0 and permutation gates only, transitively); it is the only kind of
action an oracle may call.

**Body.** Gates; `qcopy quncopy qxor qexch qinplace`; `qload qunload
qstore qexchm`; `qpred qunpred qif qloop`; `oracle_call action_call`;
`qalloc qborrow qfree qreturn`; `qregion`.

**Adjoint table.** `adj @a` is the body in reverse order with each
instruction replaced per the table and the implicit versions renumbered
accordingly; the result is well-formed by construction:

```
  rx/ry/rz(θ) ↦ (−θ)      s ↔ sdg      t ↔ tdg      x cx ccx mcx swap h cz: self-adjoint
  qalloc ↔ qfree          qborrow ↔ qreturn          qregion creation ↔ its release
  qcopy ↔ quncopy         qload ↔ qunload            qxor qexch qstore qexchm: self-adjoint
  qinplace @g @ginv ↦ qinplace @ginv @g              oracle_call ↦ oracle_call
  action_call @b ↦ adj action_call @b                qpred/qunpred pairs reversed as a whole
  qif w {A}{B} ↦ qif w {adj A}{adj B}                qloop n {A} ↦ qloop n {adj A}
  qloop n while cond {A} ↦ allocate and compute the flags forward exactly as in §4.6, run
                           adj A for i = n..1 under c_i, uncompute the flags
```

**Control.** `ctl w @a` is controlled-U: workspace, regions and flags are
allocated unconditionally; every gate of the body, including those inside
copy/memory instructions and cleanup, runs under `w` in addition to the
active predicate; on `w = 0` the body is the identity and all workspace
is trivially clean.

### 5.4 Budgets and fault codes

Budget = (B, heap_limit, stack_limit, depth_limit), classical. B is
enforced by running exactly B steps. Heap, stack and depth are **wire
counters** compared at full width against the classical limits (§4.2
rows). Precedence when one instruction could raise two faults: the row's
flag definition is authoritative (`lift.call`: depth before stack;
`lift.alloc`: heap before table).

Fault codes (normative values; F ≥ 4):

```
  0 FAULT_NONE               4 FAULT_UB_TRAP            8 FAULT_EFFECT_UNMODELLED
  1 FAULT_BUDGET_STEPS       5 FAULT_UB_DIV0            9 FAULT_CALLEE
  2 FAULT_BUDGET_HEAP        6 FAULT_UB_SDIV_OVERFLOW
  3 FAULT_BUDGET_DEPTH       7 FAULT_UB_MEMFAULT
```

### 5.5 Nesting and nested faults

A `lift.oracle_call` supplies a caller location `fr'` for the nested fault
register. **No automatic propagation.** The dialect emits `lift.icmp.ne
fr' 0 → p; lift.faultif p FAULT_CALLEE` where the source semantics
requires it. `fr'` MUST be clean when the call computes a fresh outcome;
to clear a nonzero `fr'` the producer emits a second `lift.oracle_call
@o` with the same `tk`, `ins` versions and `tgt` version (the oracle is
an involution, so the second call XORs the same payload and code back);
suite F checks that the two calls' operand versions match. Alternatively
`fr'` is retained as data until the prefix reversal clears it.

### 5.6 Borrowed systems and borrow frames

**Requirement.** A region's completed operation MUST equal its declared
operation ⊗ identity on every borrowed bundle and on any external system
entangled with it. Basis-value restoration alone is **not** sufficient
(`cx b a; s a; cx b a` with b borrowed restores every basis value of b
and applies `s` to b).

**Rule (well-formedness, suite F).** Borrowed wires are touched only
inside **borrow frames**. A borrow frame is a maximal contiguous
subcircuit, within one region, consisting of **permutation gates only**
(including permutation-gate copy/XOR/exchange/memory instructions and
`lift.perm_call`s), that begins with the first and ends with the last
instruction touching the frame's borrowed wires. The frame's realised
permutation P_F on its wires (borrowed ∪ every wire a frame instruction
touches) MUST factor as `P_F = P' ⊗ I_borrowed`, i.e. P_F(x, b) = (P'(x),
b) for every basis value of every frame wire. This is verified by T3 over
the frame's full domain (exhaustively where finite, else by a library
certificate, §12 `borrow_frames`), or **structurally** when the frame has
the form `V; W; V⁻¹` with V permutation-only, W touching neither the
borrowed wires nor any wire V reads, and V⁻¹ the exact inverse sequence
of V. Inside a frame no wire of the frame is acted on by a non-permutation
gate (the frame is permutation-only by definition), so T3 applies.
Oracles are a single frame. Since P' does not depend on b, no public
output can depend on a borrowed value.

**Exit synchronisation** (oracles). Every basis branch has executed
exactly B machine steps at commit; branches differ in `pc` and data
until the reversal, which returns all control workspace to clean.

### 5.7 Executor transformations

Inlining of lprocs, structure recovery (`qif`/`qloop` for provably
structured CFG parts with static bounds), and any simplification MUST
produce, on every basis configuration in D, the same final interface
tuple as §5.2's construction on the reference body (T6); suite C tests
each executor against the reference interpreter.

## 6. Uncomputation validity (static discipline)

### 6.1 Provenance and dependency sets

Every workspace bundle version has provenance `perm` (computed by
permutation gates from its **dependency set** S) or `other`. S is a set of
*versions*: wire versions, location versions (oracle bodies), and cell
versions `(region, cell, v)` where v counts the stores/exchanges to that
cell so far; a cell's version advances on every `qstore`/`qexchm`/
`lift.store`/`lift.alloc` touching it.

**Transfer rules** (checked statically by suite F):

| Instruction | Effect on provenance |
|---|---|
| `qcopy s → d` under predicate stack Π | d: perm, S = {s} ∪ Π |
| `qload r a → d` under Π | d: perm, S = {a} ∪ {(r, i, v_i) for all cells} ∪ Π |
| `qxor s t` | if s and t are perm: t stays perm with S_t ∪ S_s ∪ Π; else t: other |
| `qexch a b` | provenances and sets swap |
| permutation gate, controls C, target t | t: perm iff t was perm, with S_t ∪ C ∪ Π ∪ ⋃_{c∈C} S_c; else other |
| diagonal gate on wire u | unchanged |
| non-diagonal gate on wire u | u: other; **and closes the window of every value whose S contains u** |
| `qstore`/`qexchm` to cell (r,i) | the cell's version advances; every value whose S names an older version of (r,i) has its window **closed** |
| `oracle_call @o (ins) tgt fr` | tgt, fr: perm with S = ins ∪ {tgt} ∪ {fr} ∪ Π (callee exact permutation); `in` regions unchanged |
| `lift.perm_call` / permutation `action_call` | each mut: perm with S = all mut ∪ ins ∪ Π |
| non-permutation `action_call` | every mut: other |
| `qinplace @g @ginv x` | x: perm with S = S_x ∪ Π |

### 6.2 Window and obligations

A perm value g with dependency set S is **in its window** from its
computation until the first of: a non-diagonal gate on any wire in S or
in g; a version advance of any cell in S; a non-permutation action call
touching a wire in S; or a permutation change to a wire in S that is not
undone again before g's cleanup. While in its window, g MAY be cleaned by
the inverse of its computing sequence (`quncopy`, `qunload`, adjoint
sequence) or by recomputation. **Every perm value MUST be cleaned within
its window and before its region exits.** A region containing a perm
value whose window closes before its cleanup is **ill-formed** in this
draft (closed-window measurement-based cleanup is not admitted until its
certificate contract exists). `other` values are released only by the
adjoint of the sequence that produced them.

### 6.3 Restated T5

Cleaning g within its window returns g's wires to |0⟩ and factorises
them from the remaining state; any diagonal gate on g, or use of g as a
control into a phase-eigenstate target, has applied the corresponding
diagonal phase (a function of S) to the remainder, and that phase is part
of the program's declared semantics, not a defect.

### 6.4 Control context and MBU

The **control context** of an invocation is inherited transitively (§2).
A **measurement-based realisation** of an in-window cleanup (Gidney-style
measure-and-fix) is legal **only** in a schedule for an invocation whose
control context is empty and whose target declares `mbu: true`; the fixup
is computed for the actual schedule (after an intervening U the
correction D becomes U D U†) and verified by suite D. Schedules and
certificate cleanup entries are keyed by `(region hash, variant ∈ {plain,
controlled, adjoint, controlled-adjoint})`; a region reachable under a
non-empty control context MUST have a unitary-cleanup schedule for that
variant. Schedulers choose only among realisations satisfying this
section.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse. `alloc n` returns the current bump
pointer, records `(base, size, live=1)` in the allocation table and
advances the pointer by n (n = 0 is a valid zero-size allocation that no
byte access may touch). Accesses are valid iff the whole byte range lies
in one live allocation. `free p` marks the unique live allocation with
base p dead; storage is never reclaimed (monotonic). Alignment is not
required.

### 7.2 Quantum memory of lifted code

An oracle's lifted classical memory is one byte region `mem` of 2^H
8-bit cells (`H ≤ ptr_width`), the allocation table `alloctab` (2^Ac
entries of `(base: ptr_width, size: ptr_width, live: 1)`), and the stack
region of 2^Sc cells of width `max(P, Sc, W_max)`. A `ptr` value is a byte
address into `mem`; `lift.load.iN`/`lift.store.iN` access N/8 consecutive
cells little-endian; an access whose range wraps past 2^H is out of every
allocation and faults through the preceding `lift.boundscheck`. `heap_
base = 0`; `lift.alloc` and `lift.free` maintain `alloctab` as §4.2. The
object's `layout` section records H, Ac, Sc and, for source globals, their
fixed base addresses and data images. `ptr_width` is an **object-level**
constant recorded in the header; a target MUST support the object's
`ptr_width` or refuse the object at load.

### 7.3 Device models and tapes (R)

| Device | State | Operations (typed) | Failure | Reversal |
|---|---|---|---|---|
| `console` | byte sequence | `write(bytes: [u8]) → ()` | – | pop the bytes |
| `clock` | counter `c: u64` | `read() → u64` returns `c`, then `c += 1` | – | `c −= 1` |
| `entropy` | position `p` into the **entropy tape** `[u8]` supplied at launch | `read(n: u64) → [u8]` returns tape[p..p+n), `p += n` | `p + n >` tape length: R fault record `ENTROPY_EXHAUSTED` | `p −= n` |
| `block` | sector map, 512-byte sectors; missing sectors read as zero | `read(s: u64) → [u8;512]` ; `write(s: u64, d: [u8;512]) → ()` (history records the overwritten sector) | – | restore the sector |

A run of an R function is a function of (program, initial state, entropy
tape). Each `effect` appends `(dev, op, args, results)` to the effect
tape; reversal pops and applies the inverse. Reversal restores device-
model state; it cannot retract an observation of the console, which is
why the coherent tier forbids effects.

### 7.4 R register model and history rules

Within an activation, SSA values are immutable except **block
parameters**, which `br` assigns in parallel. Each executed instruction
pushes one history frame:

| Instruction | Frame records |
|---|---|
| `br` (both forms) | predecessor block id; the prior values of the target block's parameters |
| `store` | address, width, overwritten bytes |
| `alloc` / `free` | the old bump pointer / the table entry's old live bit |
| `call` | nothing (the callee's frames follow) |
| `ret` | the callee's entire activation (all live SSA values) and the frame link |
| `effect` | index of the tape record |
| `oracle_call` / `action_call` from R | (region hash, variant, classical args, register ids); reversed by re-application / adjoint |
| all other instructions | nothing: their operands are immutable live SSA values in the current activation and their results are recomputable |
| fault record (`udiv` by 0, MIN/−1, trap, out-of-bounds, invalid free, entropy exhausted) | cause and location; execution enters a **terminal faulted state**; `uncall` reverses the prefix like any other |

`uncall` is valid only for the most recent unreversed `call` whose
activation is the top of the history stack (strict LIFO); reversal pops
frames in order. T4 is stated over these frames.

## 8. Resources and target descriptions (target 0.3)

### 8.1 Format

A target description is a **JSON document in RFC 8785 canonical form**
(JCS); `target_hash` = SHA-256 of those bytes. Cost expressions use the
closed language

```
  expr := number | "k" | "eps" | "log2inv_eps" | expr ("+"|"-"|"*"|"/") expr | "max(" expr "," expr ")" | "ceil(" expr ")" | "table[" (k | eps) "]"
```

with `table` a declared array indexed by k (exact) or by ε decade.

### 8.2 Resources and aggregation

```
  "resources": { "<name>": { "kind": "count" | "time" | "occupancy" | "peak", "unit": "<string>" } }
```

Mandatory: `qubit_second` (occupancy, per class), `time` (time, the
schedule makespan in seconds), `peak_qubits` (peak, per class). **Timing
model:** execution is sequential in program order unless the schedule
assigns start times; a gate occupies its wires for its declared `time`;
gates on disjoint wires MAY overlap unless `max_parallel` or a topology
is declared; the ISA machine is all-to-all over logical wires. A wire's
occupancy interval runs from `qalloc`/`qborrow` to `qfree`/`qreturn`;
**interface wires are charged to the caller** for the call's duration;
`qubit_second = Σ_wires interval × rate`, borrowed wires at the class's
`dirty_rate` charged to the borrower and replacing the owner's charge for
that interval. Dispatch, history, reversal and cleanup are instructions
of the lowered program and are counted like any other.

### 8.3 Classes, gates, decompositions, capabilities

```
  "ptr_widths_supported": [32, 64],
  "classes": { "<cls>": { "qubit_second": rate, "dirty_rate": rate, "capacity": int | "unbounded" } },
  "gates": { "<gate>": { "classes": ["<cls>" | "*"], "controls": int | "any",
                         "cost": { "<resource>": expr, ... , "time": expr } } },
  "decompositions": { "<gate>": { "scheme": "<name>", "params": ["k"], "epsilon": expr, "cost": {...} } },
  "capabilities": { "qram": null | {"load": {...}, "store": {...}, "exch": {...}},
                    "measurement": {"mid_circuit": bool, "feedforward_latency": seconds},
                    "mbu": bool, "max_parallel": int | "unbounded", "max_predicate_depth": int | "unbounded" },
  "objective": { "weighted": { "<resource>": weight } } | { "lexicographic": ["<resource>", ...] },
  "imports": { "<model>": { "version": "...", "map": { "<their quantity>": ["<resource>", factor] } } }
```

**Legality and cost of an executed gate** are functions of (opcode,
operand classes, arity, **total control count** = declared controls +
predicate depth, parameters, ε): a gate executed under predicate depth p
is the (p + its own controls)-controlled gate, legal iff some `gates` or
`decompositions` entry covers that control count and those classes, with
that entry's cost. `any` class resolves to the lowest `qubit_second`
class with remaining capacity. A gate with no covering entry is a load-
time error. Imports (§8.5 of 0.2) are the versioned `imports` map.

### 8.4 Space budget

The scheduler's capacity constraint is peak live qubits per class
(`peak_qubits`), separate from `qubit_second`.

## 9. Objects, identity, linking, reversible ABI (object 0.3)

### 9.1 Sections (canonical text, §16)

```
  header      versions; producer id; ptr_width; target hint
  symbols     local index → (name, kind, signature, interface_hash)
  imports     (name, signature, pinned closure_hash?)
  functions   bodies (fn <tier> | oracle | action | perm_action | lproc)
  data        data images (hex) for local regions and globals
  devices     device models used by R code
  layout      H, Ac, Sc, global bases, images
  schedule    optional serialised §11 schedule (JCS JSON) bound to a target_hash
  certificate §12 (JCS JSON)
  coverage    §13 (JCS JSON)
```

Metadata sections are single-line **JCS-canonical JSON** values (§16).

### 9.2 Identity

**Signature** = (tier, kind, interface roles and bundle widths in order,
interface region types and roles, T, F, classical argument types, action
bounds, ABI version). **Canonical bytes of a symbol** = the bytes of its
`functions` entry from its header line through its last body line
inclusive (grammar §16), with every reference to another symbol replaced
as below. **Interface hash** (compile time) = SHA-256 over the canonical
bytes with each reference to a defined symbol replaced by that symbol's
interface hash (hex) and each reference to an unresolved import replaced
by `SHA-256(name ‖ 0x00 ‖ canonical signature)`. **Closure hash** (link
time) = the same with resolved closure hashes substituted. **SCCs** of
mutually referencing symbols: order members lexicographically by name,
replace intra-SCC references by `$<index>`, hash the concatenation of the
members' canonical bytes in that order (`scc_hash`); member identity =
SHA-256(`scc_hash` ‖ index). **object_hash** = SHA-256 over all sections
except `schedule`, `certificate` and `coverage`. `reference_program_hash`
of an oracle = its interface hash. **Program-point id** = `(symbol
interface hash, block name, instruction index within the block)`.

### 9.3 Linking

Imports resolve by name + signature (link error on mismatch; a pinned
hash additionally requires equality); the resolved closure hash is
recorded in the linked certificate. Equal-hash duplicates deduplicate;
unequal hashes under one name, and conflicting `devices`/`layout`/
`data` entries, are link errors. Linking = resolution, validation,
composition of certificates (§12.3), rebinding of certificates to
closure hashes.

### 9.4 Reversible ABI

- **CC/R calls**: classical frame; the callee's R history frames follow
  the call frame on the caller's history stack; `uncall` reverses the
  most recent unreversed call (LIFO, §7.4).
- **Region calls**: interface bundles and regions are passed in declared
  order and owned by the caller; the callee owns its workspace and
  returns it clean, local regions at image, borrowed bundles returned.
- **Frame descriptor** (in every region's certificate): interface slots
  (role, width, class requirement), scratch requirement by class and
  cleanliness, retained-history requirement (oracles: B × frame width),
  borrow requirement (bundles it `qborrow`s). A caller MAY pass a
  **shared frame** satisfying the descriptor only when the caller's live
  values and history are disjoint from it for the call's duration (suite
  F checks live ranges); a callee `qborrow`s only from the caller's
  designated idle set.
- Variants (controlled, adjoint, controlled-adjoint) use the same
  descriptor.

## 10. Launch ABI (launch 0.3)

**Model.** A run executes a **device CC entry function**. The host passes
classical arguments, budgets and opaque **register ids** naming device-
resident quantum state that persists between runs, and receives
classical results, fault codes and declared read-back measurements.
Host code never holds a wire. Measurements whose results affect control
run in device CC.

**Invocation state machine.** `CREATED → RUNNING → (SUSPENDED ⇄ RUNNING) → COMPLETED | HOST_REQUEST ⇄ RUNNING | FAILED`; `COMPLETED → REVERSED`
(via `bennett_reverse`) `→ CLOSED` (via `bennett_run_close`). Run records
(history, classical args and register ids of every Q invocation in
order) are retained until `bennett_run_close`.

**Types** are opaque with versioned constructors/accessors; the fields
are normative:

```
  bennett_arg      : tagged union { INT(width, value) | F64 | QREG(id) | TOKEN(id) }  matched in order to the entry signature
  bennett_result   : { classical results [bennett_arg], fault_codes [u64], measurements [(qreg id, bits)], tape_length }
  bennett_request  : { service id, payload bytes }    # a host-service request raised by device CC
```

```c
  bennett_status bennett_load      (const uint8_t* object, size_t len, const uint8_t* target_jcs, size_t tlen, bennett_program** out);
  bennett_status bennett_unload    (bennett_program*);
  bennett_status bennett_budget    (bennett_program*, const char* region, uint64_t steps, uint64_t heap, uint64_t stack, uint64_t depth, bennett_token* out);
  bennett_status bennett_qreg_new  (bennett_program*, const char* cls, uint32_t n, bennett_qreg* out);      // clean
  bennett_status bennett_qreg_prepare(bennett_program*, bennett_qreg, const uint8_t* bits, size_t nbits);  // X gates on a clean register; invalidates no run
  bennett_status bennett_qreg_free (bennett_program*, bennett_qreg);                                        // must be clean
  bennett_status bennett_run       (bennett_program*, const char* cc_entry, const bennett_arg* args, size_t n, bennett_run_id* out);
  bennett_status bennett_wait      (bennett_program*, bennett_run_id, bennett_result** out, bennett_request** req_out); // returns in COMPLETED, FAILED or HOST_REQUEST
  bennett_status bennett_reply     (bennett_program*, bennett_run_id, const uint8_t* payload, size_t len);  // answers a HOST_REQUEST, run resumes
  bennett_status bennett_suspend   (bennett_program*, bennett_run_id);   // takes effect at the next CC instruction boundary outside any region
  bennett_status bennett_resume    (bennett_program*, bennett_run_id);
  bennett_status bennett_reverse   (bennett_program*, bennett_run_id);   // see eligibility
  bennett_status bennett_run_close (bennett_program*, bennett_run_id);
  bennett_status bennett_tape      (bennett_program*, bennett_run_id, bennett_tape_iter** out);
  bennett_status bennett_estimate  (bennett_program*, const char* region, bennett_token, bennett_estimate** out);   // no execution
  bennett_status bennett_coverage  (bennett_program*, bennett_coverage** out);
  // errors: E_VERSION E_PTR_WIDTH E_DEVICE_MISSING E_GATE_UNSUPPORTED E_TARGET E_BUDGET E_QREG_NOT_CLEAN E_INVALID_STATE E_NOT_REVERSIBLE E_SCHEDULE_INFEASIBLE
```

**Reverse eligibility.** `bennett_reverse` is valid only in `COMPLETED`,
and only if the run performed no `measure` and every register it touched
has not been prepared, freed or used by a later run (`E_NOT_REVERSIBLE`
otherwise). It reverses the run's record in reverse order: R segments by
`uncall`, each Q invocation by re-application (oracle) or adjoint
(action) with the recorded classical args and register ids, CC segments
by restoring their recorded classical state.

## 11. Scheduling interface (sched 0.3)

```c
  bennett_status bennett_sched_schedule(const bennett_sched_request*, bennett_sched_response**);
  // request (opaque, accessors): object bytes, target JCS bytes, region interface hash, variant,
  //          objective, budget (B, heap, stack, depth), classical parameters, ε_total, capacity per class,
  //          scheduler version requested
  // response: SCHEDULED(schedule bytes, certificate bytes) | INFEASIBLE(reason) | UNSUPPORTED(feature)
```

**Schedule** (JCS JSON; the object's `schedule` section): `{ bindings: {
object_hash, target_hash, region, variant, budget, params_hash, epsilon
}, entries: [ { point: <program-point id>, kind: cleanup | alloc | gate |
structure | start, realisation: reverse | recompute | mbu, class, scheme,
params, epsilon_share, start_time } ] }`. **Obligations:** satisfy §6;
respect capacity; report every declared resource; be reproducible from
the request plus scheduler version. A consumer validates every binding
and every point id against the object, then executes the schedule
**verbatim** or rejects it (`E_SCHEDULE_INFEASIBLE`) and requests a
replacement; it never alters program semantics. The VM uses this
interface at run time with the run-time budget in the request.

## 12. Certificate (cert 0.3; JCS JSON)

### 12.1 Claims

Each verification claim has a **kind** with a normative payload and a
versioned checker:

| kind | payload | checker obligation |
|---|---|---|
| `exhaustive` | domain: per interface bundle `{width, lo, hi}` ranges; expected: `oracle` \| `permutation(<hash of P as a table or program>)` | re-execute every element against the reference interpreter |
| `sampled` | domain; `sampler: {algorithm: "xoshiro256**", version, seed, count}` | replay the sample; **evidence** |
| `structural` | the rule invoked (`borrow_frame_VWV`, `inverse_pair_library`, `adjoint_table`) and the sub-claims it rests on | check the rule's side conditions syntactically |
| `numerical` | `{widths, metric: "operator_norm" \| "diamond", bound, method: "interval_arithmetic" \| "rational_exact", precision}` | recompute the bound by the named method; agreement without a bound method is **evidence** |

### 12.2 Schema

```
  versions, bindings: { object_hash, interface_hash, closure_hash?, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer: { name, version, materialisation: { llvm_version, pipeline, normaliser_version } }
  regions: { <interface_hash>: {
      kind, signature, bounds, frame (§9.4), resources { <name>: value }, gates_used { <gate>: { count, scheme?, epsilon? } },
      verification: { oracle: <claim>, borrow_frames: [<claim>], inverse_pairs: [{g, ginv, <claim>}], channel: [<claim>],
                      fault_rate: { domain, faults_by_code, undefined_excluded, layout_dependent_excluded } },
      cleanup: { <variant>: [ { point, realisation } ] },
      error: { local_epsilon, inclusive_epsilon },
      definedness_assumptions: [ <assumption id from the dialect spec> ] } }
  composition: { multiplicities: { <interface_hash>: n }, epsilon_total, method: "sum_over_multiplicities" }
```

### 12.3 Composition

`inclusive_epsilon(R) = local_epsilon(R) + Σ_callees n_c × inclusive_epsilon(c)`;
operator-norm bounds on unitaries convert to diamond-norm bounds on
channels by the factor 2 before summation with channel bounds. Linking
recomputes `composition` over the closure.

## 13. Coverage (coverage 0.3; JCS JSON)

`[ { point: <program-point id of the reference body>, source_location: <dialect-spec stable id>, classification: "lowered" | "trapped" | "shimmed", reason, fault_code?, shim_hash?, count } ]`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

Executes an oracle's **reference body** per basis configuration:
locations and cells are bit-vectors, predication is `if`, each §4.2 row is
its classical function, `fault` records the code and halts, `lift.retval`
halts with success, the step counter counts executed rows, counters are
integers compared without wrap. It **defines** F_B and the budget unit
and rejects any body containing a non-permutation gate.

### 14.2 Quantum state semantics

The state of a Q region is a vector in ⊗ over live wires in allocation
order (bundles little-endian). `qalloc` tensors |0⟩ factors; `qfree`
removes clean factors; `qborrow` introduces a factor in unknown state
possibly entangled with a reference system R, and the region's operation
is required to be U ⊗ I on it (§5.6); gates act by §4.4's matrices under
the active predicate; `measure` (CC) is the projective computational-
basis measurement with Born probabilities, consuming the wires.

### 14.3 Theorems

- **T1 (totality).** For every well-formed oracle, budget and x ∈ D, the
  reference interpreter halts within B + 1 rows and F_B(x) is unique.
- **T2 (prefix reversal).** For every executor whose oracle realisation
  is a composition of ε = 0 permutation gates implementing §5.2 steps 1–4,
  on every x ∈ D every non-interface wire is clean after step 4 and
  borrowed bundles hold their initial values. *(Steps 1–2 are a
  permutation Π on workspace ⊗ interface; step 3 acts on tgt, fr
  controlled on workspace; step 4 applies Π⁻¹.)*
- **T3 (permutation theorem).** If the realised unitary V of a circuit on
  span(D) is a permutation matrix and for every x ∈ D the final basis
  tuple equals P(x), then V|span(D) = P: no relative phase, no residual
  entanglement. Applied to oracles (P the §5.2 tuple), permutation
  actions (P = |g(x)⟩, workspace clean) and borrow frames (P = P' ⊗ I).
- **T4 (round trip, R).** For every finite valid R trace with retained
  history and tapes, `uncall` in LIFO order restores classical state,
  memory, allocation metadata, device-model state and history to their
  entry values; observed external events are not retracted.
- **T5.** As §6.3.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on one
  target with the same decompositions produce, on every x ∈ D, the same
  final tuple for every oracle (exact) and, for every action, unitaries
  within `inclusive_epsilon₁ + inclusive_epsilon₂` in operator norm
  (channels: diamond norm, after the ×2 conversion).

### 14.4 Mechanisation *(deferred)*

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA; R round trip with history, tapes, loops, recursion, fault records (T4) |
| B | Executor | oracle totality and prefix reversal (T1, T2): every fault code; B = 0; boundary halts; `lift.call`/`lift.ret` recursion; nested oracle faults and matched re-calls; interface regions restored |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs, borrow frames; T6 agreement among VM, specialiser, inlined/structure-recovered forms and the reference interpreter |
| D | Executor | channel and unitary comparison (Choi state with reference system) for ε > 0 realisations and MBU cleanups; controlled-interference tests; numerical-bound methods |
| E | Target author, Executor | JCS parsing; cost-expression evaluation; aggregation per kind; timing model; control-count legality; import maps |
| F | Producer | linearity and versioning; disjointness; write sets and frame sizing; terminators; permutation-only oracles; §6 transfer rules and windows; adjoint table; borrow-frame rule; acyclic action graphs; grammar; hashes; linking; frame-descriptor live ranges |
| G | Launch | every §10 entry point and state transition; suspend at CC boundaries only; HOST_REQUEST/reply; reverse eligibility and order |
| H | Scheduler | §6 validity; capacity; reproducibility; stored-schedule validation and verbatim execution; INFEASIBLE/UNSUPPORTED |

## 16. Canonical textual form (normative)

### 16.1 Lexical

UTF-8, LF line endings, one instruction per line, tokens separated by
exactly one space, no trailing spaces, no blank lines except one between
sections. `NAME := [A-Za-z_][A-Za-z0-9_.]*`; `INT := -?[0-9]+` (no leading
zeros except `0`); `FLOAT :=` shortest round-trip decimal with a `.` or
exponent, finite only; `STRING := "..."` with escapes `\" \\ \n` only;
`HEX := [0-9a-f]*` even length. Metadata JSON is RFC 8785 canonical on one
line.

### 16.2 Grammar

```
  object     := header NL section*
  header     := "bennett-object" SP "isa=" VER SP "object=" VER SP "launch=" VER SP "sched=" VER SP "cert=" VER SP "coverage=" VER SP "target=" VER SP "ptr_width=" INT
  section    := NL "section" SP SECTNAME NL body
  SECTNAME   := "symbols" | "imports" | "functions" | "data" | "devices" | "layout" | "schedule" | "certificate" | "coverage"
  body       := jsonline              (symbols, imports, devices, layout, schedule, certificate, coverage)
              | dataline*             (data)
              | function*             (functions)
  jsonline   := JCS-canonical JSON object NL
  dataline   := NAME SP HEX NL
  function   := fhead NL regs? block+
  fhead      := ("fn" SP TIER | "oracle" | "action" | "perm_action" | "lproc") SP "@" NAME SP iface
  TIER       := "cc" | "r"
  iface      := "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")" SP "(" plist ")"
                 -- oracle: (in..) (tgt) (fault) (mem..) (args..); action: (mut..) (in..) (mem..) (args..) ()
                 -- lproc: (params..) (result) () () (); fn: (params..) (results..) () () ()
  plist      := (param ("," SP param)*)?
  param      := NAME ":" type (SP ROLE)?
  type       := "i" INT | "ptr" | "f64" | "token" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "region[" INT "," INT "]"
  ROLE       := "in" | "mut"
  regs       := "regs" SP "{" SP (NAME ":" type ("," SP NAME ":" type)*)? SP "}" (SP "heap" SP INT)? (SP "alloctab" SP INT)? (SP "stack" SP INT)? (SP "bounds" SP "{" INT ("," SP INT)* "}")? NL
  block      := "^" NAME "(" plist "):" NL instr+
  instr      := (NAME ("," SP NAME)* SP "=" SP)? OPCODE (SP operand)* (SP "{" NL instr+ "}" (SP "{" NL instr+ "}")?)? NL
  operand    := NAME | NAME "[" INT "]" | "@" NAME | "^" NAME ("(" (NAME ("," SP NAME)*)? ")")? | INT | FLOAT | STRING | "(" (NAME ("," SP NAME)*)? ")"
  OPCODE     := any mnemonic of §4 (with its dotted suffix), e.g. "lift.add", "lift.icmp.ult", "lift.load.i32", "mcx", "oracle_call"
  VER        := INT "." INT
```

The canonical bytes of a function are its text from `fhead` through its
last `instr` line inclusive. A binary encoding *(deferred)* MUST round-
trip through this form. An executor refuses an object whose ISA major
differs from its own and MAY accept a lower minor.

### 16.3 A complete example object

```
bennett-object isa=0.3 object=0.3 launch=0.3 sched=0.3 cert=0.3 coverage=0.3 target=0.3 ptr_width=32

section symbols
{"0":{"interface_hash":"c9303119bc1bb381323f77d8ab6a3c24f15b7f19c4d740670312afb91c2d6188","kind":"oracle","name":"inc8","signature":{"abi":"0.3","args":[],"fault":4,"in":[8],"kind":"oracle","mem":[],"tgt":8,"tier":"q"}}}

section functions
oracle @inc8 (x:wire[8] in) (t:wire[8]) (f:wire[4]) () ()
regs { rx:reg[8], one:reg[8], r:reg[8] }
^entry():
lift.mov x rx
lift.const 1 one
lift.add rx one r
lift.retval r
```

`H_inc8` is the SHA-256 (hex) of the function's canonical bytes (the
seven lines from `oracle @inc8 …` through `lift.retval r`, joined by LF
with no trailing LF): `c9303119bc1bb381323f77d8ab6a3c24f15b7f19c4d740670312afb91c2d6188`.
The object has no imports, so its closure hash equals its interface
hash. With B ≥ 4 and any budget, F_B(x) = (x + 1 mod 256, 0) for every x;
with B = 3, F_B(x) = (0, FAULT_BUDGET_STEPS) for every x.

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding. 2. Gate-name registry. 3. Further device models.
4. Mechanisation. 5. Bit layout of the opaque launch/scheduler objects.
