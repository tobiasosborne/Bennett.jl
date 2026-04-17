# Brief: Mogensen 2018 — Reversible GC via Hash-Consing

## Citation

- **Authors:** Torben Ægidius Mogensen
- **Title:** Garbage Collection for Reversible Functional Languages
- **Venue:** New Generation Computing 36:203–232 (2018)
- **DOI:** https://doi.org/10.1007/s00354-018-0037-3
- **Springer URL:** https://link.springer.com/article/10.1007/s00354-018-0037-3
- **PDF:** `Mogensen2018_reversible_gc.pdf` (21 pages, 3.0 MB)
- **Affiliation:** DIKU, University of Copenhagen

---

## 1. Core Contribution

The paper presents the **first reversible garbage collection method that does not rely on linearity**. Previous reversible heap managers (e.g., Axelsen & Glück 2013) required every heap node to have exactly one reference (linearity). This paper achieves **maximal sharing** (hash-consing): if a newly constructed node is identical to an existing node, the existing node's reference count is incremented and the existing pointer is returned rather than allocating a new cell. Construction and deconstruction are exact inverses. The heap manager is implemented in RIL (a reversible intermediate language) and benchmarked.

---

## 2. Verbatim Algorithm Pseudocode

### 2a. Value Copying (`copy` subroutine) — p. 212, §"Value Copying"

```
begin copy
assert copyP > 0 && copyQ == 0
copyP !& 3 ⇒ M[copyP] += 1
copyQ += copyP
assert copyP > 0 && copyQ == copyP
end copy
```

*Semantics:* Copies value `copyP` into `copyQ` (initially zero). If the value is a pointer (two least significant bits are 00, i.e., `copyP !& 3` is false — note: the condition `copyP !& 3` means `!(copyP & 3)`, i.e., the pointer case), the reference count at `M[copyP]` is incremented. Otherwise (integer or symbol) the value is simply copied. Calling `copy` in reverse decrements the reference count (or just zeroes `copyQ` for non-pointers).

### 2b. Copying Fields of a Cons Node (`fields` subroutine) — p. 212–213, §"Copying the Fields of a Cons Node"

```
begin fields
assert fieldsP !& 3 && fieldsA == 0 && fieldsD == 0
fieldsP += 4
fieldsA += M[fieldsP]
fieldsA !& 3 ⇒ M[fieldsA] += 1
fieldsP += 4
fieldsD += M[fieldsP]
fieldsD !& 3 ⇒ M[fieldsD] +=1
fieldsP -= 8
assert fieldsP !& 3 && fieldsA > 0 && fieldsD > 0
end fields
```

*Semantics:* Takes pointer `fieldsP`, copies its two child fields into `fieldsA` and `fieldsD` (initially zero), incrementing reference counts of any pointer-typed children. Called in reverse: `fieldsA` and `fieldsD` must equal the fields of `fieldsP`; they are cleared and reference counts decremented.

### 2c. Naive `cons` — p. 214, Fig. 3

```
begin cons
assert consA != 0 && consD != 0 && consP == 0
consP += H
/* search for identical node */
consSearchSame ← consP > H
  M[consP] == 0 → consNext
    consP += 4
    M[consP] != consA → consNotA
      consP += 4
      M[consP] == consD → consFoundSame    /* identical node found */
        consP -= 4
        consNotA ← M[consP] != consA
        consP -= 4
  consNext ← M[consP] == 0
  consP += 12
consP <= lastH → consSearchSame
/* end of heap reached, search for empty node */
consSearchEmpty ← consP <= lastH
  consP < H → consFail    /* no empty node found, allocation fails */
  M[consP] != 0 → consSearchEmpty
    /* empty node found, store node in this */
    M[consP] += 1
    consP += 4
    consA ↔ M[consP]
    consP += 4
    consD ↔ M[consP]
    consP -= 8
consEnd ← M[consP] > 1
assert consP !& 3 && consP >= H && consA == 0 && consD == 0
end cons

consFoundSame ←
  /* identical node found, update reference counts and return node */
  consD !& 3 ⇒ M[consD] -= 1
  consD -= M[consP]
  consP -= 4
  consA !& 3 ⇒ M[consA] -= 1
  consA -= M[consP]
  consP -= 4
  M[consP] += 1
→ consEnd
```

*Semantics (forward):* Given `consA` and `consD` (the two fields to cons), returns a pointer `consP` to a Cons-cell containing those fields, allocating a new cell or reusing an existing identical cell. On reuse, decrements reference counts of `consA` and `consD` (since the existing node already holds references to those values) and increments the cell's own reference count.

*Semantics (reverse / `uncall cons`):* Given `consP`, returns `consA` and `consD`. If `consP` has reference count 1 (unshared), the cell is deallocated (reference count and fields zeroed). If reference count > 1 (shared), only the reference count is decremented and the field values are restored in `consA` and `consD` (with their reference counts incremented back).

### 2d. Optimised `cons` with hashing — p. 216, Fig. 4

```
begin cons
assert consA != 0 && consD != 0 && consP == 0 && segBegin == 0 && segEnd == 0
call hash    /* find segment address */
consP += segBegin
segEnd += segBegin + (12b−12)
/* search for identical node in segment */
consSearchSame ← consP > segBegin
  M[consP] == 0 → consNext
    consP += 4
    M[consP] != consA → consNotA
      consP += 4
      M[consP] == consD → consFoundSame    /* identical node found */
        consP -= 4
      consNotA ← M[consP] != consA
      consP -= 4
  consNext ← M[consP] == 0
  consP += 12
consP <= segEnd → consSearchSame
/* end of segment reached, search for empty node */
consSearchEmpty ← consP <= segEnd
  consP < segBegin → consFail    /* no empty node in segment, allocation fails */
  M[consP] != 0 → consSearchEmpty
    /* empty node found, store node in this */
    segEnd -= segBegin + (12b−12)
    uncall hash
    M[consP] += 1
    consP += 4
    consA ↔ M[consP]
    consP += 4
    consD ↔ M[consP]
    consP -= 8
consEnd ← M[consP] > 1
assert consP !& 3 && consP >= H && consA == 0 && consD == 0
assert segBegin == 0 && segEnd == 0
end cons

consFoundSame ←
  /* identical node found, update reference counts and return node */
  segEnd -= segBegin + (12b−12)
  uncall hash
  consD !& 3 ⇒ M[consD] -= 1
  consD -= M[consP]
  consP -= 4
  consA !& 3 ⇒ M[consA] -= 1
  consA -= M[consP]
  consP -= 4
  M[consP] += 1
→ consEnd
```

### 2e. Jenkins 96-bit Reversible Mix Function (`hash` subroutine) — p. 217–218, Fig. 5

> The full Jenkins hash as implemented in RIL. Input: `consA`, `consD` (non-zero); `segBegin` = 0. Output: `segBegin` holds the segment start address; `consA`, `consD` unchanged. `hashA`, `hashB`, `hashC` are globally initialised to constants k_a, k_b, k_c.

```
begin hash
assert segBegin == 0 && hashA == k_a && hashB == k_b && hashC == k_c
hashA ^= consA
hashB ^= consD
hashA += hashB + hashC
hashA ^= hashC >> 13
hashB -= hashC + hashA
hashB ^= hashA << 8
hashC += hashA + hashB
hashC ^= hashB >> 13
hashA -= hashB + hashC
hashA ^= hashC >> 12
hashB += hashC + hashA
hashB ^= hashA << 16
hashC -= hashA + hashB
hashC ^= hashB >> 5
hashA += hashB + hashC
hashA ^= hashC >> 3
hashB -= hashC + hashA
hashB ^= hashA << 10
hashC += hashA + hashB
hashC ^= hashB >> 15
segBegin += hashC & mask
segBegin += hashC & mask
segBegin += hashC & mask
segBegin += H
end hash
```

*(Fig. 5, p. 218. Three additions of `hashC & mask` multiply by 3 to get a valid aligned segment address for overlapping segments. For non-overlapping segments the mask is `4(2^m − b)` and multiplication is by 12b.)*

**Reversal of `hash`:** `uncall hash` resets `hashA`, `hashB`, `hashC` to their original constant values and clears `segBegin` to zero.

### 2f. Simplified `hash` subroutine — p. 220, Fig. 6

```
begin hash
assert segBegin == 0 && hashT == k_a
hashT ^= consA << 7
hashT += consA >> 1
hashT ^= consD << 5
hashT += consD >> 3
segBegin += hashT & mask
segBegin += hashT & mask
segBegin += hashT & mask
segBegin += H
end hash
```

*(Fig. 6, p. 220. Simpler variant — 8 instructions in the body vs. 24 for Jenkins. Experimentally comparable performance for these workloads.)*

---

## 3. Reference-Counting Reversibility Scheme

### Core invariant (p. 205, §Introduction)

> "If a newly constructed node is identical to an already existing node, we return a pointer to the existing node (increasing its reference count) instead of allocating a new node with reference count one."

> "Whenever a node is taken apart by pattern matching, it is freed."

### Reversibility condition (p. 215, §"Naive Implementation of cons")

> "When called in reverse, `cons` takes a pointer `consP` and two uninitialised (zeroed) variables `consA` and `consD`, and returns in `consA` and `consD` the values of the fields of the node pointed to by `consP`, while clearing `consP`. If the node pointed to by `consP` is unshared (indicated by reference count 1), it is deallocated by setting the reference count and the fields to 0. Otherwise, the reference count is just decremented and the fields preserved."

### Reference count at allocation vs. reuse (p. 213–214)

- **New allocation:** reference count set to 1; `consA` and `consD` are *swapped* into the fields (clearing the variables). The references originally in `consA`/`consD` are now owned by the new cell.
- **Reuse of existing identical cell:** reference count incremented by 1; `consA` and `consD` are *decremented* (their reference counts are decremented if they are pointers, and the variables are cleared). The cell already held references to those values, so the caller's references are discarded.

### Symmetry of construction and deconstruction (p. 203, Abstract)

> "Since constructing a node creates exactly one reference to this node, the inverse can only be applied if the reference count is exactly one."

> "We can overcome this limitation if constructing a node can return a node with multiple references."

---

## 4. Performance: Instruction Count

(p. 218, §"Performance Analysis and Experiments")

- **Best case** (non-pointer arguments, first node searched is a match): **71 instructions**, of which **52 are used by the two calls to `hash`**.
- **Worst case** (all nodes in segment match on `consA` but not `consD`, no free node found in segment): **15b + 58 instructions**, of which **52** are again used by `hash`.
- The segment size `b` is the dominant factor in worst-case cost; `b = 32` gives ~50% average heap utilisation.

---

## 5. Reversibility Prediction for Bennett.jl

### What the paper counts

The paper counts RIL *instructions* (updates + exchanges + conditional jumps), not Toffoli gates. A RIL update `x ^= y` maps to a CNOT (or chain of CNOTs for W-bit words); a conditional `c ⇒ x ^= y` maps to a Toffoli. The mapping is one-to-many.

### Estimated gate cost at width W

| Operation | RIL instructions (best case) | Approx. Toffoli gates at W=32 |
|-----------|------------------------------|-------------------------------|
| `hash` (Jenkins, one call) | 26 | ~26 × W = 832 |
| `hash` (Jenkins, two calls in `cons`) | 52 | ~1664 |
| `cons` best case total | 71 | ~71 × W ≈ 2272 |
| `cons` worst case (b=32 segment) | 15×32 + 58 = 538 | ~538 × W ≈ 17216 |

These are rough lower bounds: each RIL arithmetic step at W=32 bits expands to at least W one-bit operations. Memory-access steps (EXCH of a 32-bit word) expand to W CNOTs. Conditional arithmetic steps (`c ⇒ x ^= y`) expand to W Toffolis.

At W=64 (Julia's `Int64`): double the above. Hash itself becomes ~3328 gates per call at W=64, and a best-case `cons` ~4544 gates.

---

## 6. What Is Nontrivial About Reversibilising Hash-Consing

### The forward-direction problem: reuse vs. new allocation

When `cons(a, d)` finds an identical existing cell, the reversible semantics **discards the caller's references to `a` and `d`** rather than placing them in the cell. This is nontrivial: in the reverse direction (deconstruction), the system must know whether it is "un-allocating a new cell" (reference count was 1, so set everything to 0) or "un-reusing a shared cell" (reference count > 1, so decrement and restore `a`, `d` with incremented reference counts). The branching is on `M[consP] > 1`, checked at `consEnd`. This is the dual of the allocation decision and is the source of the complexity in the reverse direction.

### The bug in the RC 2015 conference version (p. 217)

> "The conference version of this paper [18] has an error in the optimised `cons` procedure: When searching for an unallocated node, the search did not stop at `segBegin`, but continued all the way down to `H`. This made allocation more likely to succeed, but broke the property that identical nodes have identical locations and made allocation much slower."

This is precisely the kind of subtle invariant violation the SURVEY.md warns about: the identity-implies-same-location property is critical to correctness of reverse execution.

### Limitation: immutability of shared nodes

Hash-consed nodes **cannot be modified after construction** (p. 205). The memory manager is therefore only suitable for pure functional data — it cannot be used for mutable arrays or mutable fields. For Bennett.jl, this means the hash-cons table is only applicable to constructor-term representations of values, not to general LLVM `store` targets.

---

## 7. Relationship to AG13 (Axelsen & Glück 2013)

Mogensen explicitly extends AG13's heap manager (cited as [1] in the paper). AG13 requires linearity (reference count always 1). Mogensen lifts this via maximal sharing. The EXCH instruction used in AG13 for allocation/deallocation is preserved in spirit: RIL's `↔` exchange is the same primitive. The key difference is that Mogensen's `cons` must perform a segment search (O(b) steps) whereas AG13's allocation is O(1) via the free list.
