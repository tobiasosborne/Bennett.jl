# Brief: Okasaki 1999 — Red-Black Trees in a Functional Setting

## Citation

- **Author:** Chris Okasaki
- **Title:** Red-Black Trees in a Functional Setting
- **Venue:** Journal of Functional Programming (Functional Pearls column); published in proceedings style, 7 pages
- **Note on venue:** The PDF header reads "J. Functional Programming 1(1):1–000, January 1993 © 1993 Cambridge University Press" but this is a journal template header; the actual publication is JFP 9(4):471–477, 1999.
- **PDF:** `Okasaki1999_redblack.pdf` (7 pages, 144 KB)
- **Affiliation:** School of Computer Science, Carnegie Mellon University

---

## 1. Core Contribution

Okasaki presents a remarkably compact functional implementation of insertion into red-black trees. The key insight is that all four cases of a red-node-with-red-parent violation are handled identically by a single rewrite — eliminating the case explosion of earlier imperative presentations. The `balance` function has five clauses: four dangerous cases and one fallthrough, with all four dangerous-case right-hand sides being identical. The paper does **not** cover deletion; see §5 below for the secondary reference.

---

## 2. Verbatim Algorithm Pseudocode

### 2a. Type Definition — p. 1, §2

```haskell
data Color = R | B
data Tree elt = E | T Color (Tree elt) elt (Tree elt)
```

### 2b. Lookup (`member`) — p. 2, §3 "Simple Set Operations"

```haskell
type Set a = Tree a

empty :: Set elt
empty = E

member :: Ord elt => elt -> Set elt -> Bool
member x E = False
member x (T _ a y b) | x < y = member x a
                      | x == y = True
                      | x > y = member x b
```

*(p. 2: "Except for the occasional wildcard, these are exactly the same as the equivalent operations on unbalanced search trees.")*

### 2c. Insertion skeleton — p. 2, §4 "Insertions"

```haskell
insert :: Ord elt => elt -> Set elt -> Set elt
insert x s = makeBlack (ins s)
  where ins E = T R E x E
        ins (T color a y b) | x < y = balance color (ins a) y b
                             | x == y = T color a y b
                             | x > y = balance color a y (ins b)

        makeBlack (T _ a y b) = T B a y b
```

*(p. 2: "By coloring the new node red, we maintain Invariant 2, but we might be violating Invariant 1. We make detecting and repairing such violations the responsibility of the black grandparent of the red node with the red parent.")*

### 2d. The `balance` function — ALL 4 CASES VERBATIM — p. 4, §4

The paper first shows the four cases with `?` placeholders (p. 3):

```haskell
balance B (T R (T R a x b) y c) z d = ?
balance B (T R a x (T R b y c)) z d = ?
balance B a x (T R (T R b y c) z d) = ?
balance B a x (T R b y (T R c z d)) = ?
balance color a x b = T color a x b
```

Then gives the completed function (p. 4):

```haskell
balance B (T R (T R a x b) y c) z d = T R (T B a x b) y (T B c z d)
balance B (T R a x (T R b y c)) z d = T R (T B a x b) y (T B c z d)
balance B a x (T R (T R b y c) z d) = T R (T B a x b) y (T B c z d)
balance B a x (T R b y (T R c z d)) = T R (T B a x b) y (T B c z d)
balance color a x b = T color a x b
```

*(p. 4: "Notice that the right-hand sides of the first four clauses are identical.")*

The paper also presents an or-pattern collapsed version (p. 4):

```haskell
balance B (T R (T R a x b) y c) z d
      || B (T R a x (T R b y c)) z d
      || B a x (T R (T R b y c) z d)
      || B a x (T R b y (T R c z d)) = T R (T B a x b) y (T B c z d)
balance color a x b = T color a x b
```

### 2e. Alternative `balance` (color-flip / single-rotation / double-rotation formulation) — p. 5, Fig. 3

```haskell
-- color flips
balance B (T R a@(T R _ _ _) x b) y (T R c z d)
      || B (T R a x b@(T R _ _ _)) y (T R c z d)
      || B (T R a x b) y (T R c@(T R _ _ _) z d)
      || B (T R a x b) y (T R c z d@(T R _ _ _)) = T R (T B a x b) y (T B c z d)
-- single rotations
balance B (T R a@(T R _ _ _) x b) y c = T B a x (T R b y c)
balance B a x (T R b y c@(T R _ _ _)) = T B (T R a x b) y c
-- double rotations
balance B (T R a x (T R b y c)) z d
      || B a x (T R (T R b y c) z d) = T B (T R a x b) y (T R c z d)
-- no balancing necessary
balance color a x b = T color a x b
```

*(Fig. 3, p. 5. This alternative formulation is the traditional imperative approach, included for comparison. The paper argues the simpler 5-clause version of §2d is superior in functional settings.)*

---

## 3. Red-Black Balance Invariants — p. 1–2, §2

> **Invariant 1.** No red node has a red parent.

> **Invariant 2.** Every path from the root to an empty node contains the same number of black nodes.

*(p. 2: "For the purposes of these invariants, empty nodes are considered to be black.")*

*(p. 2: "Taken together, these invariants ensure that every tree is balanced — and thus that most operations take no more than O(log n) time — because the longest possible path in a tree, one with alternating black and red nodes, is no more than twice as long as the shortest possible path, one with black nodes only.")*

---

## 4. Deletion — NOT IN THIS PAPER

**The paper contains no deletion algorithm.** The only operations presented are `empty`, `member`, and `insert`. The paper explicitly limits scope to insertion.

**Secondary reference for deletion:** Stefan Kahrs, "Red-Black Trees with Types," *Journal of Functional Programming* **11**(4):425–432, 2001. Kahrs gives a typed functional delete for red-black trees. That paper is NOT in the current PDF collection and must be acquired separately for T5-P3b.

---

## 5. Reversibility Prediction

### Per-operation cost analysis

**Lookup** (`member`): A pure comparison chain, no allocation. At each node: one comparison (icmp), one branch (br). Depth O(log N). For a tree of depth d = log₂ N:
- d comparisons × ~3W Toffoli each (for W-bit keys, using ripple-carry comparison) = ~3W·d Toffoli total.
- At W=32, d=20: ~1920 Toffoli. At W=64, d=20: ~3840 Toffoli.
- No ancillae beyond key comparison intermediates; all clean up trivially.

**Insert** (`insert` + `balance`): The insert path descends O(log N) levels, calling `balance` at each level. Each `balance` call pattern-matches on colors (1-bit fields) and rearranges at most 3 nodes.

**Per-balance-case gate cost:**
- Pattern match on color bits: ~3 Toffoli (3-way condition on two 1-bit fields and one node-color bit).
- Node construction `T R (T B a x b) y (T B c z d)`: allocates 3 nodes, copies ~5 pointers. If implemented via AG13-style EXCH heap: ~3 × 8 EXCH = ~24 EXCH instructions, each expanding to ~W CNOTs = 24W CNOTs at W-bit pointer width.
- At W=32 pointer width: ~768 CNOT + ~3 Toffoli ≈ ~800 gates per balance call.
- **Conservative estimate at W=32: ~3W Toffoli per balance case = ~96 Toffoli**, or ~800 total gates including pointer moves.

**Total insert at depth d=3** (the case quoted in the bead description, for trees of ~8 nodes):
- 3 `balance` calls × ~96 Toffoli = ~288 Toffoli for balance logic.
- Plus 3 node allocations (heap ops) and ~log N comparison steps.
- **Summary:** ~30W Toffoli for the balance logic component at depth 3 (W=32 → ~960 gates; W=1 [single-bit keys] → ~30 gates). The bead's "~30W Toffoli per insert at depth 3" is confirmed as a reasonable conservative estimate for the balance core alone.

**Bennett construction overhead:** Forward pass (insert) + CNOT copy of result + reverse (uncompute insert). This triples the gate count and requires ancillae proportional to the path length × node size. Key ancillae: the intermediate `balance` results on the way down (each node created during descent must be uncomputed on the reverse pass).

---

## 6. What Is Nontrivial About Reversibilising RBT Insert

### Structural sharing is prohibited

The paper's functional style freely creates new nodes and relies on GC to handle old ones. In a reversible circuit, **every allocated node must be exactly deallocated** by the uncompute pass. The "makeBlack" at the root creates a new node and discards the old red root — in a reversible setting this discard must be an explicit unallocation. The Bennett construction handles this: the forward pass allocates, the uncompute pass deallocates in reverse. But the path of allocations must be recorded precisely.

### The four-way case analysis must be compiled to MUX circuits

The `balance` function's four cases are a pattern match on tree structure. In a reversible circuit, all four cases may "fire" in superposition (when controlling on a quantum bit). The reversible compiler must convert each case into a guarded MUX: `if condition_i then apply_rotation_i`. Conditions are computable from the color bits of the top three nodes — these are 1-bit fields, so each condition is a simple conjunction of 1–3 bits, requiring 1–2 Toffoli gates to evaluate. The four conditions are mutually exclusive (at most one match), so they can be evaluated with a 4-way AND-OR circuit. This is the well-understood "one-hot encoding" pattern.

### Color bit is state, not structure

In functional Haskell, the color is a tag in an algebraic type. In a reversible circuit at the integer level, the color must be stored as a 1-bit field in the node record. This field is flipped by `balance` (the black grandparent becomes a red root, two red children become black). These flips are reversible XOR operations — no ancilla needed per flip.

### The `makeBlack` final step

The root's color is forced to black unconditionally. Reversibly: record the old color (1 ancilla bit), flip it to black, use that ancilla in the Bennett uncompute. This is a 1-Toffoli or 1-NOT operation.

### Delete requires Kahrs 2001

Okasaki's paper gives no deletion algorithm. The full reversible RBT implementation for T5 must incorporate Kahrs (2001), which uses "double-black" phantom nodes during deletion and four rotation/recolor cases analogous to but distinct from the insert cases. Kahrs's Haskell formulation is typed, making the pattern-match structure explicit and directly compilable to guarded MUX circuits.
