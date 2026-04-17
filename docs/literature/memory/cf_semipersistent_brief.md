# Brief: Conchon & Filliâtre 2007 — A Persistent Union-Find Data Structure

## Citation

- **Authors:** Sylvain Conchon and Jean-Christophe Filliâtre
- **Title:** A Persistent Union-Find Data Structure
- **Venue:** ACM SIGPLAN Workshop on ML (ML 2007), October 5, 2007, Freiburg, Germany
- **DOI:** ACM copyright 2007
- **PDF:** `ConchonFilliatre2007_PUF.pdf` (9 pages, 138 KB)
- **Affiliation:** LRI, Univ Paris-Sud, CNRS, Orsay F-91405; INRIA Futurs, ProVal

---

## 1. Core Contribution

The paper presents a persistent union-find data structure that matches the time complexity of the optimal imperative Tarjan algorithm while exposing a purely persistent interface. The key mechanism: a **persistent array** implemented via a version-tree (a linked list of `Diff` nodes pointing back to an `Arr` node holding the actual array), with a **rerooting** operation that lazily moves the `Arr` node to the most-recently-accessed version. This gives O(1) amortized access when used linearly (no branching), degrading gracefully under backtracking.

The paper also provides a Coq proof of correctness and observational persistence.

---

## 2. Version-Tree Construction — Verbatim OCaml

### 2a. Persistent Array Type — p. 3, §2.3 "Efficient Implementation of Persistent Arrays"

```ocaml
type α t = α data ref
and α data =
  | Arr of α array
  | Diff of int × α × α t
```

*(p. 3: "The type α t is the type of persistent arrays. It is a reference on a value of type α data which indicates its nature: either an immediate value Arr a with an array a, or an indirection Diff(i, v, t) standing for a persistent array which is identical to the persistent array t everywhere except at index i where it contains v. The reference may seem superfluous but it is actually crucial.")*

**Invariant** (p. 3): "the graph of references of type α t for the various versions of a persistent array is acyclic and from any of these references there is a unique path to the Arr node."

### 2b. Creating a New Persistent Array — p. 3, §2.3

```ocaml
let init n f = ref (Arr (Array.init n f))
```

### 2c. `get` (access) — p. 3, §2.3

```ocaml
let rec get t i = match !t with
  | Arr a →
      a.(i)
  | Diff (j, v, t') →
      if i == j then v else get t' i
```

### 2d. `set` (update) — p. 3, §2.3

```ocaml
let set t i v = match !t with
  | Arr a as n →
      let old = a.(i) in
      a.(i) ← v;
      let res = ref n in
      t := Diff (i, old, res);
      res
  | Diff _ →
      ref (Diff (i, v, t))
```

*(p. 3: "either t is a reference to an object of shape Arr a; in that case, we are going to replace t with an indirection (which is possible since it is a reference and not a value of type α data), modify the array a in place and return a new reference pointing to Arr a.")*

---

## 3. Rerooting Algorithm — VERBATIM OCaml

### Source: p. 4, §2.3.2 "A Major Improvement"

*(p. 4: "H. Baker introduces a very simple improvement [5]: as soon as we try to access a persistent array which is not an immediate array we first reverse the linked list leading to the Arr node, to move it in front of the list, that is precisely where we want to access. This operation, that Baker calls rerooting, can be coded by the following reroot function which takes a persistent array as argument and returns nothing; it simply modifies the structure of pointers, without modifying the contents of the persistent arrays.")*

```ocaml
let rec reroot t = match !t with
  | Arr _ → ()
  | Diff (i, v, t') →
      reroot t';
      begin match !t' with
        | Arr a as n →
            let v' = a.(i) in
            a.(i) ← v;
            t := n;
            t' := Diff (i, v', t)
        | Diff _ → assert false
      end
```

*(p. 4: "After calling this function, we have the property that t now points to a value of the shape Arr.")*

Updated `get` using `reroot` (p. 4):

```ocaml
let rec get t i = match !t with
  | Arr a →
      a.(i)
  | Diff _ →
      reroot t;
      begin match !t with
        | Arr a → a.(i)
        | Diff _ → assert false
      end
```

Updated `set` using `reroot` (p. 4):

```ocaml
let set t i v =
  reroot t;
  match !t with
  | Arr a as n → ... as previously ...
  | Diff _ → assert false
```

### 3a. Semi-persistent variant with `Invalid` nodes — p. 4–5, §2.3.3 "Final Improvements"

*(p. 4: "It is striking to notice that the final data structure we get is actually nothing more than a usual array together with an undo stack, that is the backtracking design pattern of the imperative programmer.")*

Extended type with `Invalid` constructor (p. 4):

```ocaml
type α t = α data ref
and α data =
  | Arr of int array
  | Diff of int × α × α t
  | Invalid
```

Modified `reroot` for semi-persistence (p. 4–5):

```ocaml
let rec reroot t = match !t with
  | Arr _ → ()
  | Diff (i, v, t') →
      reroot t';
      begin match !t' with
        | Arr a as n →
            a.(i) ← v;
            t := n;
            t' := Invalid
        | Diff _ | Invalid → assert false
      end
  | Invalid → assert false
```

*(p. 5: "As we can notice, we save the allocation of a Diff node.")*

---

## 4. Persistent Union-Find — Verbatim OCaml

### Source: p. 2–3, §2.2 "A Persistent Version of Tarjan's Union-Find Algorithm"

```ocaml
module Make(A : PersistentArray)
  : PersistentUnionFind
= struct
```

```ocaml
type t = {
  rank: int A.t;
  mutable parent: int A.t
}
```

```ocaml
let create n = {
  rank = A.init n (fun _ → 0);
  parent = A.init n (fun i → i)
}
```

`find_aux` with path compression (p. 3):

```ocaml
let rec find_aux f i =
  let fi = A.get f i in
  if fi == i then
    f, i
  else
    let f, r = find_aux f fi in
    let f = A.set f i r in
    f, r
```

`find` with side-effecting path compression (p. 3):

```ocaml
let find h x =
  let f,cx = find_aux h.parent x in
  h.parent ← f;
  cx
```

`union` (p. 3):

```ocaml
let union h x y =
  let cx = find h x in
  let cy = find h y in
  if cx != cy then begin
    let rx = A.get h.rank cx in
    let ry = A.get h.rank cy in
    if rx > ry then
      { h with parent = A.set h.parent cy cx }
    else if rx < ry then
      { h with parent = A.set h.parent cx cy }
    else
      { rank = A.set h.rank cx (rx + 1);
        parent = A.set h.parent cy cx }
  end else
    h
```

---

## 5. Semi-Persistence and Its Relationship to Reversibility's Linearity Model

### What semi-persistence means

The `Invalid` variant (§3a above) makes the data structure **semi-persistent**: once you backtrack to a previous version, the newer versions become invalid and cannot be accessed again. The paper states (p. 5):

> "The most efficient version we finally obtained actually uses arrays that are not fully persistent. Indeed, they must only be used to come back to previous versions (which is the typical use of persistent structures in a backtracking algorithm). This semi-persistence currently has a dynamic nature (the data is made invalid when we do the backtrack) but it would be even more efficient if we checked statically the legal use of this semi-persistence."

**Concretely:** the version graph is a chain (path), not a tree. At any moment exactly one version is "current" (holds the `Arr` node); all others are either forward-`Diff` nodes (newer, invalid after backtrack) or backward-`Diff` nodes (older, accessible via `reroot`).

### KEY INSIGHT for T5: Semi-persistence exposes exactly one live version chain

This is the critical observation for T5's reversible data structure tier:

- **Bennett's construction** operates on a single tape: the circuit computes forward (building up a state), then copies the output, then runs in reverse (uncomputing the state). The "tape" is exactly a linear chain of versions: v₀ → v₁ → ... → vₙ → copy → vₙ → ... → v₀.
- **A semi-persistent data structure** exposes exactly this structure: one root (the initial version `Arr`), a chain of `Diff` nodes going forward in time, and the `reroot` operation that moves the `Arr` node along the chain.
- **The uncompute pass** in Bennett's construction corresponds exactly to `reroot` moving backward along the `Diff` chain: each `reroot` step reverses one `set` operation, restoring the previous array state and invalidating the newer version.

In other words: **the semi-persistent array IS Bennett's tape for array data structures.** The `Arr` node tracks the current "scratch" state; the `Diff` nodes encode the history needed to uncompute. The `reroot` function IS the uncompute step.

### Why full persistence would break this

A fully persistent data structure allows branching: two different versions can both be current simultaneously. In Bennett's circuit model, this would require two copies of the ancilla state — violating the no-cloning principle. The semi-persistent design (which invalidates older versions on backtrack) enforces the linearity that Bennett's construction requires.

### Linearity condition (p. 5, §5 "Conclusion")

> "Our solution is exactly the same as the imperative one when used linearly i.e. without any backtracking."

This "linear use" condition exactly matches Bennett's construction's access pattern: each version is accessed exactly once in the forward direction (during computation) and exactly once in the reverse direction (during uncomputation), with no branching.

---

## 6. Reversibility Prediction

### Reroot cost

*(p. 4: "The reroot operation has a cost proportional to the number of Diff nodes that must be followed to reach the Arr node, but it is only performed the first time we access to an old version of a persistent array. Any subsequent access will be performed in constant time.")*

Let d = distance (number of `Diff` hops) from the current reference to the `Arr` node. Then:
- First access to version at distance d: O(d) cost for `reroot`.
- All subsequent accesses to that version: O(1).

Under sequential (linear) access — which is exactly Bennett's access pattern — the `Arr` node moves one step at a time. Each `reroot` is O(1). **Amortized complexity O(1) per operation under sequential access.**

### Bennett construction overhead for the PUF

For a computation that makes k union-find operations:
- **Forward pass**: k operations, each O(α(n)) amortized for `find`/`union` (where α is the inverse Ackermann function from path compression + ranking). Total: O(k·α(n)).
- **Copy pass**: 1 CNOT-copy of the representative array (~n·W CNOT at W-bit integers). Total: O(n·W) = O(n·W) gates.
- **Uncompute pass**: k `reroot` + reverse operations, each O(1) amortized. Total: O(k·W) gates (each reverse step undoes one `set`, which is one array element write = W CNOTs).

**Gate count estimate for k operations at W=32:**
- Forward: k × O(α(n)) ≈ k × 32 Toffoli (each find step is ~32-bit comparison chain)
- Copy: n × 32 CNOT
- Uncompute: k × 32 CNOT
- Total: **O(k·W) gates** ≈ 64k + 32n gates (W=32)

Compared to a naive copy-on-write approach (which would cost O(n·k·W) — copying the entire array for each operation), the reroot-based semi-persistent array achieves **linear** gate count in the number of operations, matching the imperative algorithm's time complexity.

### Rebase O(d) worst case

Under backtracking (non-linear access), accessing a version at distance d from the current root costs O(d) per operation. In the worst case (accessing a version from k steps ago), this is O(k) per access. But in a Bennett circuit there is no backtracking in the version-tree sense — the circuit always moves forward then backward along the same chain — so this worst case never occurs in practice.

---

## 7. What Is Nontrivial About Reversibilising the PUF

### Path compression mutates the parent array

The `find` operation performs path compression: it updates `h.parent` with `h.parent ← f` (line in `find`, p. 3), which is a **side effect on the union-find record** — specifically, on the `mutable parent` field. This field is mutated even though the abstract value (the set of representatives) is unchanged.

In a reversible circuit, this mutation must be paired with an uncompute step. The `reroot` mechanism handles this: the `Diff` nodes record exactly which array cells were mutated and to what values, so the uncompute pass can restore them.

The subtlety: path compression in `find_aux` creates a chain of `set` operations (one per node along the find path). Each `set` creates a new `Diff` node. On the uncompute pass, `reroot` must traverse and reverse all of these `Diff` nodes. The number of Diff nodes created by a single `find` can be up to O(log* n) (inverse Ackermann). Each reversal is O(W) CNOT gates.

### The mutable parent field is a controlled side channel

The `union-find` record has a `mutable parent` field (p. 2: `mutable parent: int A.t`). This field is updated by `find` via path compression. In the persistent setting, this mutation is safe because it only affects the current version and the abstract value (representatives) is invariant under path compression. In a reversible circuit, this "safe mutation" must be tracked by the `Diff` chain so it can be undone. The `Invalid` variant (semi-persistent) handles this correctly: path-compressed versions become invalid after backtracking, which is consistent because we only need the compressed path during the forward pass.

### The Coq proof (§4) is not directly executable

The paper's Coq formalization (§§4.3–4.4) verifies correctness and observational persistence but does not extract a circuit-level implementation. The Coq specs are useful as formal correctness criteria for the reversible version but the gate-level implementation must be derived separately from the OCaml code plus Bennett's construction.
