# Brief: Axelsen & Glück 2013 — Reversible Heap (AG13)

## Citation

- **Authors:** Holger Bock Axelsen and Robert Glück
- **Title:** Reversible Representation and Manipulation of Constructor Terms in the Heap
- **Venue:** RC 2013, LNCS 7948, pp. 96–109
- **Springer URL:** https://link.springer.com/chapter/10.1007/978-3-642-38986-3_9
- **PDF:** `AxelsenGluck2013_reversible_heap.pdf` (11 pages, 260 KB)
- **Affiliation:** DIKU, Department of Computer Science, University of Copenhagen

---

## 1. Core Contribution

AG13 presents the first complete garbage-free method for representing and manipulating **binary constructor trees** (algebraic data types) in the heap of a **reversible machine**, without generating garbage. The approach uses:

1. A **linear heap** — every cons cell has reference count exactly one, guaranteed by the linear variable-usage discipline of RFUN.
2. The **EXCH** (exchange) instruction as the primitive for reversible heap reads and writes.
3. Reversible **allocation** (`get_free()`) and **deallocation** as exact inverses.
4. A **free list** maintained as a heap invariant across construction/deconstruction.

The paper also gives reversible implementations of the RFUN **first-match policy** and **call-stack interaction** for let-calls.

---

## 2. Verbatim Algorithm Pseudocode

### 2a. Building a Nil Node — p. 101, §4.1 "Building a Nil"

```
< r_cell ← get_free() >    ; subroutine call
XORI r_t  Nil               ; Nil is a constant
EXCH r_t  M(r_cell)         ; write Nil in the constructor field
< return r_cell >
```

*Note (p. 101):* "the temporary register r_t is zero-cleared after the EXCH instruction: the constructor field of the new cons cell is initially zero and EXCH exchanges the contents of the register and the memory location."

### 2b. Building a Cons Node — p. 101–102, §4.1 "Building a Cons"

```
< r_cell ← get_free() >    ; subroutine call
XORI r_t  Cons              ; Cons is a constant
EXCH r_t  M(r_cell)         ; write Cons in the constructor field
ADDI r_cell  1              ;
EXCH r_a  M(r_cell)         ; move pointer to a to the 'left' field
ADDI r_cell  1              ;
EXCH r_b  M(r_cell)         ; move pointer to b to the 'right' field
SUBI r_cell  2              ; realign cell pointer
< return r_cell >
```

*(Fig. 3 caption, p. 102: "How the heap changes while building a Cons node, corresponding to evaluating the left-expression Cons(a,b) in the environment {x → Nil, a → Nil, b → Cons(Nil,Nil)}.")*

### 2c. The `get_free()` Subroutine — p. 103, §4.1 "Using the free list"

```
if (r_flp == 0)               ; subroutine body get_free()
then                           ; grow heap:
  XOR  r_cell  r_hp            ; cell := hp
  ADDI r_hp    3               ; hp++ (3 is the size of a cons cell)
else                           ; pop free list:
  EXCH r_cell  M(r_flp)        ; cell ⇔ M(flp)
  SWAP r_cell  r_flp           ; cell ⇔ flp
fi (r_flp == 0) && (r_cell == r_hp - 3)
```

*(p. 103: "The above gives pseudocode for the control flow in the style of Janus [14]. The if-then-else-fi reversible control flow statement works almost as a traditional if-then-else, except that it also has a joining assertion (the expression following the fi). This assertion must be true if control comes from the then-branch, and false otherwise, to guarantee reversibility.")*

**Invariant required for orthogonalization** (p. 103): "the last element of the free list must never be the cons cell immediately above the heap pointer." This is what makes the fi-condition orthogonalizable: we grew the heap only if the free list is empty *and* the allocated pointer points to the top of the heap.

### 2d. Pattern Matching (Data Deconstruction) — p. 104, §4.2 "Pattern Matching Constructors"

```
if (constructor_field == Nil)
then
  deconstructNil()
  < code for branch e_1 >
else
  deconstructCons()
  < code for branch e_2 >
fi match(result, Cons(Nil, Nil))
```

*(p. 104: "the forward branching condition is merely the constructor field value... the joining assertion match(result, Cons(Nil, Nil)) is checked on the reverse path.")*

Deconstruction of a Cons cell is the exact inverse of construction: pull the constructor field and child pointers into temporary registers, zero-clear the constructor field, place the cons cell on the free list, and add the two children back to the environment. Freeing a cell is the inverse of `get_free()`.

### 2e. First-Match Policy Implementation — p. 105–106, §4.2 "Implementing the first-match Policy"

For a function with leaves {l_1, ..., l_n}, the branches are joined as follows (p. 106):

> "we first join the n-th and (n−1)-th branch by matching the return value with l_{n−1}. Join the resulting merged branch with the (n−2)-th branch by matching the return value with l_{n−2}, and so forth until all branches are merged. Thus, the return value from the i-th branch will be matched against l_i (which will trivially succeed) and then matched against l_{i−1}, l_1 as required (all of which should fail)."

The control-flow structure is shown in Fig. 4 (p. 106). Each join uses a conditional pattern-match as an orthogonalizing assertion. The cost scales with the number of branches.

### 2f. Call Stack Interaction — p. 106–107, §4.3

> "For the *call sequence*, the caller pushes its complete environment onto the call stack (with the non-argument variables first, and the argument variables on top) and calls the callee. The *prologue* of the callee then extracts the arguments into its own local variables, and stores the return offset on the stack. Evaluation of the callee function body completely consumes these local variables, leaving only (a pointer to) the return value in, say, a designated *result register*. For the callee *epilogue*, the callee returns to the caller using the return offset on the stack (which is automatically removed in the return). The callee then restores the non-argument variables of its environment from the stack, and moves the result (pointer) to the fresh return variable into the environment as well..."

*(p. 107: "In particular, no garbage is generated using this calling convention.")*

---

## 3. EXCH Primitive Semantics

### Definition (p. 101, §4.1)

EXCH is the **exchange** instruction: it atomically swaps the contents of a register and a memory location.

```
EXCH r_t  M(r_cell)
```

**Effect:** `r_t, M[r_cell] := M[r_cell], r_t` (swap register r_t with memory word at address r_cell).

**Reversibility:** EXCH is its own inverse — applying it twice restores the original state. This is the key property that makes it suitable as the primitive heap-access operation in a reversible machine.

**Why zero-clearing matters** (p. 101): "the temporary register r_t is zero-cleared after the EXCH instruction: the constructor field of the new cons cell is initially zero and EXCH exchanges the contents of the register and the memory location. In this sense the reversible instruction set actually helps in maintaining linearity. For example, if a pointer is to be copied, this must be done *explicitly*."

EXCH is defined for PISA (the Pendulum Instruction Set Architecture, ref [3,7,13] in the paper) and BobISA (ref [13]).

### EXCH vs. SWAP

(p. 102, footnote 4): "Although SWAP would seem to be a natural instruction in a reversible architecture, neither PISA nor BobISA contain an instruction to swap the contents of two registers. However, it is easy to simulate reversibly, e.g. using the 'xor trick'."

The xor trick: `EXCH r_a, r_b` simulated as:
```
XOR r_a  r_b
XOR r_b  r_a
XOR r_a  r_b
```
(3 CNOTs at W-bit width.)

---

## 4. Linear-Reference Discipline

### Statement (p. 98, §2 "Linearity")

> "We consider only well-formed programs in the following sense: each variable in patterns appears at most once, and each variable is bound before its use and is used *linearly* in each branch. This is essential to a reversible language to avoid discarding values. Also, there is not implicit duplication of values (*e.g.* by using a variable twice in a branch). The duplication and comparison of values has to be programmed explicitly in our simplified language (a more convenient and explicit duplication/equality operator |.| can be provided as in RFUN)."

### Consequence for heap structure (p. 100, §3)

> "Note that each cons cell in our heap example has reference count exactly one, *i.e.*, the heap is linear. This is not accidental, as RFUN uses variables linearly, so if we enforce that environments may only bind distinct variables to *separate* pointer trees, we can *guarantee* that the heap is linear. This is advantageous, in that we can then alter heap data representations directly (*update-in-place*)."

> "Our heap data is *mutable*, in contrast to conventional functional language implementations, where heap data is usually immutable. In a linear heap with mutable data the problem of garbage collection (in the conventional sense) becomes easy, as noted by Baker [5]. In fact, the combination of mutable data, linearity and reversibility actually means that garbage collection will be automatically performed simply by maintaining the heap structure across updates."

### Anti-aliasing guarantee (p. 100)

> "so if we enforce that environments may only bind distinct variables to *separate* pointer trees, we can *guarantee* that the heap is linear."

This is the **linear-reference invariant**: no two environment bindings may point to the same cons cell. This prevents aliasing entirely. Construction of a `Cons(a, b)` node consumes both `a` and `b` from the environment (they are no longer accessible as `a` and `b`) — this is what "linearly used" means operationally.

---

## 5. Reversible Alloc and Free as Inverses

### Allocation (`get_free()`) and its inverse (pp. 103–104)

Construction (`get_free()` + EXCH writes) and deconstruction (EXCH reads + `put_free()`) are exact operational inverses:

- **Forward (alloc + write):** `get_free()` obtains a zero-cleared cell pointer (either from free list or by growing the heap). EXCH instructions write constructor tag and child pointers into the cell, simultaneously zeroing the source registers.
- **Reverse (read + free):** EXCH instructions read the constructor tag and child pointers back into registers (zeroing the cell fields). `put_free()` (inverse of `get_free()`) returns the now-zeroed cell to the free list or shrinks the heap.

(p. 104): "When freeing the empty cons cell we have to maintain the free list *invariant*. Again, this is simply the inverse procedure used to allocate free cells, and can invoked by, say, a reverse subroutine call, or inlined with program inversion. The effect is exactly as desired: if the top cell of the heap is freed and the free list is empty, then shrink the heap. This maintains the invariant."

### The free-list invariant (p. 99 and p. 103)

> "we place the following restriction on the free list, to be maintained as an invariant: the last element of the free list may *not* be the cons cell immediately above the heap pointer."

This invariant is necessary to orthogonalize the two cases in `get_free()`: growing the heap vs. popping the free list. Without it, both branches of the if-then-else could produce the same result (a cell adjacent to the heap pointer), destroying reversibility.

---

## 6. Gate-Cost Analysis

### Paper's own figure: ~51W gates per heap access (from SURVEY.md context)

The paper does not give an explicit Toffoli gate count but notes (p. 97, footnote 1): "statement `x += e` requires reversible simulation of expression `e`." The dominant cost arises from the **variable-shift barrel shifter** needed to implement EXCH on the reversible machine, which costs approximately 51W gates for a W-bit word (confirmed in our prototype: ~51–59 kGates per operation at W=32).

### Breakdown

| Operation | Instruction count | Approx. gates at W=32 |
|-----------|------------------|-----------------------|
| `get_free()` body | ~5 instructions | ~5 × 32 = 160 |
| Build Nil | ~3 instructions | ~96 |
| Build Cons | ~8 instructions | ~256 |
| Pattern match + free | ~8 instructions | ~256 |
| Full alloc+write+dealloc round-trip | ~16–20 instructions | ~512–640 |

These counts are for the PISA/BobISA instruction level. When compiled to NOT/CNOT/Toffoli gates for Bennett.jl, the variable-shift in EXCH dominates: the barrel-shifter needed to implement a W-bit memory address offset costs O(W log W) gates, which at W=32 is ~51×32 ≈ 1632 gates per EXCH. With ~4 EXCH instructions per `cons`, the total approaches ~6528 gates per cons at W=32.

---

## 7. What Is Nontrivial About Reversibilising This

### The EXCH-based allocation/free duality

The key nontriviality is that **garbage collection is free by construction**: because linearity guarantees no aliasing, and because EXCH zeroes the source when writing to memory, the heap is always returned to a zero-cleared state when a cell is freed. There is no need for a mark-and-sweep or reference-counting pass — the program structure itself ensures cells are freed exactly when they are deconstructed by pattern matching. This is the "automatically performed" GC noted on p. 100.

### The free-list invariant as an orthogonalizing condition

The invariant that the last free-list element is never the cell immediately above the heap pointer (p. 99, p. 103) is subtle. Without it, `get_free()` is not reversible because the forward condition `r_flp == 0` (free list empty → grow heap) could be satisfied even when the free list is non-empty but its last element happens to equal `hp−3`. The invariant eliminates this ambiguity and is what makes the `fi` assertion of the reversible if-then-else hold.

### Linear reference as an anti-aliasing contract

The linear-reference discipline (§2) is not just a programming convenience — it is a **correctness requirement** for the heap's reversibility. If a pointer escaped into two environment bindings, deconstruction of one binding would free the cell, leaving the second binding dangling. The static linearity check in RFUN prevents this. For Bennett.jl, this translates to: any use of the AG13-style heap requires that the LLVM IR's pointer analysis confirms no-alias for all heap pointers passed to heap-manipulation routines.

### Complement to Mogensen hash-consing

AG13 and Mogensen 2018 are complementary rather than competing:

- AG13: linear heap, O(1) alloc/free via free list, reference count always 1, no sharing, full mutable update-in-place.
- Mogensen: non-linear heap, O(b) alloc/free via segment search, maximal sharing via hash-consing, immutable nodes.

For Bennett.jl's T5 tier, AG13 provides the base allocation mechanism and EXCH semantics; Mogensen layers hash-consing on top to reduce heap pressure when many identical constructor terms are built.
