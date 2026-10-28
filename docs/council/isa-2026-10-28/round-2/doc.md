# Bennett Virtual ISA — Specification, draft 0.2

**Date:** 2026-10-28. **Status:** second normative draft, for council
iteration (round 1 report: `docs/council/isa-2026-10-28/round-1/`; all
three members "revise"; the editor's response is in `round-1/response.md`).
This document is the founding text of the `bennett-isa-spec` repository
defined in `Bennett-NorthStar.md` §4.4 and §6.1; the north star governs
where this draft is silent. Nothing is implemented. MUST, MUST NOT, SHOULD
and MAY are normative. *(non-normative)* marks explanation; *(deferred)*
marks items this draft leaves open and asserts to be non-semantic.

**Versioning.** The ISA, the object format, the launch ABI, the scheduling
interface, the certificate schema and the coverage-report format are
versioned independently (semantic versioning); a conformant implementation
declares each. This draft is ISA 0.2, object 0.2, launch 0.2, sched 0.2,
cert 0.2, coverage 0.2.

---

## 1. Scope and conformance

### 1.1 What the ISA is

A program model for classical, reversible and coherent computation with a
single semantics, executed by the **virtual machine** (`bennett-vm`) and
the **circuit specialiser** (`bennett-circuits`), produced by the LLVM
plugin (`bennett-plugin`) through the dialect's reference semantics
(`bennett-dialect-spec`), scheduled through §11, and described for
hardware by target descriptions (§8). Nothing here refers to LLVM.

### 1.2 Conformance classes

| Class | Who | Obligation |
|---|---|---|
| **Executor** | VM, specialiser, hardware stacks | §3–§7 and §14 exactly; suites A–E, H (§15). |
| **Producer** | plugin, library compilers | well-formed objects (§9) and regions (§5, §6); suite F. |
| **Scheduler** | `bennett-sched` and competitors | §11; returns only schedules valid under §6; suite H. |
| **Checker** | `bennett-conformance` | validates certificates (§12) against objects without trusting producers. |
| **Target author** | hardware vendors | target descriptions conforming to §8; suite E. |

### 1.3 Deferred *(deferred, asserted non-semantic)*

Binary encodings (the canonical text of §16 is the normative interchange
form); mechanisation of §14; device models beyond the four of §7.3; the
gate-name registry process. **Fault-code values are not deferred** (§5.4):
they are quantum data and therefore semantic.

## 2. Terminology

- **Tier.** *classical-control* (CC), *reversible* (R), *coherent* (Q).
- **Wire.** One qubit. **Bundle** `wire[N]`: N wires with little-endian
  integer reading, wire 0 the least significant.
- **Register file.** In a lifted oracle, the named bundles that hold the
  lifted program's values (§3.7); they are *mutable locations*, not SSA
  values.
- **Region.** A Q-tier function with a declared interface: a **lifted
  oracle** (§5.2) or a **quantum action** (§5.3).
- **Budget.** The classical triple (steps, heap, depth) a lifted oracle
  runs under.
- **Fault register.** A caller-supplied bundle that receives the oracle's
  fault code by XOR at commit.
- **History frame.** Per machine step, the workspace that retains what
  the step displaced (§3.6).
- **Basis configuration.** An assignment of classical values to every
  wire of a region's interface and borrowed bundles.
- **Permutation gate.** `x cx ccx mcx swap`. **Diagonal gate.** `s sdg t
  tdg cz rz`. **Non-diagonal gate.** `h rx ry`.

## 3. Machine model

### 3.1 Tiers and the control invariant

```
  CC ──calls──▶ R functions (call / uncall)        CC ──calls──▶ Q regions (oracle_call / action_call)
  R  ──calls──▶ R functions and Q regions          Q  ──calls──▶ Q regions (§5.5)
```

CC code runs on the device's classical-control processor; the host reaches
the device only through §10. **No instruction in any tier makes a control
or scheduling decision that depends on the value of a wire** except
through predication (§3.5), which conditions on a wire without inspecting
it. Classical angle parameters of gates are constants fixed at region
entry; nothing superposed ever becomes classical except by `measure`.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical registers | CC, R | SSA values of classical type |
| classical memory | CC, R | byte-addressed sparse map, little-endian, reads of unwritten bytes yield 0 |
| effect tape | R | append-only sequence of effect records (§7.3) |
| entropy tape | R | input sequence supplied at launch, consumed in order (§7.3) |
| R history | R | stack of history frames, one per executed R instruction (§7.4) |
| wire store | Q (CC via handles) | all live wires, each with a **role**: `input`, `target`, `fault`, `borrowed`, `mutable`, `workspace`, `register`, `memory` |
| quantum memory | Q | named regions of `wire[W]` cells (§7.2), including the oracle's `heap` and `stack` regions |
| register file | Q (oracle) | named bundles holding the lifted program's values (§3.7) |
| predicate stack | Q | stack of wires; the **active predicate** is their conjunction |
| step state | Q (oracle) | `pc : wire[P]`, `pc' : wire[P]`, internal `faulted : wire`, `code : wire[F]`, `heap_used : wire[H]`, `depth : wire[Dw]`, B history frames |
| budget | Q (oracle) | classical: steps B, heap limit, depth limit |

### 3.3 Types

```
  iN          classical integer, 1 ≤ N ≤ 128, two's complement          (CC, R)
  ptr         classical byte address; width = target.ptr_width          (CC, R)
  f64         classical binary64                                         (CC; gate angles in Q)
  wire        one qubit, linear (structured code and interfaces)
  wire[N]     bundle, linear as a unit
  reg[N]      a register-file location of width N (oracle bodies only; not linear, §3.7)
  token       classical opaque value (budgets)
```

**Linearity** applies to `wire`/`wire[N]` values in quantum actions and
at region interfaces: produced exactly once, consumed exactly once.
Register-file locations in oracle bodies are not linear; they are
mutable state re-executed every machine step (§3.6–§3.7). Operand modes
below: `in` (used, returned unchanged), `consume`, `produce`, `c`
(classical), `r` (register-file location, read), `w` (register-file
location, written by exchange).

### 3.4 Execution in CC and R

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow, dynamic
allocation. In R every instruction has a **history rule** (§7.4) that
records exactly what it destroys, so the executor can run any finite R
trace backwards to its entry state (T4).

### 3.5 Predication in Q

Every Q instruction with unitary semantics executes controlled on the
active predicate p. `qpred w` pushes, `qunpred w` pops the same wire; the
stack is empty at region entry and exit. **Allocation, borrowing and
release are unconditional resource operations**: `qalloc`/`qborrow`/
`qfree` act for the region's static maximum regardless of predicate
values; only gates are controlled. A controlled wire-producing
instruction (`qcopy`, `qload`) allocates unconditionally and copies under
the predicate.

### 3.6 The predicated step machine *(the general construction for lifted oracles)*

A lifted oracle body is a list of instructions `I[0..n)`, each a *lifted
instruction* (§4.2) or a control instruction, with `HALT = n`. Choose P
with 2^P > n. The oracle allocates `pc`, `pc'`, `faulted`, `code`,
`heap_used`, `depth`, the register file, the `heap` and `stack` regions,
and **B history frames**, each of layout `(old_pc : wire[P], displaced :
wire[W_max], flag : wire)` where W_max is the widest register-file
location. All start clean; `pc` is XORed with the entry index 0.

One **machine step** t (1 ≤ t ≤ B), from an immutable snapshot of the
state at the start of the step:

1. **Dispatch.** For every k in 0..n inclusive compute `at_k = (pc == k)`
   into clean scratch (permutation computation from `pc`).
2. **Execute.** For every k < n, push `at_k`, execute `I[k]` (§4.2: its
   result is computed out of place into frame t's `displaced` slot, then
   `qexch`ed into the destination location, so the slot now holds the
   displaced old value; its optional comparison flag goes into frame t's
   `flag`), pop `at_k`. Exactly one `I[k]` has `at_k = 1` on any basis
   branch, so exactly one location changes per step per branch.
3. **Next pc.** For every k < n: under `at_k`, XOR the successor index
   into `pc'` (the fallthrough index `k+1` for non-control instructions;
   the selected target for `qjump`/`qbranch`/`qjumpr`; `HALT` for `ret`
   and `fault`). Under `at_HALT`, XOR `HALT` into `pc'` (**halted
   branches self-loop and change no state**).
4. **Commit pc.** `qexch pc pc'` then `qexch pc' frame_t.old_pc`: `pc`
   now holds the next index, `pc'` is clean, frame t holds the old pc.
5. **Clean dispatch.** Uncompute every `at_k` from `frame_t.old_pc`.
6. Decrement the classical step counter.

The step is a permutation of the state and its inverse is the same
sequence read backwards. Every executor MUST implement this transition
or a transformation of it that is extensionally identical on every basis
configuration (§5.7, T6). B = 0 is legal (the oracle commits `FAULT_
BUDGET_STEPS` on every input unless index 0 is HALT).

### 3.7 The register file and lifted values

A lifted oracle declares `regs: name : reg[N], …`, a result location
`result : reg[T]`, and the widths H, Dw of `heap_used`, `depth`. Every
lifted value of the source program occupies one location. Lifted
instructions read locations and write **exactly one** location by the
out-of-place-then-exchange rule of §3.6 step 2; the displaced old value
is retained in the step's history frame. Block parameters are lowered by
producers to `lift.mov` on edges (critical edges split), so no coherent
phi is needed. Locations are initialised clean at region entry;
interface inputs are copied into their locations at entry by `qcopy`
(inputs are never written).

*(non-normative)* The machine is Bennett's history construction at
instruction granularity over a register file. It costs B × (P + W_max + 1)
history wires; the specialiser recovers structure to reduce it (§5.7).

## 4. Instruction set

### 4.1 Classical control (CC, R)

| Instruction | Form | Semantics |
|---|---|---|
| `const` | `const c:iN → r` | |
| `add sub mul and or xor shl lshr ashr` | `op a b → r` | two's complement, wrap; shift by ≥ N yields 0 |
| `udiv urem sdiv srem` | `op a b → r` | divisor 0: CC traps, R records a fault record and halts (§7.4); `sdiv`/`srem` of INT_MIN by −1: CC traps, R fault record |
| `icmp` | `eq ne ult ule slt sle a b → r:i1` | |
| `select` | `select p a b → r` | |
| `zext sext trunc ptrtoint inttoptr` | | `ptr` width = `target.ptr_width` |
| `load` | `load.iN addr:ptr → r:iN` ; `load.iN.{s|z}` for sub-register widths | little-endian, unaligned permitted; CC: out-of-bounds traps; R: fault record |
| `store` | `store.iN addr:ptr v:iN` | R history rule: records the overwritten bytes |
| `alloc` / `free` | `alloc n:iN → p:ptr` ; `free p` | bump allocator; R: `free` validates and is reversed by rewinding the bump pointer |
| `br` | `br ^b(args)` / `br p ^b1(args) ^b2(args)` | block parameters |
| `call` / `uncall` / `ret` | `call @f args → results` ; `uncall @f` (R only, §9.3) ; `ret vals` | |
| `trap` | `trap` | CC traps; R fault record |
| `measure` | `measure w:consume wire[n] → r:iN` | CC only; computational-basis measurement with Born probabilities (§14.2); the little-endian integer |
| `effect` | `effect dev op args → results` | R only (§7.3) |

### 4.2 Lifted instructions (oracle bodies only; each is one budget step)

Operands are register-file locations (`r` read, `w` written). Each
computes its result out of place into the step's `displaced` slot by
permutation gates and exchanges it into `w` (§3.6).

| Instruction | Form | Semantics / fault |
|---|---|---|
| `lift.const` | `lift.const c → w` | |
| `lift.binop` | `lift.{add,sub,mul,and,or,xor,shl,lshr,ashr} a:r b:r → w` | as §4.1; shift by ≥ N yields 0 |
| `lift.div` | `lift.{udiv,urem,sdiv,srem} a:r b:r → w` | flag := (b == 0) ∨ (signed ∧ a == MIN ∧ b == −1); under flag: `fault FAULT_UB_DIV0` / `FAULT_UB_SDIV_OVERFLOW`; under ¬flag: result |
| `lift.icmp` | `lift.icmp.{pred} a:r b:r → w:reg[1]` | |
| `lift.select` | `lift.select p:r a:r b:r → w` | |
| `lift.cast` | `lift.{zext,sext,trunc} a:r → w` | |
| `lift.mov` | `lift.mov a:r → w` | copy (used for block parameters) |
| `lift.load` | `lift.load.W region a:r → w` | `qload` from the named quantum memory region at the little-endian address in `a`; the producer MUST precede it by an explicit range check (`lift.icmp` + `lift.faultif`) against the declared allocation, so out-of-range accesses fault with `FAULT_UB_MEMFAULT`; the raw `qload` is total (§4.6) |
| `lift.store` | `lift.store.W region a:r v:r` | copy `v` into the displaced slot, then `qexchm region a slot`: the cell takes `v`, the slot takes the old cell value; range check as for load |
| `lift.alloc` | `lift.alloc n:r → w:reg[ptr]` | flag := (heap_used + n > heap_limit); under flag: `fault FAULT_BUDGET_HEAP`; under ¬flag: `w := heap_base + heap_used` and `heap_used := heap_used + n` (two locations change: `heap_used`'s old value goes to the slot's upper half; frame layout accommodates this) |
| `lift.free` | `lift.free p:r` | validates only; bump allocation is rewound by the reversal |
| `lift.faultif` | `lift.faultif p:r code:c` | under `p`: `fault code` |
| `lift.call` | `lift.call k:c` | flag := (depth + 1 > depth_limit); under flag: `fault FAULT_BUDGET_DEPTH`; under ¬flag: push the return index onto the `stack` region at `sp`, `sp := sp + 1`, `depth := depth + 1`, next pc := k |
| `lift.ret` | `lift.ret` | pop: `sp := sp − 1`, `depth := depth − 1`, next pc := popped index (via the step's `qjumpr` behaviour) |
| `lift.retval` | `lift.retval v:r` | `result := v`; next pc := HALT |
| `lift.oracle_call` | `lift.oracle_call @o ins:r… tgt:w fr:w tk:token` | one outer step; runs the nested oracle (§5.5) under its own budget token; `fr` is a caller-allocated location that MUST be clean before the call |
| `lift.perm_call` | `lift.perm_call @a mut:w… ins:r…` | one outer step; calls a **permutation action** (§5.3) |

Control instructions of oracle bodies: `qjump k:c`, `qbranch p:r k1:c
k2:c`, `qjumpr a:r` (indirect, for `lift.ret`), `fault code:c` (§4.6).
Producers MUST inline non-recursive calls; recursive calls use
`lift.call`/`lift.ret`. **Budget steps:** every lifted or control
instruction executed on a basis branch is one step; callee instructions
count individually; `lift.oracle_call` and `lift.perm_call` count one.

**Reference binding.** The dialect's reference semantics maps each
materialised source instruction to exactly one lifted instruction (plus
edge `lift.mov`s for block parameters), and that mapping is versioned.
Hence the fault set of an oracle depends only on (program, budget,
dialect-mapping version, and the producer's materialisation inputs
recorded in the certificate), never on an executor's lowering.

### 4.3 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `qalloc class:c n:c → w:produce wire[n]` | n clean wires of class `class` (§8.2) or `any`. Unconditional (§3.5). |
| `qborrow` | `qborrow class:c n:c → w:produce wire[n]` | n wires in an unknown state, possibly entangled with external systems. The region MUST act as the identity on them (§5.6). |
| `qfree` | `qfree w:consume wire[n]` | release. Clean for `qalloc`ed wires; simulators MUST check, hardware MAY trust the certificate. |

### 4.4 Gates

Matrices in the computational basis, |0⟩ = (1,0)ᵀ, bundle ordering
little-endian (wire 0 is the least-significant tensor factor). θ is a
classical `f64` in radians, fixed at region entry.

```
  x    = [[0,1],[1,0]]             h   = (1/√2)[[1,1],[1,-1]]
  s    = diag(1, i)                sdg = diag(1, -i)
  t    = diag(1, e^{iπ/4})         tdg = diag(1, e^{-iπ/4})
  rx(θ) = exp(-iθX/2) = [[cos θ/2, -i sin θ/2], [-i sin θ/2, cos θ/2]]
  ry(θ) = exp(-iθY/2) = [[cos θ/2, -sin θ/2], [sin θ/2, cos θ/2]]
  rz(θ) = exp(-iθZ/2) = diag(e^{-iθ/2}, e^{iθ/2})
  cx, ccx, mcx(k): X on the target iff every control is |1⟩, identity otherwise (exact, no phase)
  cz   = diag(1,1,1,-1)            swap = exact exchange of two wires
```

Forms: `x a:in`, `cx c:in t:in`, `ccx c1 c2 t`, `mcx cs:in wire[k] t:in`,
`swap a b`, `h a`, `s a`, `sdg a`, `t a`, `tdg a`, `cz a b`, `rx θ a`,
`ry θ a`, `rz θ a`. All execute controlled on the active predicate.

**Decomposition legality.** A target realises a gate either natively or
through a declared decomposition (§8.3). A decomposition is conformant
only if its realised unitary **equals the specified unitary exactly,
including global phase** (because every gate may run under control,
where a global phase is observable), or lies within a stated ε of it in
**operator norm** (which is phase-sensitive and preserved under adding
controls). A relative-phase Toffoli is therefore not a conformant
realisation of `ccx` unless a certificate (§12) proves the phase cancels
in the specific context in which it is used.

### 4.5 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `qcopy s:in wire[n] → d:produce wire[n]` | allocate d clean (unconditional), then `cx s_i d_i` under the predicate. |
| `quncopy` | `quncopy s:in wire[n] d:consume wire[n]` | the inverse: `cx s_i d_i` under the predicate, then `qfree d` (d MUST be clean on every basis configuration; this is the explicit cleanup of a `qcopy`). |
| `qxor` | `qxor s:in wire[n] t:in wire[n]` | t_i ^= s_i |
| `qexch` | `qexch a:in wire[n] b:in wire[n]` | n `swap` |
| `qinplace` | `qinplace @g @ginv x:in wire[n] tk:token` | **WF:** `@g`, `@ginv` are **total permutation oracles** (§5.2) on the n-bit encoding: their certificates (§12) state that on every basis input of the encoding, under their declared budgets, the fault code is `FAULT_NONE` and `g∘ginv = ginv∘g = id`, checked exhaustively where the width makes that finite and otherwise carried as a library certificate. **Sem:** `t = qalloc n; f = qalloc F; lift-free: oracle_call @g (x) t f tk; qexch x t; oracle_call @ginv (x) t f tk; qfree t; qfree f`. After the second call `t` is clean because `ginv(g(x)) ⊕ g(x)`… precisely: `t` held g(x₀), is exchanged so x holds g(x₀) and t holds x₀, and `ginv(g(x₀)) = x₀` XORed into t clears it. `f` stays clean by the certificate. |

### 4.6 Quantum memory, predication, structure, faults

| Instruction | Form | Rules |
|---|---|---|
| `qregion` | `qregion name A:c W:c [image]` | declares a region of exactly 2^A cells of `wire[W]`; created at region entry from the object's **data image** for `name` (classical bytes, little-endian per cell, default all zero) by X gates; MUST be returned to its image at exit (the producer emits the inverse). |
| `qload` | `qload name a:in wire[A] → d:produce wire[W]` | d clean; for every cell i: under `a == i`, `qxor cell_i d`. Total: every address names a cell. |
| `qstore` | `qstore name a:in wire[A] v:in wire[W]` | for every i: under `a == i`, `qxor v cell_i`. |
| `qexchm` | `qexchm name a:in wire[A] v:in wire[W]` | for every i: under `a == i`, `qexch v cell_i`. |
| `qunload` | `qunload name a:in wire[A] d:consume wire[W]` | inverse of `qload` (XOR back, then `qfree d`). |
| `qpred` / `qunpred` | `qpred w:in` / `qunpred w:in` | §3.5; nested; `w` MUST NOT be modified between push and pop. |
| `qif` | `qif w:in { then } { else }` | `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w`. Neither arm modifies `w`. |
| `qloop` | `qloop n:c { body }` ; `qloop n:c while c:in { body }` | body n times. With `while`: fresh flags c₁..cₙ are allocated; c₁ = c; c_{i+1} = c_i ∧ cond_i is computed out of place (`ccx`) after iteration i, where cond_i is a **permutation-provenance** wire (§6) of wires no iteration modifies; iteration i runs under `qpred c_i`; after the loop the flags are uncomputed in reverse order. Any other data-dependent exit in an action is ill-formed. |
| `fault` | `fault code:c` | oracle bodies only. Under the active predicate: XOR `code` into the internal `code` register, `x faulted`, next pc := HALT. Because the halted branch then self-loops, the first fault on a branch is the only fault on that branch; no zero test is needed and the operation is injective. |
| `budget` | `budget steps:c heap:c depth:c → tk:token` | classical. |

### 4.7 Region calls (structured code and CC)

| Instruction | Form |
|---|---|
| `oracle_call` | `oracle_call @o tk:token ins:in wire[*]… tgt:in wire[T] fr:in wire[F] args:c…` |
| `action_call` | `action_call @a mut:in wire[*]… ins:in wire[*]… args:c…` |
| `adj` | `adj action_call …` (§5.3); `adj oracle_call …` ≡ `oracle_call …` |
| `ctl` | `ctl w:in <call>` ≡ `qpred w; <call>; qunpred w` for calls; for a whole action the controlled unitary of §5.3 |

## 5. Regions

### 5.1 Common well-formedness

A region MUST NOT contain `measure`, `effect`, `br`, `call`, `uncall`,
`trap`, or classical memory instructions. Its predicate stack is empty at
entry and exit. Every `qalloc`ed wire is `qfree`d clean before exit by
**explicit cleanup instructions in the program text** (`quncopy`,
`qunload`, the adjoint of the computing sequence, or, in oracles, the
prefix reversal); the schedule (§11) chooses only the *realisation* of
each cleanup. Every `qborrow`ed bundle is returned to the identity (§5.6).
Every quantum memory region is returned to its image. **Action call
graphs MUST be acyclic**; oracles MAY be recursive only through
`lift.call` under the depth budget.

### 5.2 Lifted oracle

**Interface.** `oracle @o (ins: wire[*]…, tgt: wire[T], fr: wire[F], args: c…) regs {…} heap H stack S`.

**Body.** Lifted and control instructions only (§4.2), plus the implicit
machine of §3.6. **Permutation-only:** no gate other than the permutation
gates ever executes in an oracle body or in anything it calls; `lift.
perm_call` targets MUST be permutation actions (§5.3). Suite F rejects
anything else; a region that needs a non-permutation gate is an action.

**Contract.** On every basis configuration:

- `ins` final = `ins` initial (inputs are only read).
- `tgt` final = `tgt` initial ⊕ payload(F_B(x)).
- `fr` final = `fr` initial ⊕ code(F_B(x)).
- borrowed bundles: identity; all workspace, registers, memory regions
  and step state: clean / at image.

**F_B(x)** is defined by the reference interpreter (§14.1) run on the
body with budget B from basis input x: `(f(x), FAULT_NONE)` if it reaches
`lift.retval` within B steps without a fault, else `(0, code)` where
`code` is the first fault encountered in sequential order, or
`FAULT_BUDGET_STEPS` if it has not halted after B steps. Both halves are
XORs, so the oracle is an **involution** on `(ins, tgt, fr)`, equal to
its own adjoint, composing under control by XOR accumulation.

**Construction** (what an executor runs; T6 fixes every executor to it):

1. Allocate step state, register file, regions, B frames (all clean);
   `qcopy` each input into its location; apply the data images.
2. Run B machine steps (§3.6).
3. **Commit.** Compute `at_HALT = (pc == HALT)` into scratch. Under
   `at_HALT ∧ ¬faulted`: `qxor result tgt`. Under `faulted`: `qxor code
   fr`. Under `¬at_HALT`: XOR the constant `FAULT_BUDGET_STEPS` into `fr`
   (X gates controlled on `¬at_HALT`). The three cases are exclusive
   because `fault` jumps to HALT. Uncompute `at_HALT`.
4. **Prefix reversal.** Run the inverse of step 2 and step 1. The commit
   writes to `tgt` and `fr` are **not** reversed (they are outside the
   reversed prefix); everything else returns to clean.

**Domain D** (suite C): every value of each `ins`, of `tgt`, of `fr`, of
every borrowed bundle; `qalloc`ed wires at 0; regions at image.

### 5.3 Quantum action

**Interface.** `action @a (mut: wire[*]…, ins: wire[*]…, args: c…)`.

**Semantics.** The body denotes a unitary U_a on mut ⊗ ins ⊗ (borrowed)
that is **block-diagonal in the computational basis of `ins`** (the basis
value of every `ins` wire is unchanged; phases and entanglement between
`ins` and `mut` are part of U_a and are the action's declared behaviour),
acts as the **identity on borrowed systems** (§5.6), and returns all
workspace clean and unentangled. An action has no fault outcome of its
own; a fallible computation it needs is an `oracle_call` whose `fr` it
declares among its `mut` wires. An action whose body contains coherent
internal control (`qif`, `qloop while`) is, by definition, its padded
unitary under its declared bounds, and **those bounds are part of its
content identity** (§9.2).

**Body.** Structured: gates, `qcopy`/`quncopy`/`qxor`/`qexch`, `qload`/
`qunload`/`qstore`/`qexchm`, `qpred`/`qunpred`/`qif`/`qloop`,
`qinplace`, `oracle_call`, `action_call`, `qalloc`/`qborrow`/`qfree`.

**Permutation action.** An action whose body uses only permutation gates
(transitively). Its unitary is a permutation; it is the only kind of
action an oracle may call (`lift.perm_call`), and suite C verifies it by
the basis-tuple check over its declared permutation.

**Adjoint.** `adj @a` is the body in reverse order with each instruction
replaced by its adjoint per this table, and SSA names renamed
accordingly; the adjoint of a well-formed action is well-formed by
construction of the table:

```
  gate g(θ)        ↦ g(−θ) ; s↔sdg ; t↔tdg ; x,cx,ccx,mcx,swap,h,cz self-adjoint
  qalloc            ↦ qfree           qfree ↦ qalloc        qborrow ↦ qfree (restore ⇒ identity)
  qcopy             ↦ quncopy         quncopy ↦ qcopy       qload ↦ qunload      qunload ↦ qload
  qxor, qexch, qstore, qexchm           self-adjoint
  qinplace g ginv   ↦ qinplace ginv g
  oracle_call       ↦ oracle_call (involution)
  action_call @b    ↦ adj action_call @b
  qpred/qunpred     ↦ qunpred/qpred (the pair is reversed as a whole)
  qif w {A}{B}      ↦ qif w {adj A}{adj B}        qloop n {A} ↦ qloop n {adj A}
  qloop n while c   ↦ the flags are recomputed forward, the body adjointed under them, flags uncomputed
```

**Control.** `ctl w @a` is controlled-U_a: workspace is allocated
unconditionally, every gate of the body runs under `w` in addition to
the active predicate, cleanup runs under `w` too, so on `w = 0` the body
is the identity and all workspace is trivially clean.

### 5.4 Budgets and fault codes

Budget `(steps B, heap limit, depth limit)` is classical. B is enforced
by the machine running exactly B steps on every branch. Heap and depth
are **wire counters** `heap_used`, `depth` in the step state, updated by
`lift.alloc`/`lift.call`/`lift.ret`, compared against the classical
limits, raising faults. When two faults would trip on one instruction,
the order is: depth, then heap, then the instruction's own fault.

Fault codes (values **normative**; F ≥ 4):

```
  0 FAULT_NONE                 5 FAULT_UB_DIV0
  1 FAULT_BUDGET_STEPS         6 FAULT_UB_SDIV_OVERFLOW
  2 FAULT_BUDGET_HEAP          7 FAULT_UB_MEMFAULT
  3 FAULT_BUDGET_DEPTH         8 FAULT_EFFECT_UNMODELLED
  4 FAULT_UB_TRAP              9 FAULT_CALLEE
```

### 5.5 Nesting and nested faults

A `lift.oracle_call` inside an oracle supplies a **caller-allocated,
clean** location `fr'` for the nested fault register and a budget token
from the caller's classical args. There is **no automatic propagation**.
Fault handling is ordinary lifted code the producer emits: `lift.icmp.ne
fr' 0 → p; lift.faultif p FAULT_CALLEE`, after which `fr'` is either
retained as declared data or cleared by calling the nested oracle a
second time (involution). The nested call is one outer step; its own
steps are its own budget.

### 5.6 Borrowed systems, prefix reversal, exit synchronisation

**Borrowed systems.** A region's completed operation MUST equal its
declared operation ⊗ identity on every borrowed bundle **and on any
external system entangled with it**. Basis-value restoration is not
sufficient in general (an `s` on a borrowed wire preserves every basis
value and changes |+⟩). The discipline: borrowed wires may be acted on
**only by permutation gates**, as controls or targets, and MUST be
returned to their initial basis value on every basis configuration; by
T3 over the extended domain D this yields exactly identity on them. In
actions, borrowed wires additionally MUST NOT be controls of non-
permutation gates (that would entangle them). Legitimate correlations
among the region's own public inputs and outputs are not restricted.

**Prefix reversal** (oracles). Step 4 of §5.2 restores every non-interface
wire on every basis configuration, faulted or not, because the forward
prefix is a permutation and is inverted exactly.

**Exit synchronisation** (oracles). Every basis branch has executed
exactly B machine steps at commit; branches differ in `pc` and data until
the reversal, and the reversal returns all control workspace to clean.

### 5.7 Structure recovery

A specialiser MAY replace step-machine execution of an oracle body, or
part of it, by `qif`/`qloop` structures when it can prove the CFG
structured and the bounds static. The replacement MUST produce, on every
basis configuration in D, the same final interface tuple as §5.2's
construction (T6); suite C tests both forms against the reference
interpreter.

## 6. Uncomputation validity *(static discipline; Silq's `qfree`/`const`, Unqomp)*

Every workspace wire has a **provenance**: `perm` (computed from its
**dependency set** S, a set of wires, by permutation gates only, with S
used as controls or XOR sources) or `other`.

**Transfer rules** (computed statically over immutable value versions;
suite F checks them): `qcopy s → d`: perm, S = {s}. `qload r a → d`: perm,
S = {a} ∪ cells(r). `qxor s t`: t's provenance becomes `other` unless t
was perm with S ⊇ {s} ∪ S_t, in which case it stays perm with S ∪ S_s.
`qexch`: provenances swap. A permutation gate with controls C and target
t: t stays perm with S_t ∪ C ∪ ⋃S_c. A diagonal gate on a wire: unchanged
provenance. A non-diagonal gate on a wire: `other`. `measure`: n/a in
regions.

**Window.** A perm value g with dependency set S may be cleaned by
reversal (`quncopy`, `qunload`, the inverse sequence) or by recomputation
**only while**, since its computation: (a) every operation touching S has
used S only as controls, or been diagonal on S, or been a permutation of
S that was exactly undone again before the cleanup; and (b) g's own wires
have been used only as controls or by diagonal gates. Any other operation
on S or on g **closes the window**.

**Obligations.** Every perm value MUST be cleaned before its window would
close, and before the end of its region. A value whose window has closed
can be cleaned only by **measurement-based uncomputation with phase
fixup**, which is permitted **only** when the predicate stack is empty,
the target declares `mbu: true`, and the fixup is computed for the actual
schedule (after an intervening U the correction D becomes U D U†); it is
an executor-internal realisation verified by suite D, never an
instruction. Under any active predicate, unitary cleanup is mandatory
(the north star's fallback until a controlled-MBU certificate kind
exists). An `other` value is released only by the adjoint of the action
that produced it. A region in which some value has no valid cleanup is
ill-formed (suite F).

**Schedulers** choose only among realisations satisfying this section.

## 7. Memory and effects

### 7.1 Classical memory (CC, R)

Byte-addressed, little-endian, sparse; `alloc` is a bump allocator with
per-allocation bounds metadata used by CC traps and R fault records for
out-of-bounds access.

### 7.2 Quantum memory

`qregion name A W [image]` as §4.6; exactly 2^A cells; data image in the
object (§9.1). Lifted classical memory of an oracle is laid out by the
producer into regions (`heap` of size 2^H bytes for `lift.alloc`, `stack`
for return indices, and one region per source allocation class), recorded
in the object's `layout` section. Cost of an access is linear in the
region size unless the target declares `qram` (§8.3).

### 7.3 Effects and device models (R)

`effect dev op args → results`. Device models in this draft, each with
state, operations and inverse deltas:

| Device | State | Operations | Reversal |
|---|---|---|---|
| `console` | byte sequence | `write(bytes)` | pop the bytes |
| `clock` | counter `c` | `read() → c`; the counter advances by 1 per tape record | restore `c` |
| `entropy` | position in the **entropy tape** supplied at launch | `read(n) → bytes` consumed in order; exhaustion is an R fault record | rewind the position |
| `block` | sector map | `read(sector) → bytes`; `write(sector, bytes)` (records the overwritten bytes) | restore sectors |

A run of an R function is therefore a function of (program, initial
state, entropy tape). Each `effect` appends `(dev, op, args, results,
delta)` to the effect tape; reversal pops and applies the inverse delta.
Reversal restores device-model state; it does not and cannot retract an
external observation of the console, which is why the coherent tier
forbids effects.

### 7.4 R history rules

| Instruction | History frame records |
|---|---|
| `store` | address, width, overwritten bytes |
| lossy binops (`mul` with overflow, `and`, `or`, shifts, `udiv`…), `trunc`, `select` | the destroyed operand(s) |
| `br p …` | the taken edge |
| `alloc` / `free` | old bump pointer |
| `call` / `ret` | frame link |
| `effect` | pointer to the tape record |
| `load`, `const`, `add`, `sub`, `xor`, `icmp`, `zext`, `sext` | nothing (invertible from the result and the retained operands, which SSA keeps live) |
| fault record (`udiv` by 0, trap, out-of-bounds) | the fault cause and location; execution halts in a **terminal faulted state** that `uncall` reverses like any other prefix |

## 8. Resources and target descriptions

### 8.1 Resources and aggregation

A target declares resources, each with a **kind** that fixes how usage is
aggregated:

```
  kind count      : summed over instructions (e.g. t, cx, measurement)
  kind time       : the schedule makespan in seconds
  kind occupancy  : ∫ (live qubits of a class) dt, in qubit-seconds
  kind peak       : max over time (e.g. peak live qubits per class)
```

Every target MUST declare `qubit_second` (occupancy) per class, `time`,
and `peak_qubits` per class. **Timing model:** execution is sequential in
program order unless the schedule (§11) assigns start times; a gate
occupies its wires for its declared `time`; gates on disjoint wires MAY
overlap unless the target declares `max_parallel` or a topology; the
ISA-level machine is all-to-all over logical wires, with routing folded
into the target's decomposition costs. A wire's lifetime runs from
`qalloc`/`qborrow` to `qfree`; `qubit_second = Σ_wires lifetime × rate`,
borrowed wires charged **to the borrower at the class's `dirty_rate`,
replacing** the owner's charge for that interval. Dispatch, history,
reversal and cleanup are ordinary instructions in the lowered program and
are therefore counted like any other.

### 8.2 Qubit classes

```
  classes:
    <name>: { qubit_second: <rate>, dirty_rate: <rate>, capacity: <int | unbounded> }
```

`any` resolves to the class with the lowest `qubit_second` whose
`capacity` is not exhausted in the schedule. Two-wire gates across
classes are permitted; their cost is the declared `cross_class` cost if
present, else the costlier class's cost.

### 8.3 Gate alphabet, decompositions, capabilities

```
  ptr_width: <bits>
  gates:
    <gate>: { <resource>: <cost | fn(k) | fn(ε)>, ..., time: <seconds | fn(...)> }
  decompositions:
    <gate>: { sequence: [...native gates...], epsilon: <0 | bound in operator norm> }
  capabilities:
    qram: none | { load: <cost vector>, store: <cost vector>, exch: <cost vector> }
    measurement: { mid_circuit: bool, feedforward_latency: <seconds> }
    mbu: bool
    max_parallel: <int | unbounded>
    max_predicate_depth: <int | unbounded>
  cross_class: { <classA>,<classB>: <cost vector> }      # optional
```

`mcx` cost is a declared function of k; `rz`/`rx`/`ry` cost a declared
function of the synthesis ε the schedule assigns. A gate neither native
nor decomposable is a load-time error.

### 8.4 Objective and space budget

```
  objective: weighted { <resource>: <weight>, ... } | lexicographic [ <resource>, ... ]
```

The scheduler minimises the objective. The **space budget** passed to the
scheduler is a peak-capacity bound per class (`peak_qubits`), separate
from `qubit_second`.

### 8.5 Importing existing models

A target description MAY be generated from a Qualtran or Azure-RE model:
units aligning with a declared resource are converted; others become new
named resources of the appropriate kind.

## 9. Objects, linking, reversible ABI

### 9.1 Object sections (canonical text, §16)

```
  header      versions (isa, object, launch, sched, cert, coverage); producer id; target hint
  types       bundle widths; qregion declarations
  symbols     local index → (name, kind: cc|r|oracle|action|perm_action|data, signature, content_hash)
  imports     (name, signature, [pinned content_hash])
  functions   per local index: tier, interface, regs, body
  data        data images for qregions
  devices     device models referenced by R code
  layout      producer's mapping of lifted classical memory to qregions
  schedule    optional: a serialised §11 schedule bound to a target hash
  certificate §12
  coverage    §13
```

### 9.2 Identity and linking

**Content hash** is the sole global identity: SHA-256 over the canonical
bytes of a symbol's `signature` and `body` (for `data`, over the image;
for actions, including declared bounds), with references to other
symbols replaced by their content hashes; a strongly connected component
of mutually recursive symbols is hashed as one unit in canonical order.
Local indices are per-object aliases rewritten at link.

**Signature** = (tier, kind, wire-bundle widths in order, T, F, classical
argument types, ABI version). **Imports** resolve by name + signature,
with a link error on mismatch; a pinned hash additionally requires
equality; the resolved hash is recorded in the linked certificate. Two
definitions with equal hash deduplicate; unequal hashes under one name
are a link error; conflicting `types`/`devices`/`layout` entries are link
errors. Linking is resolution, validation, then composition of
certificates (§12), not a union of tables.

### 9.3 Reversible ABI

- **CC/R calls:** classical frame; the callee's R history frame is pushed
  on the caller's R history stack at `call` and popped by `uncall`, which
  consumes exactly that frame. `uncall @f` is well-formed only where the
  matching `call @f` is the most recent unreversed call on the current
  history stack.
- **Region calls:** the caller passes interface bundles in declared order
  and owns them; the callee owns its workspace and returns it clean. A
  callee MAY `qborrow` only from a caller-designated idle set, which it
  restores (§5.6).
- **Frame descriptors.** Every region's certificate carries a frame
  descriptor: typed interface slots, scratch requirement by class and
  cleanliness (clean / dirty-restorable), retained-history requirement
  (oracles: B × frame width), and ownership transitions. A caller MAY
  pass a **shared frame** of at least the descriptor's clean scratch only
  when the caller's own live values and history are disjoint from it for
  the duration of the call (suite F checks live ranges); reuse is never
  inferred from a peak count alone.
- **Controlled and adjoint variants** of a region use the same descriptor.

## 10. Launch ABI (host ↔ device)

**Model.** The launch entry point is a **device CC function**. The host
supplies classical arguments, budgets, and opaque register IDs naming
device-resident quantum state that persists between launches; it receives
classical results, fault codes and read-back measurements. Every
measurement whose result affects control runs in device CC. Host code
never holds a wire.

```c
  // launch 0.2 — C ABI; every function returns bennett_status (0 = ok, else an error code below)
  bennett_status bennett_load     (const uint8_t* object, size_t len, const char* target_id, bennett_program** out);
  bennett_status bennett_unload   (bennett_program*);
  bennett_status bennett_budget   (bennett_program*, const char* region, uint64_t steps, uint64_t heap, uint64_t depth, bennett_token* out);
  bennett_status bennett_qreg_new (bennett_program*, const char* cls, uint32_t n, bennett_qreg* out);   // clean |0…0⟩
  bennett_status bennett_qreg_prepare(bennett_program*, bennett_qreg, const uint8_t* bits);              // X gates on a clean register
  bennett_status bennett_qreg_free(bennett_program*, bennett_qreg);                                      // must be clean
  bennett_status bennett_run      (bennett_program*, const char* cc_entry, const bennett_arg* args, size_t nargs, bennett_run_id* out);
  bennett_status bennett_wait     (bennett_program*, bennett_run_id, bennett_result* out);                // classical results, fault codes, measurements
  bennett_status bennett_suspend  (bennett_program*, bennett_run_id);   // only at CC instruction boundaries, never inside a region
  bennett_status bennett_resume   (bennett_program*, bennett_run_id);
  bennett_status bennett_reverse  (bennett_program*, bennett_run_id);   // R: uncall to entry. Q action: U† with retained args. Q oracle: re-apply (involution).
  bennett_status bennett_tape     (bennett_program*, bennett_run_id, bennett_tape_iter* out);
  bennett_status bennett_estimate (bennett_program*, const char* region, bennett_token, const char* target_id, bennett_estimate_out* out); // no execution
  bennett_status bennett_coverage (bennett_program*, bennett_coverage_out* out);
  // errors: BENNETT_E_VERSION, _E_DEVICE_MISSING, _E_GATE_UNSUPPORTED, _E_TARGET, _E_BUDGET, _E_QREG_NOT_CLEAN, _E_INVALID_STATE, _E_SCHEDULE_INFEASIBLE
```

`bennett_run` returns an invocation id; `bennett_wait` yields results.
`bennett_reverse` on a run that invoked Q regions re-invokes them as
stated (oracles are involutions; actions run their adjoint with the
retained classical arguments and the same live registers); it is an
error (`_E_INVALID_STATE`) if those registers have been modified since.

## 11. Scheduling interface

```c
  // sched 0.2 — C ABI
  bennett_status bennett_sched_schedule(const bennett_sched_request* req, bennett_sched_response* out);
  // request: program content hash, region, target hash, objective, budget token, accuracy ε_total,
  //          capacity (peak per class), classical parameters, scheduler version
  // response: SCHEDULED | INFEASIBLE(reason) | UNSUPPORTED(feature); on SCHEDULED a serialised schedule + certificate (§12)
```

**Schedule** (serialised; may be stored in the object's `schedule`
section bound to the target hash): per cleanup, its realisation (reverse
| recompute | mbu); per allocation, its class; per gate, the decomposition
chosen and, for rotations, its ε share; start times where the schedule
parallelises; structure-recovery decisions; checkpoint and recomputation
points for R history.

**Obligations.** Every schedule MUST satisfy §6, MUST respect the capacity
bound, MUST report the full resource vector, MUST be reproducible from
the request plus scheduler version. A consumer (VM or specialiser) MUST
validate a stored schedule's bindings (program hash, target hash, budget,
ε) and either execute it **verbatim** or reject it and request a
replacement; it MUST NOT alter program semantics either way. The VM uses
the same interface at run time with the run-time budget in the request,
so its decisions depend only on classical data.

## 12. Certificate schema (machine-readable; JSON object; cert 0.2)

```
  versions:      { isa, object, launch, sched, cert, coverage }
  bindings:      { object_hash, reference_program_hash, dialect_mapping_version, target_hash, schedule_hash? }
  producer:      { name, version, materialisation: { llvm_version, pipeline, normaliser_version } }
  objective:     <as §8.4>
  regions: { <content_hash>: {
      kind:           oracle | action | perm_action
      signature:      <as §9.2>
      bounds:         { steps, heap, depth } | { action bounds }
      frame:          <frame descriptor, §9.3>
      resources:      { <resource>: <value> ... }                     # aggregated per §8.1
      gates_used:     { <gate>: { count, decomposition_hash?, epsilon? } }
      verification: {
        permutation:  { domain: <finite-domain encoding: widths and ranges per interface bundle>,
                        method: exhaustive | sampled, count, sampler: { algorithm, version, seed }, result: proof | evidence }
        channel:      { widths, metric: diamond | operator_norm, epsilon, numerical_bound: { method, bound }, result: proof | evidence }
        fault_rate:   { domain, faults: <count by code>, undefined_excluded, layout_dependent_excluded }
        inverse_pairs:[ { g, ginv, domain, method, result } ]
        borrowed:     { discipline_checked: bool, domain }
        minimality:   none | { lower_bound: { method, value }, witness_hash }
      }
      definedness_assumption: <structured: list of assumption ids from the dialect spec>
  } }
  composition:   { invocation_multiplicities: { <hash>: n }, epsilon_total: Σ n·ε, method }
```

A checker MUST validate every `proof` entry by re-execution at the stated
widths (permutation) or by re-computing the numerical bound (channel)
without trusting the producer; `evidence` entries are replayable from
`sampler`. Epsilons compose over **invocation multiplicities** (how many
times each region executes under the bounds), not over linked symbols.

## 13. Coverage report (coverage 0.2)

Per object, per function, per source construct: `{ location: <stable
reference-program location>, classification: lowered | trapped |
shimmed, reason, fault_code (trapped), shim: <bennett-runtimes symbol
hash> (shimmed), count }`.

## 14. Formal model

### 14.1 Reference interpreter *(normative)*

A sequential interpreter over oracle bodies executing **per basis
configuration**: register-file locations are bit-vectors, predication is
an `if`, lifted instructions are their classical functions, `fault`
records the code and stops, `lift.retval` stops with success, the step
counter counts executed instructions, `heap_used` and `depth` are
integers. It **defines** F_B and the budget unit. It rejects any non-
permutation gate (such a body is not an oracle).

### 14.2 Quantum state semantics *(normative)*

The state of a Q region is a vector in the Hilbert space ⊗ over live
wires in allocation order (bundles little-endian), together with the
classical budget counters. `qalloc` tensors |0⟩ factors; `qfree` of a
clean wire removes a |0⟩ factor; gates act by the matrices of §4.4,
controlled on the active predicate; `qborrow` introduces a factor in an
unknown state possibly entangled with a reference system R, and the
region's operation MUST be U ⊗ I_R with U acting as identity on the
borrowed factor (§5.6). `measure` (CC) applies the computational-basis
projective measurement with Born probabilities, yielding the little-
endian integer and consuming the wires.

### 14.3 Theorems (hypotheses explicit)

- **T1 (totality, determinism).** For every well-formed oracle, budget,
  and basis configuration x ∈ D, the reference interpreter terminates
  within B + 1 steps and F_B(x) is unique; `code` is the first fault in
  sequential order.
- **T2 (prefix reversal).** For every executor whose oracle realisation
  is a composition of permutation gates implementing §5.2 steps 1–4 (any
  decomposition whose realised unitary is exactly a permutation), on
  every x ∈ D every non-interface wire is clean after step 4 and every
  borrowed bundle holds its initial value. *(Proof sketch: steps 1–2 form
  a permutation Π; step 3 acts only on tgt and fr controlled on
  workspace; step 4 applies Π⁻¹; Π⁻¹Π = I on workspace.)*
- **T3 (permutation theorem).** If the realised unitary V of a region on
  span(D) is a permutation matrix (however decomposed), and for every x ∈
  D the final basis tuple equals P(x) for the declared permutation P
  (the oracle tuple of §5.2, or |g(x)⟩ with workspace clean for a
  permutation action), then V|span(D) = P: no relative phase, no residual
  entanglement, identity on borrowed systems.
- **T4 (round trip, R).** For every finite valid R trace with retained
  history and tape, `uncall` returns classical state, memory, device-
  model state and history to their entry values; observed external
  events are not retracted.
- **T5 (validity ⇒ cleanliness).** Under §6, a perm value cleaned within
  its window by reversal or recomputation returns exactly to |0⟩ and
  leaves the remaining state unchanged.
- **T6 (executor agreement).** Two executors conforming to §3–§7 on the
  same target with the same decompositions produce, on every x ∈ D, the
  same final tuple for every oracle (exact equality), and for every
  action unitaries within ε₁ + ε₂ in operator norm (channels: diamond
  norm) where ε_i are their certificates' totals composed over invocation
  multiplicities.

### 14.4 Mechanisation *(deferred)*

A machine-checked model of §3.6, §5.2, §5.3 (adjoint table) and §6 at
the abstract level (bits for oracles; matrices for actions at small
widths).

## 15. Conformance suites

| Suite | Class | Tests |
|---|---|---|
| A | Executor | classical ISA exhaustive at narrow widths, property-based above; R round trip (T4) with tape and entropy tape; R fault records |
| B | Executor | oracle totality and prefix reversal (T1, T2): bodies with every fault code, budget boundaries (B = 0, exact-boundary halt), nested oracle faults, borrowed restoration; faulted and non-faulted configurations |
| C | Executor, Producer | T3 over full D at exhaustive widths for oracles, permutation actions, `qinplace` pairs; T6 agreement among VM, specialiser, structure-recovered forms and the reference interpreter |
| D | Executor | channel comparison (Choi state with reference system) for non-permutation decompositions and MBU realisations; controlled-interference tests; ε accounting against the numerical bound method |
| E | Target author, Executor | resource aggregation per kind against declared units; timing model; objective evaluation; decomposition exactness or ε; cross-class costs |
| F | Producer | linearity in structured code; register-file write-once-per-step; predicate nesting; permutation-only oracle bodies; §6 transfer rules and schedulability; adjoint table; acyclic action graphs; object grammar; linking rules; frame-descriptor live-range checks |
| G | Launch | every §10 entry point; suspend/resume at CC boundaries only; reverse semantics per tier; error codes |
| H | Scheduler | returned schedules satisfy §6 and capacity; reproducibility; stored-schedule validation and verbatim execution |

## 16. Canonical textual form (normative grammar)

```
  object    := header section*
  header    := "bennett-object" version-list NEWLINE
  section   := "section" NAME NEWLINE line*
  function  := ("fn" TIER | "oracle" | "action" | "perm_action") NAME "(" params ")" attrs? NEWLINE block+
  params    := (param ("," param)*)?
  param     := NAME ":" type
  type      := "i" INT | "ptr" | "f64" | "wire" | "wire[" INT "]" | "reg[" INT "]" | "token"
  attrs     := "regs" "{" (NAME ":" type ("," NAME ":" type)*)? "}" ("heap" INT)? ("stack" INT)? ("bounds" "{" INT ("," INT)* "}")?
  block     := "^" NAME "(" params ")" ":" NEWLINE instr+
  instr     := (results "=")? OPCODE operand* ("{" NEWLINE instr+ "}" ("{" NEWLINE instr+ "}")?)? NEWLINE
  results   := NAME ("," NAME)*
  operand   := NAME | "@" NAME | "^" NAME ("(" (NAME ("," NAME)*)? ")")? | INT | FLOAT | STRING
  version-list := NAME "=" INT "." INT ("," NAME "=" INT "." INT)*
```

Whitespace: one instruction per line, single spaces between tokens, no
trailing spaces, LF line endings, UTF-8; integers decimal; floats in the
shortest round-trip representation; names `[A-Za-z_][A-Za-z0-9_.]*`.
These rules make the canonical bytes unique, so content hashes (§9.2)
are well-defined. A binary encoding *(deferred)* MUST round-trip through
this form. An executor MUST refuse an object whose ISA major differs
from its own and MAY accept a lower minor.

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding.
2. Gate-name registry process.
3. Device models beyond the four of §7.3.
4. Mechanisation of §14.
5. The exact bit layout of `bennett_arg`, `bennett_result`, `bennett_
   estimate_out`, `bennett_coverage_out` (their fields are those named in
   §10, §12, §13).
