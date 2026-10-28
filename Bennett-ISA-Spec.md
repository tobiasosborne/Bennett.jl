# Bennett Virtual ISA — Specification, draft 0.1

**Date:** 2026-10-28. **Status:** first normative draft, for council
iteration. This document is the founding text of the `bennett-isa-spec`
repository defined in `Bennett-NorthStar.md` §4.4 and §6.1; the north
star is background and governs where this draft is silent. Nothing is
implemented. The words MUST, MUST NOT, SHOULD and MAY are normative.
Sections marked *(non-normative)* explain; sections marked *(deferred)*
name items this draft intentionally leaves open and asserts to be non-
semantic.

**Versioning.** The ISA, the object format, the launch ABI, the scheduling
interface, the certificate schema and the coverage-report format are
versioned independently (semantic versioning). A conformant implementation
declares which version of each it implements. This draft is ISA 0.1,
object 0.1, launch 0.1, sched 0.1, cert 0.1, coverage 0.1.

---

## 1. Scope and conformance

### 1.1 What the ISA is

A program model for classical, reversible and coherent computation with a
single semantics, executed by a **virtual machine** (`bennett-vm`) and by
a **circuit specialiser** (`bennett-circuits`), produced by the LLVM
plugin (`bennett-plugin`) from the dialect (`bennett-dialect-spec`), and
scheduled by an implementation of the scheduling interface
(`bennett-sched`). Hardware is described by a **target description**
(§8). Nothing in this specification refers to LLVM; the dialect's
reference semantics maps dialect programs onto this ISA.

### 1.2 Conformance classes

| Class | Who | Obligation |
|---|---|---|
| **Executor** | VM, specialiser, hardware stacks | Implements §3–§7 exactly as the formal model (§14) defines; passes conformance suites A–E and H (§15). |
| **Producer** | plugin, library compilers | Emits well-formed objects (§9) whose regions satisfy the well-formedness rules (§5, §6); passes suite F. |
| **Scheduler** | `bennett-sched` and competitors | Implements §11; returns only schedules valid under §6; passes suite H. |
| **Checker** | `bennett-conformance` | Validates certificates (§12) against objects without trusting producers. |
| **Target author** | hardware vendors | Supplies a target description conforming to §8; passes suite E. |

### 1.3 What this draft defers *(deferred)*

Binary encodings of instructions and objects (a canonical textual form is
normative, §16); the exact numeric values of fault codes beyond their
names (§5.4); the gate-alphabet extension process (§4.3); the formal
model's mechanisation (§14 states it in prose and mathematics).

## 2. Terminology

- **Tier.** One of *classical-control* (CC), *reversible* (R), *coherent*
  (Q). Every function is in exactly one tier.
- **Wire.** A linear value denoting one qubit. **Bundle.** `wire[N]`, N
  wires with a declared little-endian integer reading.
- **Classical value.** `iN` (1 ≤ N ≤ 128), `ptr` (classical byte address),
  `f64` only in CC.
- **Region.** A Q-tier function with a declared interface: a *lifted
  oracle* (§5.2) or a *quantum action* (§5.3).
- **Budget.** The classical triple (steps, heap bytes, call depth) under
  which a lifted oracle runs.
- **Fault register.** A caller-supplied bundle into which a lifted oracle
  XORs a fault code.
- **History.** Workspace that records what predicated execution
  overwrote, so that it can be reversed.
- **Basis input.** An assignment of classical values to every wire of a
  region's inputs, targets, fault register and borrowed ancillae.

## 3. Machine model

### 3.1 Tiers and what may call what

```
  CC  ──calls──▶  R regions   (enter / run / reverse through the launch ABI, §10)
  CC  ──calls──▶  Q regions   (lifted oracles and quantum actions, §5)
  R   ──calls──▶  R functions (call/uncall, §9.3) and Q regions
  Q   ──calls──▶  Q regions   (nesting, §5.5) and R-tier library functions lifted into Q
```

CC code runs on the device's classical-control processor, **never** on the
host (the host reaches the device only through §10). CC code MAY inspect
measurement results and classical values. **No instruction in any tier
may make a control or scheduling decision that depends on the value of a
wire** except through the predication mechanism of §3.5, which does not
inspect the wire but conditions on it. This is the architectural
invariant of the north star §4.2.

### 3.2 State

| Component | Tier | Contents |
|---|---|---|
| classical registers | CC, R, Q | SSA values of classical type; in Q they are constants fixed at region entry |
| classical memory | CC, R | byte-addressed sparse map; reads of unwritten bytes yield 0 |
| effect tape | R | append-only sequence of effect records (§7.3) |
| history | R, Q | sequence of history frames (§3.6) |
| wire store | Q, CC (via handles) | the set of live wires, each in exactly one of: *input*, *target*, *fault*, *borrowed*, *workspace*, *mutable* (§5) |
| quantum memory | Q | named regions, each an array of `wire[W]` cells (§7.2) |
| predicate stack | Q | stack of wires; the *active predicate* is their conjunction (§3.5) |
| program counter | Q (step machine) | a bundle `pc : wire[P]` naming an instruction index or HALT (§3.6) |
| budget counters | Q | classical: steps remaining, heap remaining, depth remaining |

### 3.3 Types

```
  iN           classical integer, 1 ≤ N ≤ 128, two's complement
  ptr          classical byte address, width from the target description
  wire         one qubit, linear
  wire[N]      bundle of N wires, linear as a unit; integer reading little-endian
  qaddr[A]     a bundle used as an address into a quantum memory region of 2^A cells
  token        classical opaque value returned by region/budget instructions
```

**Linearity.** Every `wire` and `wire[N]` value MUST be consumed exactly
once by an instruction that lists it as consumed, and produced exactly
once. Instructions below mark operands `in` (consumed, re-produced as an
output with the same name), `consume` (consumed, not re-produced) or
`produce`. A program that uses a wire twice, or drops one, is ill-formed
(§15 suite F rejects it). Executors MAY assume linearity.

### 3.4 Execution in CC and R tiers

Sequential small-step execution with an instruction pointer, block
parameters instead of phi nodes, dynamic control flow, dynamic
allocation. In R, every instruction MUST be invertible given the history
(§3.6) and the effect tape (§7.3); the executor MUST be able to run an R
function backwards to its entry state (theorem T4, §14).

### 3.5 Predication in Q tier

Every Q instruction executes under the **active predicate** p, the
conjunction of the predicate stack. An instruction with semantics "apply
unitary U" executes "apply U controlled on p". An instruction with
classical semantics (budget decrement, token creation) executes
unconditionally. `qpred` pushes a wire; `qunpred` pops it and MUST pop the
same wire. The predicate stack is empty at region entry and MUST be empty
at region exit.

### 3.6 The predicated step machine *(the general construction)*

A lifted oracle's body is a list of instructions `I[0..n)` with a
distinguished index `HALT = n`. Execution for budget B proceeds in B
**machine steps**. State: `pc : wire[P]` with 2^P > n, initialised to a
clean bundle XORed with 0 (the entry index). One machine step:

1. For every index k in 0..n (including HALT), compute the wire
   `at_k = (pc == k)` into workspace; `at_HALT` is the halt flag.
2. For every index k < n, push `at_k` on the predicate stack, execute
   `I[k]`, pop. Control instructions (§4.1 `qjump`, `qbranch`) do not
   modify `pc` directly: they XOR the *next* index into a fresh bundle
   `pc' ` and record the old `pc` in a **history frame** (`pc` is moved
   into the frame by exchange; the frame is workspace). After all k,
   `pc := pc'`. Non-control instructions fall through: the step machine
   XORs `k+1` into `pc'` under `at_k` for every non-control `I[k]`.
3. Uncompute every `at_k` (they are functions of the old `pc`, which is
   in the history frame, so they are uncomputable).
4. Decrement the classical step counter.

After B steps the region evaluates its **exit** (§5.2): under `at_HALT`
the result is committed; under `¬at_HALT` the fault register receives
`FAULT_BUDGET_STEPS`. Then the entire B-step execution is **reversed**
(the prefix-reversal invariant, §5.6), which returns `pc`, every history
frame and every `at_k` to clean.

The cost of one machine step is the sum over k of the cost of `I[k]`
under control; a specialiser MAY recover structure (§4.6 `qloop`,
`qif`) wherever it can prove the CFG structured, and MUST produce the
same function (theorem T6).

*(non-normative)* The step machine is Bennett's history construction
applied at instruction granularity. Everything an executor needs to
reverse is in the history frames and the budget counter; nothing is ever
overwritten.

## 4. Instruction set

Notation: `name operands → results`. Operand modes: `in`, `consume`,
`produce`, `c` (classical). Each entry: **WF** well-formedness,
**Sem** semantics, **Cost** the resource hook (§8.4).

### 4.1 Classical control (CC, R, Q)

| Instruction | Form | Notes |
|---|---|---|
| `const` | `const c:iN → r:iN` | |
| `binop` | `add/sub/mul/and/or/xor/shl/lshr/ashr a:iN b:iN → r:iN` | **Sem:** two's complement, wrap; shifts by ≥ N yield 0 (totalised, §3.2 of the north star). |
| `udiv/urem/sdiv/srem` | `a b → r` | **Sem:** divisor 0 → `fault FAULT_UB_DIV0` (Q) or trap (CC). |
| `icmp` | `eq/ne/ult/ule/slt/sle a b → r:i1` | |
| `select` | `select p:i1 a b → r` | |
| `cast` | `zext/sext/trunc/ptrtoint/inttoptr` | |
| `br` | `br b` / `br p:i1 b1 b2` | CC, R only (dynamic). |
| `qjump` / `qbranch` | `qjump k:c` / `qbranch w:in wire k1:c k2:c` | Q only; **Sem:** set next pc under the active predicate (§3.6). `w` is not consumed. |
| `call` / `ret` | `call @f args → results` | CC, R: dynamic. Q: inlined, or bounded by the depth budget with a padded frame stack (§5.4). |
| `switch` | lowered to `icmp` chains by producers | not an instruction. |

### 4.2 Allocation

| Instruction | Form | Rules |
|---|---|---|
| `qalloc` | `qalloc class:c n:c → w:produce wire[n]` | **Sem:** n clean |0⟩ wires of qubit class `class` (§8.2). **WF:** `class` named by the target or `any`. **Cost:** class occupancy from allocation to `qfree`. |
| `qborrow` | `qborrow class:c n:c → w:produce wire[n]` | **Sem:** n wires in an unknown state (dirty). The region MUST restore them to their initial value on every basis input (§5.2 domain D). **Cost:** class occupancy at the dirty rate. |
| `qfree` | `qfree w:consume wire[n]` | **Sem:** release. **WF:** w was produced by `qalloc` (clean) or `qborrow` (restored). Executors with a simulator MUST check; hardware MAY trust the certificate. A `qalloc`ed wire freed non-clean is a producer error, not a fault. |
| `alloc` / `free` | CC, R: classical heap | R: `free` is a no-op that validates (bump allocator rewound on reversal); Q lifted code: counted against the heap budget, `FAULT_BUDGET_HEAP` on exhaustion. |

### 4.3 Gates

| Instruction | Form |
|---|---|
| `x` | `x a:in` |
| `cx` | `cx c:in t:in` |
| `ccx` | `ccx c1:in c2:in t:in` |
| `mcx` | `mcx cs:in wire[k] t:in` (k ≥ 0; k = 0,1,2 are `x`,`cx`,`ccx`) |
| `swap` | `swap a:in b:in` |
| `h` | `h a:in` |
| `rz` / `ry` / `rx` | `rz θ:c:f64 a:in` (θ classical, fixed at region entry) |
| `s`, `sdg`, `t`, `tdg` | single-wire Clifford/T |
| `cz` | `cz a:in b:in` |

**Sem:** the standard unitaries, controlled on the active predicate
(§3.5). **Permutation gates** are `x cx ccx mcx swap`. **Cost:** from the
target description (§8.3); a gate absent from a target's alphabet is
decomposed by the executor using the target's declared decompositions,
and the certificate (§12) records which. **Extension** *(deferred)*: new
gate names enter through a spec revision.

### 4.4 Copy, XOR, exchange, in-place

| Instruction | Form | Semantics |
|---|---|---|
| `qcopy` | `qcopy s:in wire[n] → d:produce wire[n]` | d = fresh clean wires, then `cx s_i d_i` for all i. d is workspace. |
| `qxor` | `qxor s:in wire[n] t:in wire[n]` | t_i ^= s_i (n `cx`). The north-star "XOR-on-write". |
| `qexch` | `qexch a:in wire[n] b:in wire[n]` | n `swap`. The reversible overwrite: a lifted `store v → cell` is `qexch v cell`, whose old cell value lands in `v`'s wires, which become history. |
| `qinplace` | `qinplace @g @ginv x:in wire[n] args` | **WF:** `@g` and `@ginv` are *quantum actions* (§5.3) that are mutually inverse total bijections on the declared n-bit encoding, with a certificate (§12) or an exhaustive check at n ≤ 16. **Sem:** `t = qalloc n; call @g x → t` (out of place); `qexch x t`; `call @ginv x → t` uncomputing `t`; `qfree t`. A fallible computation MUST NOT be `qinplace`d (it has no total inverse); it is a lifted oracle (§5.2). |

### 4.5 Quantum memory

| Instruction | Form | Semantics |
|---|---|---|
| `qregion` | `qregion name cells:c W:c` | declares a region of `cells` cells of `wire[W]`, all clean at creation. Declared at object scope; created at region entry; MUST be clean at region exit. |
| `qload` | `qload r:name a:in qaddr[A] → d:produce wire[W]` | d = fresh clean; for every cell i: under `a == i`, `qxor cell_i d`. Copy-on-read. |
| `qstore` | `qstore r:name a:in qaddr[A] v:in wire[W]` | for every cell i: under `a == i`, `qxor v cell_i`. XOR-on-write. |
| `qexchm` | `qexchm r:name a:in qaddr[A] v:in wire[W]` | for every cell i: under `a == i`, `qexch v cell_i`. Reversible overwrite for lifted stores. |

**Cost:** `cells · W` controlled operations plus the address comparators,
unless the target declares `qram` (§8.3), in which case the target's
declared QRAM cost applies. The address comparators `a == i` are computed
into workspace and uncomputed within the instruction.

### 4.6 Predication, structure, measurement, effects, faults

| Instruction | Form | Rules |
|---|---|---|
| `qpred` / `qunpred` | `qpred w:in` / `qunpred w:in` | §3.5. **WF:** properly nested; `w` not modified between push and pop. |
| `qif` | `qif w:in { then } { else }` | sugar: `qpred w; then; qunpred w; x w; qpred w; else; qunpred w; x w`. **WF:** neither arm modifies `w`. |
| `qloop` | `qloop bound:c { body }` | sugar: `body` repeated `bound` times. Data-dependent exit is expressed by predicating the body on a *continue* wire the body maintains; the loop still runs `bound` times (padding). |
| `measure` | `measure w:consume wire[n] → r:iN` | **CC only**, on wires reached through handles (§10). Collapses; `r` is classical. **WF:** MUST NOT appear in any Q region (§5.1). |
| `effect` | `effect dev:c op:c args → results` | **R only** (§7.3). |
| `fault` | `fault code:c` | Q only. **Sem:** under the active predicate, XOR `code` into the enclosing lifted oracle's fault register *if the register is currently 0* (first fault wins: implemented as `mcx` on the register's zero-test); set the oracle's *faulted* flag wire; jump to HALT. **WF:** only inside a lifted oracle. |
| `budget` | `budget steps:c heap:c depth:c → tk:token` | classical; creates a budget token consumed by `oracle_call`. |

### 4.7 Region calls

| Instruction | Form | Rules |
|---|---|---|
| `oracle_call` | `oracle_call @o tk:token ins:in wire[*] tgt:in wire[*] fr:in wire[F] args:c` | §5.2. |
| `action_call` | `action_call @a mut:in wire[*] ins:in wire[*] args:c` | §5.3. |
| `adj` | `adj action_call …` | runs the action's adjoint (§5.3). `adj oracle_call` is identical to `oracle_call` (oracles are involutions, §5.2). |
| `ctl` | `ctl w:in action_call …` / `ctl w:in oracle_call …` | sugar for `qpred w; …; qunpred w`. |

## 5. Regions

### 5.1 Common well-formedness

A region is a Q-tier function. It MUST NOT contain `measure`, `effect`,
`br`, or classical `alloc` outside lifted code counted by the heap
budget. It MUST begin and end with an empty predicate stack. Every wire it
`qalloc`s it MUST `qfree` clean before exit; every wire it `qborrow`s it
MUST restore and `qfree`. Every quantum memory region it creates MUST be
clean at exit. A region's classical arguments are constants for its
duration.

### 5.2 Lifted oracle

**Interface.** `oracle @o (ins: wire[*], tgt: wire[T], fr: wire[F], args: c…) budget(B)`.

- **Inputs** `ins` are *preserved*: on every basis input their final value
  equals their initial value.
- **Target** `tgt` may hold any value on entry; on exit it holds
  `tgt ⊕ payload(F_B(x))`.
- **Fault register** `fr` may hold any value on entry; on exit it holds
  `fr ⊕ code(F_B(x))`.
- **Bounded result.** `F_B(x) = (f(x), 0)` if the reference interpreter
  (§14.1) halts within B on basis input x without a fault, where f is the
  function the body computes; else `F_B(x) = (0, code)` where `code` is
  the **first** fault the reference interpreter encounters in its
  sequential order on x (the canonical zero payload).
- **Involution.** Because both effects are XORs, applying the oracle
  twice is the identity on `(ins, tgt, fr)`; `adj` of an oracle is the
  oracle; `ctl` composes by XOR accumulation.
- **Construction** (what an executor runs): allocate `pc`, history and
  workspace; run the step machine for B steps (§3.6); under `at_HALT ∧
  ¬faulted`, `qxor result tgt`; under `faulted`, the `fault` instruction
  has already XORed the code; under `¬at_HALT ∧ ¬faulted`, `qxor
  FAULT_BUDGET_STEPS fr`; then **reverse** the step machine and release
  everything (§5.6).

**Domain D** of an oracle, for conformance (§15 suite C): every value of
`ins`, every value of `tgt`, every value of `fr`, every initial value of
every `qborrow`ed bundle, `qalloc`ed wires at 0.

### 5.3 Quantum action

**Interface.** `action @a (mut: wire[*], ins: wire[*], args: c…)`.

- **Mutable wires** `mut` are transformed by a unitary U_a determined by
  the body; **inputs** `ins` are preserved (they may be used as controls
  and as `qcopy` sources only); workspace is restored.
- The body is **structured**: gates, `qcopy`/`qxor`/`qexch`, `qload`/
  `qstore`, `qif`, `qloop`, `qinplace`, `oracle_call`, `action_call`. It
  has no step machine and no `fault`; a fallible computation it needs is
  an `oracle_call` whose fault register the action declares among its
  `mut` wires.
- `adj @a` is the body reversed with every gate replaced by its adjoint,
  every `oracle_call` unchanged, every nested `action_call` adjointed.
  **WF:** the adjoint of a well-formed action is well-formed by
  construction.
- `ctl w @a` is controlled-U_a: the body under `qpred w`.

### 5.4 Budgets and fault codes

Budget `(steps, heap, depth)` is classical, fixed before entry. **Steps**
are counted by the reference interpreter (§14.1) as instructions executed
along the sequential path on basis input x. **Heap** counts bytes
allocated by lifted `alloc`. **Depth** counts nested `call` frames in
lifted code; an executor implements calls within an oracle either by
inlining or by a frame stack padded to `depth` frames.

Fault codes (names normative; values *deferred*):

```
  FAULT_NONE            0
  FAULT_BUDGET_STEPS      budget.steps exceeded
  FAULT_BUDGET_HEAP       budget.heap exceeded
  FAULT_BUDGET_DEPTH      budget.depth exceeded
  FAULT_UB_TRAP           unreachable / trap instruction reached
  FAULT_UB_DIV0           division or remainder by zero
  FAULT_UB_MEMFAULT       access outside any allocation (lifted classical memory)
  FAULT_EFFECT_UNMODELLED an effect the device does not virtualise
  FAULT_CALLEE            a nested oracle faulted and the caller did not handle it
```

The fault register width F MUST be ≥ 4 bits.

### 5.5 Nesting

Oracles and actions nest without restriction, including an oracle calling
an action (for a library bijection) and an action calling an oracle. A
nested `oracle_call` inside a lifted oracle propagates `FAULT_CALLEE`
unless the lifted code tests the nested fault register.

### 5.6 Prefix-reversal invariant and exit synchronisation

**Prefix reversal.** Every executor MUST implement a lifted oracle so that
after commit the forward computation is reversed exactly, on faulted and
non-faulted basis inputs alike, by running the recorded history
backwards. Consequently, on every basis input, `pc`, every history frame,
every `at_k`, every `qalloc`ed wire and every quantum memory cell return
to clean, and every `qborrow`ed wire returns to its initial value.

**Exit synchronisation.** All basis branches reach the same halt
configuration (`pc = HALT` or faulted-and-jumped-to-HALT, or budget
exhausted at the same step count B) before any control workspace is
reversed. Branches never finish early: the machine always runs B steps.

### 5.7 Two implementations, one function

A specialiser that recovers structure (replacing step-machine execution
by `qif`/`qloop` where the CFG permits) MUST produce, on every basis
input in D, the same final register tuple as the step machine; theorem T6
states this and suite C tests it.

## 6. Uncomputation validity

Every value in workspace has a **dependency set**: the wires (inputs,
mutable wires, memory cells) whose basis values determined it, and a
**provenance**: `qfree` (computed only by permutation gates from its
dependency set) or `non-qfree`.

- A `qfree` value MAY be uncomputed by reversing or recomputing its
  computation **only while every wire in its dependency set holds the
  same basis value as at computation time**.
- It MUST be uncomputed before any non-permutation gate (`h`, `rx`, `ry`,
  non-diagonal `rz` usage, `measure`) or any `qinplace`/`qexch` acts on a
  wire in its dependency set, and before the enclosing region exits.
- Where that window has closed, the only sanctioned alternative is
  **measurement-based uncomputation with phase fixup**, which this draft
  admits only as an *executor-internal* lowering of `qfree`-value cleanup
  (never visible as an instruction), with the fixup computed for the
  actual schedule (after an intervening U the correction D becomes
  U D U†) and verified by suite D.
- A `non-qfree` value cannot be uncomputed by recomputation and MUST be
  released only through the adjoint of the action that produced it.

Schedulers (§11) MUST choose only schedules satisfying these rules.
Producers MUST emit regions in which a valid schedule exists; the
verifier of suite F rejects a region where no valid schedule exists.

*(non-normative)* This is Silq's `qfree`/`const` discipline and Unqomp's
validity criterion, stated as an invariant of the machine so that no
scheduler, compile-time or run-time, can defer uncomputation past an
interfering operation.

## 7. Memory and effects

### 7.1 Classical memory (CC, R, and lifted code in Q)

Byte-addressed, sparse. In R, a `store` records the overwritten bytes in a
history frame. In Q, lifted classical memory is represented by the
producer as quantum memory regions (§7.2) with `qexchm` for stores and
`qload` for loads; the layout is the producer's choice and is recorded in
the object (§9) so the checker can map basis inputs.

### 7.2 Quantum memory

`qregion` declares; `qload`/`qstore`/`qexchm` access (§4.5). A region is
addressed by a bundle; the address comparators are permutation
computations and are `qfree`. Cost is linear in the region size unless
the target declares QRAM.

### 7.3 Effects (R tier only)

`effect dev op args → results` invokes a **device model** named in the
object's device table. Forward execution appends a record `(dev, op,
args, results, device-state delta)` to the effect tape; reversal pops the
record and applies the inverse delta. Device models in this draft:
`console` (write), `clock` (read), `entropy` (read), `block` (read/write
sectors). A device the object names but the executor lacks is a load-time
error (§10). An `effect` in a Q region is ill-formed; a lifted program
that reaches one faults with `FAULT_EFFECT_UNMODELLED`, which means the
producer virtualised the device as quantum memory and the program reached
an operation the virtualisation does not model.

## 8. Resources and target descriptions

### 8.1 The resource vector

A target declares a finite set of **resource names** with units. The base
resource every target MUST declare is `qubit_second` per qubit class. The
scheduler reports, and the certificate carries, a vector over all
declared names.

### 8.2 Qubit classes

```
  classes:
    <name>: { qubit_second: <cost per second>, dirty_rate: <cost multiplier when borrowed> }
```

`any` resolves to the cheapest class satisfying the instruction's
requirements. Allocation chooses a class the way a register allocator
chooses a register class; the choice is recorded in the schedule.

### 8.3 Gate alphabet, capabilities, decompositions

```
  gates:
    <gate>: { <resource>: <cost>, ..., time: <seconds> }      # native gates
  decompositions:
    <gate>: <sequence of native gates with cost>                # for non-native gates the executor may emit
  capabilities:
    qram: { none | { load: <cost vector>, store: <cost vector> } }
    measurement: { mid_circuit: bool, feedforward_latency: <seconds> }
    mbu: bool                                                   # measurement-based uncomputation allowed
    max_predicate_depth: <int | unbounded>
```

A gate neither native nor decomposable on a target is a load-time error.

### 8.4 Objective

```
  objective: weighted { <resource>: <weight>, ... }
           | lexicographic [ <resource>, <resource>, ... ]
```

The scheduler minimises the objective; conformance (suite E) checks that
reported resource usage is accounted in the target's declared units.

### 8.5 Importing existing models

A target description MAY be generated from a Qualtran or Azure-RE model:
cost units that align with a declared resource are converted; others are
imported as new named resources, so no information is lost and the
objective can still weight them.

## 9. Objects, linking, reversible ABI

### 9.1 Object

A canonical textual form (§16) with sections:

```
  header       { isa, object, launch, sched, cert, coverage versions; producer; target hint }
  types        { bundle widths, quantum memory region declarations }
  symbols      { interned IDs → (name, content hash, kind: cc|r|oracle|action|data) }
  functions    { per symbol: tier, interface, body }
  devices      { device models the R tier references }
  layout       { producer's mapping of lifted classical memory to quantum regions }
  certificate  { §12 }
  coverage     { §13 }
```

### 9.2 Linking

Symbols resolve **structurally**: by interned ID and content hash, never
by bare name. Two objects that define the same ID with different hashes
do not link. Objects are content-addressed; a link is a new object whose
`functions` is the union and whose certificate is the composition (§12).

### 9.3 Reversible ABI

- **CC/R calls** are ordinary calls with a classical frame.
- **R call/uncall**: a callee runs forward on `call` and backward on
  `uncall`; the executor matches frames by the history.
- **Q region calls** (`oracle_call`, `action_call`): the caller supplies
  every wire the interface names; the callee allocates and frees its own
  workspace; **shared ancilla frames** are permitted when the certificate
  of the callee states its peak workspace and the caller reserves it, so
  that nested calls reuse one frame instead of nesting allocations.
- Classical arguments are passed by value and are constants for the
  callee's duration.

## 10. Launch ABI (host ↔ device)

A C ABI; the Rust runtime exports it, Bennett.jl and other hosts consume
it.

```
  bennett_load(object, target) → program | error(load-time: missing device, gate, version)
  bennett_budget(program, region, steps, heap, depth) → token
  bennett_alloc(program, class, n) → handle          # host-visible wires
  bennett_run(program, region, token, in_handles, tgt_handles, fault_handle, args) → status
  bennett_reverse(program, run_id) → status           # R tier: un-run to entry; Q tier: no-op (regions self-reverse)
  bennett_measure(program, handle) → bits             # CC-tier measurement on host-visible wires
  bennett_tape(program) → effect records              # R tier
  bennett_estimate(program, region, token, target) → resource vector + certificate (no execution)
  bennett_coverage(program) → coverage report
```

Host code never holds a wire, only a handle; a handle's wires are in the
device's wire store in state *input* or *mutable* for the duration of a
run. Host code that interleaves real host effects with handle or
measurement operations is split by the driver: the handle and measurement
operations run as CC code on the device, the host effects between them
run on the host, synchronised by `bennett_run` boundaries.

## 11. Scheduling interface

```
  sched_schedule(program, region, target, objective, space_budget) → schedule + certificate
```

**Schedule:** for each region, the placement of uncomputation (per
workspace value: reverse / recompute / MBU, and when), checkpoint and
recomputation points for R-tier history, qubit-class assignment per
allocation, gate choices among the target's decompositions, and structure
recovery decisions (step machine vs `qif`/`qloop`).

**Obligations:** every schedule MUST satisfy §6; MUST respect `space_budget`
in `qubit_second`-weighted peak occupancy; MUST report the full resource
vector; MUST be reproducible from `(program, region, target, objective,
space_budget, scheduler version)`.

**Run-time use.** The VM calls the same interface with the same inputs
plus the run-time budget; the VM's scheduling decisions therefore depend
only on classical data (program, target, budget), never on wire values.

## 12. Certificate schema

```
  certificate:
    versions:        { isa, object, launch, sched, cert }
    producer:        { name, version, llvm_version, pipeline }        # the fault set depends on these
    target:          <target id and hash>
    objective:       <as §8.4>
    regions:
      <symbol>:
        kind:        oracle | action
        interface:   <wire counts, F, classical args>
        budget:      { steps, heap, depth } | none (action)
        resources:   <vector>
        gates_used:  <alphabet and decompositions chosen>
        peak_workspace: <int>
        verification:
          permutation_tier: { domain: <description of D>, widths: <exhaustive up to>, result: proof | evidence, seeds: [...] }
          channel:          { widths, metric: diamond | operator_norm, epsilon, composition: sum, result: proof | evidence }
          fault_rate:       { domain, rate, undefined_excluded: <count> }
          inverse_pairs:    [ { g, ginv, checked_width | library_certificate } ]
          minimality:       { claimed: bool, lower_bound_certificate | exhaustive_search } | none
        definedness_assumption: <text, normative>
    composition:     <for linked objects: how region certificates were combined; epsilons summed>
```

A checker (`bennett-conformance`) MUST be able to validate every
`proof`-labelled entry by re-execution at the stated widths without
trusting the producer; `evidence` entries are replayable with the stated
seeds.

## 13. Coverage report

Per object, per function: `lowered | trapped | shimmed` for every source
construct the producer encountered, with counts and, for `trapped`, the
fault code the lifted program will raise if reached. Emitted by the
driver, consumed by the checker and by humans.

## 14. Formal model

### 14.1 The reference interpreter *(normative)*

A sequential interpreter over ISA text that executes Q regions **per basis
input**: wires are bits, predication is an `if`, every gate is a
permutation on bits (non-permutation gates are illegal in the reference
interpreter's oracle mode and are handled by suite D). For a lifted oracle
it executes the body sequentially from index 0, counts steps, heap and
depth, stops at HALT or at the first fault, and reports `(f(x) or 0,
code, steps)`. This interpreter **defines** F_B and the budget unit.

### 14.2 Abstract semantics *(normative in content, mechanisation deferred)*

State Σ = (classical registers, classical memory, tape, history, wire
store, quantum memory, predicate stack, pc, budgets). The step relation
Σ → Σ′ is as §3 and §4 define; for Q regions the per-basis-input
semantics of §14.1 and the executor semantics of §3.6 are related by the
theorems below.

### 14.3 Theorems to be proved for the spec, with hypotheses

- **T1 (totality, determinism).** For every well-formed oracle and budget
  B and basis input x ∈ D, F_B(x) is defined and unique, and `code` is the
  first fault in sequential order.
- **T2 (prefix reversal).** For every executor implementing §3.6 and
  §5.6, on every x ∈ D, every workspace wire, `pc`, history frame and
  memory cell is clean after exit and every borrowed bundle is restored.
- **T3 (permutation theorem).** If an executor's realisation of an oracle
  uses only permutation gates after decomposition, and on every x ∈ D its
  final register tuple equals `(ins, tgt ⊕ payload(F_B(x)), fr ⊕
  code(F_B(x)), borrowed, 0)`, then its unitary restricted to span(D) is
  exactly that permutation: no relative phase, no residual entanglement.
- **T4 (round trip, R tier).** For every R function and initial state,
  running forward then `uncall` returns the state, tape and history to
  the initial state.
- **T5 (validity ⇒ cleanliness).** Under §6, every `qfree` value
  uncomputed within its window returns exactly to clean and leaves no
  correlation with the data.
- **T6 (executor agreement).** Any two executors conforming to §3–§7
  produce, on every x ∈ D, the same final register tuple for every
  oracle, and unitaries equal up to the certificate's ε for every action.

### 14.4 Scope of mechanisation *(deferred)*

A machine-checked model of §3.6, §5.2 and §6 at the abstract level
(bits, not gates) is the target; the gate-level realisation is tested by
suite C and D, not proved.

## 15. Conformance suites

| Suite | Class | What it tests |
|---|---|---|
| A | Executor | Classical ISA: exhaustive at narrow widths, property-based above; R round trip (T4) with tape. |
| B | Executor | Region totality and prefix reversal (T1, T2): oracles whose inputs include faulting basis states; all fault codes; borrowed restoration. |
| C | Executor, Producer | Permutation theorem (T3) over full D at exhaustive widths; executor agreement (T6) between VM, specialiser and the reference interpreter; structure recovery vs step machine. |
| D | Executor | Channel comparison for non-permutation lowerings and MBU: Choi-state comparison with a reference system at small widths; controlled-interference tests; ε accounting. |
| E | Target author, Executor | Resource accounting against declared units; objective evaluation; decomposition legality. |
| F | Producer | Well-formedness: linearity, predicate nesting, region rules, §6 schedulability, object format, structural linking. |
| G | Launch | Launch ABI round trips: load, budget, run, reverse, measure, tape, estimate. |
| H | Scheduler | Every returned schedule satisfies §6 and the space budget; reproducibility. |

## 16. Canonical textual form and versioning

The canonical form is a line-oriented text with one instruction per line
in the notation of §4, blocks introduced by `^name(params):`, functions by
`oracle`/`action`/`fn tier`, and sections as §9.1. It is the interchange
and conformance format; a binary encoding *(deferred)* MUST round-trip
through it. Version negotiation: an executor MUST refuse an object whose
ISA major differs from its own and MAY accept a lower minor.

## 17. Open items *(deferred, asserted non-semantic)*

1. Binary encoding; numeric fault codes.
2. Gate-alphabet extension process and the registry of gate names.
3. The exact C signatures of §10 and §11 (the semantics of each entry
   point is normative above; the types are not yet frozen).
4. Mechanisation of §14.
5. The device-model set beyond the four named in §7.3.
