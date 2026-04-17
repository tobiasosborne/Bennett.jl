# Brief: Kahrs 2001 — Red-Black Trees with Types

## Citation

- **Author:** Stefan Kahrs
- **Title:** Red-Black Trees with Types (Functional Pearl)
- **Venue:** *Journal of Functional Programming* **11**(4):425–432, July 2001
- **DOI:** 10.1017/S0956796801004026
- **PDF:** `Kahrs2001_rbt_delete.pdf` (8 pages, 203 KB; Cambridge University Press)
- **Affiliation:** University of Kent at Canterbury, Canterbury, Kent, UK
- **Supplementary code:** `Untyped.hs` and `Typed.hs` hosted at `http://www.cs.ukc.ac.uk/people/staff/smk/redblack/rb.html` (JFP home page). Both files were archived by the Wayback Machine (2003 snapshot) and are the source of the verbatim code below.

---

## 1. Core Contribution

Kahrs extends Okasaki's functional red-black tree implementation with a **delete** operation. The deletion algorithm is the primary algorithmic contribution; the typed encoding (phantom types, nested datatypes, existential type variables) is the type-theoretic contribution. For reversibility purposes the untyped version is canonical — it exposes the algorithm without the type machinery. The typed version uses a typeclass-based recursive structure that is harder to lower to circuits.

The paper also adds a **fifth** insert-balance case to Okasaki's `balance` (Fig. 1, p. 426), handling a red-red sibling collision that Okasaki's weaker invariant could sidestep but the typed system cannot.

Key paper quote (p. 430): *"Deletion of elements is a more intricate operation... While Hinze's algorithm essentially tries to mimic the traditional imperative algorithm, my version is closer to Reade's as it is also based on a recursive* `append` *operation."*

---

## 2. Verbatim Insert Algorithm (p. 426, Fig. 1 and Untyped.hs)

### 2a. Type definition — p. 426, Fig. 1

```haskell
data Color  = R | B
data Tree a = E | T Color (Tree a) a (Tree a)
```

### 2b. Insertion — p. 426, Fig. 1 (Okasaki 1999 formulation, reproduced verbatim)

```haskell
insert :: Ord a => a -> RB a -> RB a
insert x s =
        T B a z b
        where
        T _ a z b = ins s
        ins E = T R E x E
        ins s@(T B a y b)
                | x<y = balance (ins a) y b
                | x>y = balance a y (ins b)
                | otherwise = s
        ins s@(T R a y b)
                | x<y = T R (ins a) y b
                | x>y = T R a y (ins b)
                | otherwise = s
```

### 2c. `balance` — p. 426, Fig. 1 and Untyped.hs

Kahrs adds a **first equation** (handling red-red collision on both sides) not present in Okasaki 1999:

```haskell
{- balance: first equation is new,
   to make it work with a weaker invariant -}
balance :: RB a -> a -> RB a -> RB a
balance (T R a x b) y (T R c z d) = T R (T B a x b) y (T B c z d)
balance (T R (T R a x b) y c) z d = T R (T B a x b) y (T B c z d)
balance (T R a x (T R b y c)) z d = T R (T B a x b) y (T B c z d)
balance a x (T R b y (T R c z d)) = T R (T B a x b) y (T B c z d)
balance a x (T R (T R b y c) z d) = T R (T B a x b) y (T B c z d)
balance a x b = T B a x b
```

*(Note: 5-clause `balance` vs. Okasaki's 5-clause version — the first clause here is new. Okasaki's four non-fallthrough clauses correspond to clauses 2–5 here. Clause 1 handles the case that arises during deletion-triggered rebalancing where both subtrees are red.)*

---

## 3. Verbatim Delete Algorithm (Untyped.hs, archived 2003)

This is the complete, untyped delete algorithm from Kahrs's supplementary `Untyped.hs`, which the paper (p. 430) says "can be found on the JFP web site." The file was retrieved from the Wayback Machine archive of `https://www.cs.ukc.ac.uk/people/staff/smk/redblack/Untyped.hs`.

### 3a. Top-level `delete` — Untyped.hs

```haskell
delete :: Ord a => a -> RB a -> RB a
delete x t =
        case del t of {T _ a y b -> T B a y b; _ -> E}
        where
        del E = E
        del (T _ a y b)
            | x<y = delformLeft a y b
            | x>y = delformRight a y b
            | otherwise = app a b
        delformLeft a@(T B _ _ _) y b = balleft (del a) y b
        delformLeft a y b = T R (del a) y b
        delformRight a y b@(T B _ _ _) = balright a y (del b)
        delformRight a y b = T R a y (del b)
```

### 3b. `balleft` — Untyped.hs

Called when deletion was in the left subtree of a black node, and the left subtree has lost one black height.

```haskell
balleft :: RB a -> a -> RB a -> RB a
balleft (T R a x b) y c = T R (T B a x b) y c
balleft bl x (T B a y b) = balance bl x (T R a y b)
balleft bl x (T R (T B a y b) z c) = T R (T B bl x a) y (balance b z (sub1 c))
```

### 3c. `balright` — Untyped.hs

Called when deletion was in the right subtree of a black node, and the right subtree has lost one black height. Dual to `balleft`.

```haskell
balright :: RB a -> a -> RB a -> RB a
balright a x (T R b y c) = T R a x (T B b y c)
balright (T B a x b) y bl = balance (T R a x b) y bl
balright (T R a x (T B b y c)) z bl = T R (balance (sub1 a) x b) y (T B c z bl)
```

### 3d. `sub1` helper — Untyped.hs

Decrements a black node to red (used inside `balright`'s third clause to propagate height reduction):

```haskell
sub1 :: RB a -> RB a
sub1 (T B a x b) = T R a x b
sub1 _ = error "invariance violation"
```

### 3e. `app` (tree-merging function) — Untyped.hs

Merges two red-black trees that had the same black height (called when the current node's key matches). This is the key non-trivial helper — it splices two subtrees together maintaining the invariant:

```haskell
app :: RB a -> RB a -> RB a
app E x = x
app x E = x
app (T R a x b) (T R c y d) =
        case app b c of
            T R b' z c' -> T R(T R a x b') z (T R c' y d)
            bc -> T R a x (T R bc y d)
app (T B a x b) (T B c y d) = 
        case app b c of
            T R b' z c' -> T R(T B a x b') z (T B c' y d)
            bc -> balleft a x (T B bc y d)
app a (T R b x c) = T R (app a b) x c
app (T R a x b) c = T R a x (app b c)
```

---

## 4. Verbatim Typed Delete Algorithm (Typed.hs, archived 2003)

For completeness, the typed version from `Typed.hs`. The types use nested datatypes, phantom types and existential type variables. The algorithm is structurally the same; the type machinery enforces invariants statically.

### 4a. Type definitions (relevant to deletion)

```haskell
data Unit a          = E deriving Show
type Tr t a          = (t a, a, t a)
data Red t a         = C (t a) | R (Tr t a)
data AddLayer t a    = B(Tr(Red t) a)
data RB t a          = Base (t a) | Next (RB (AddLayer t) a)
type Tree a          = RB Unit a
type RR t a          = Red (Red t) a
type RL t a          = Red (AddLayer t) a
```

### 4b. `app` and helpers

```haskell
class Append t where app :: t a -> t a -> Red t a

instance Append Unit where app _ _ = C E

instance Append t => Append (AddLayer t) where
    app (B(a,x,b)) (B(c,y,d)) = threeformB a x (appRed b c) y d

threeformB :: Red t a -> a -> RR t a -> a -> Red t a -> RL t a
threeformB a x (R(b,y,c)) z d = R(B(a,x,b),y,B(c,z,d))
threeformB a x (C b) y c = balleftB (C a) x (B(b,y,c))

appRed :: Append t => Red t a -> Red t a -> RR t a
appRed (C x) (C y) = C(app x y)
appRed (C t) (R(a,x,b)) = R(app t a,x,C b)
appRed (R(a,x,b)) (C t) = R(C a,x,app b t)
appRed (R(a,x,b))(R(c,y,d)) = threeformR a x (app b c) y d

threeformR:: t a -> a -> Red t a -> a -> t a -> RR t a
threeformR a x (R(b,y,c)) z d = R(R(a,x,b),y,R(c,z,d))
threeformR a x (C b) y c = R(R(a,x,b),y,C c)
```

### 4c. `balleft`, `balright`, `balleftB`, `balrightB`

```haskell
balleft :: RR t a -> a -> RL t a -> RR (AddLayer t) a
balleft (R a) y c = R(C(B a),y,c)
balleft (C t) x (R(B(a,y,b),z,c)) = R(C(B(t,x,a)),y,balleftB (C b) z c)
balleft b x (C t) = C (balleftB b x t)

balleftB :: RR t a -> a -> AddLayer t a -> RL t a
balleftB bl x (B y) = balance bl x (R y)

balright :: RL t a -> a -> RR t a -> RR (AddLayer t) a
balright a x (R b) = R(a,x,C(B b))
balright (R(a,x,B(b,y,c))) z (C d) = R(balrightB a x (C b),y,C(B(c,z,d)))
balright (C t) x b = C (balrightB t x b)

balrightB :: AddLayer t a -> a -> RR t a -> RL t a
balrightB (B y) x t = balance (R y) x t
```

### 4d. Deletion typeclasses and instances

```haskell
class Append t => DelRed t where
        delTup :: Ord a => a -> Tr t a -> Red t a
        delLeft :: Ord a => a -> t a -> a -> Red t a -> RR t a
        delRight :: Ord a => a -> Red t a -> a -> t a -> RR t a

class Append t => Del t where
        del :: Ord a => a -> AddLayer t a -> RR t a

class (DelRed t, Del t) => Deletion t

instance DelRed Unit where
        delTup z t@(_,x,_) = if x==z then C E else R t
        delLeft x _ y b = R(C E,y,b)
        delRight x a y _ = R(a,y,C E)

instance Deletion t => DelRed (AddLayer t) where
        delTup z (a,x,b)
                | z<x = balleftB (del z a) x b
                | z>x = balrightB a x (del z b)
                | otherwise = app a b
        delLeft x a y b = balleft (del x a) y b
        delRight x a y b = balright a y (del x b)

instance DelRed t => Del t where
        del z (B(a,x,b))
            | z<x = delformLeft a
            | z>x = delformRight b
            | otherwise = appRed a b
              where delformLeft(C t) = delLeft z t x b
                    delformLeft(R t) = R(delTup z t,x,b)
                    delformRight(C t) = delRight z a x t
                    delformRight(R t) = R(a,x,delTup z t)

instance Deletion t => Deletion (AddLayer t)
instance Deletion Unit
```

### 4e. Top-level delete wrap-up (p. 431, Fig. 7 + Typed.hs)

```haskell
delete :: Ord a => a -> Tree a -> Tree a
delete x (Next u) = rbdelete x u
delete x _ = empty

rbdelete :: (Ord a,Deletion t) => a -> RB (AddLayer t) a -> RB t a
rbdelete x (Next t) = Next (rbdelete x t)
rbdelete x (Base t) = blacken2 (del x t)

blacken2 :: RR t a -> RB t a
blacken2 (C(C t))     = Base t
blacken2 (C(R(a,x,b))) = Next(Base(B(C a,x,C b)))
blacken2 (R p)        = Next(Base(B p))
```

*(p. 430–431: "The function* `delB` *is the dual to* `insB`*, it removes an element from a black tree. The result is a potentially infrared tree of depth 1. If that tree is either red or infrared (first two cases) we simply blacken the top red node... In the third case the returned tree is already black and it is here where we have a deletion underflow — the height of the tree decreases.")*

---

## 5. Balance Cases: Insert vs. Delete — Structural Differences

### Insert (`balance` in Okasaki + Kahrs)

Four + one cases, all symmetric. A red-red violation is repaired by rotating and recoloring:

```
(T R a x b) y (T R c z d)  →  T R (T B a x b) y (T B c z d)   -- new in Kahrs
(T R (T R a x b) y c) z d  →  T R (T B a x b) y (T B c z d)   -- left-left
(T R a x (T R b y c)) z d  →  T R (T B a x b) y (T B c z d)   -- left-right
a x (T R b y (T R c z d))  →  T R (T B a x b) y (T B c z d)   -- right-right
a x (T R (T R b y c) z d)  →  T R (T B a x b) y (T B c z d)   -- right-left
a x b                      →  T B a x b                        -- fallthrough
```

### Delete rebalance (`balleft`, `balright`)

The delete rebalance cases are **structurally different** from insert: they handle a **black-height deficit** (one subtree is one unit shorter). There is no single canonical `balance` function for deletion; instead there are `balleft` and `balright` which call the insert `balance` internally.

**`balleft` cases** (left child is height-deficient):

| Pattern | Result | Case type |
|---------|--------|-----------|
| `(T R a x b) y c` | `T R (T B a x b) y c` | left child was red; simple recolor |
| `bl x (T B a y b)` | `balance bl x (T R a y b)` | right sibling is black; push deficit up via rotation |
| `bl x (T R (T B a y b) z c)` | `T R (T B bl x a) y (balance b z (sub1 c))` | right sibling is red; double rotation |

**`balright` cases** (right child is height-deficient) — dual:

| Pattern | Result | Case type |
|---------|--------|-----------|
| `a x (T R b y c)` | `T R a x (T B b y c)` | right child was red; simple recolor |
| `(T B a x b) y bl` | `balance (T R a x b) y bl` | left sibling is black; push deficit up via rotation |
| `(T R a x (T B b y c)) z bl` | `T R (balance (sub1 a) x b) y (T B c z bl)` | left sibling is red; double rotation |

Note: `sub1` converts a black node to red, propagating the height deficit outward. This is the "double-black" repair mechanism (Kahrs avoids explicit double-black nodes; instead `sub1` is invoked on the sibling to match heights).

---

## 6. Reversibility Prediction

### Per-delete cost analysis

**Control flow structure**: `delete` recurses to depth d = log N, calling either `delformLeft` or `delformRight` at each level. At the target node, it calls `app`. On the way back up, it calls `balleft` or `balright` at every black node on the path where the deleted element was found in a subtree that lost height.

**`app` (tree merge)**: O(min(h₁, h₂)) recursive calls on inner spine; at each level, a case analysis on colors (2 bits), and 1 allocation. Worst case O(log N) calls. Per call: ~3 Toffoli for color comparison + ~W CNOTs for pointer copies = ~3W gates.

**`balleft`/`balright`**: 3 cases each, pattern-matched on the color of the sibling node and its left child. Per call: ~2 Toffoli for the case conditions + 1 rotation (~3W CNOTs) = ~3W + 2 gates. Called at most O(log N) times total per delete (deficit propagates at most to root).

**Conservative per-delete estimate at W=32**:
- `app` call: ~O(log N) × ~100 gates = ~100 × 20 = ~2000 gates for N=10^6
- Path descent O(log N) × ~3W Toffoli (comparisons) = ~20 × ~96 = ~1920 gates
- Height-repair: O(log N) × `balleft`/`balright` each ~3W+2 ≈ ~100 gates × ~20 = ~2000 gates
- **Total forward pass**: ~6000 gates at W=32, N=10^6

**Comparison to insert**: Insert at depth 3 (8-node tree) costs ~30W Toffoli for balance logic. Delete adds `app` (O(d) extra recursion) and `balleft`/`balright` (same depth as insert). Delete is approximately **2× insert** in gate count due to `app`.

**Bennett overhead**: Forward + CNOT copy of root pointer (W bits) + reverse (uncompute). This triples gate count: **~18,000 gates** for a delete at W=32, depth 20.

---

## 7. What Is Nontrivial About Reversibilising Delete

### 7a. The `app` function is a non-local pointer merge

`app` combines two subtrees that had the same black height. It recursively descends the inner spine of both trees simultaneously. In a reversible circuit, this recursion must be unrolled to bounded depth (log N steps), and at each step the choice of which branch to take depends on color bits in the nodes being visited. This is a **non-local path predicate**: the circuit must route through O(log N) tree nodes just for the merge, separate from the primary descent path.

This is the structural analog of the "double black" case in imperative RBT delete: the double-black is Kahrs's `sub1`, which creates a temporarily unbalanced tree that `balleft`/`balright` must repair. In a circuit, `sub1`'s effect (flipping a color bit from B to R) must be done under a guarded MUX conditioned on whether height repair is needed — and that condition is only known at runtime (when `balleft`'s third clause fires, vs. the first two).

### 7b. Deletion height underflow: a conditional Bennett path

After `rbdelete`, the `blacken2` step at the top dispatches on three cases. In Bennett's construction, the forward pass produces one of three outcomes (Base/Next/(RB p)). The appropriate `blacken2` branch fires. On the reverse pass, we must undo the `blacken2` — but we only know which case fired if we retain the case discriminant as an ancilla. This requires **2 ancilla bits** per delete to record which `blacken2` branch was taken, and they must be uncomputed on the reverse pass by a matching `unblacken2` function.

### 7c. `delLeft`/`delRight` in the typed version: recursive dictionary updates

The typed version's `Del`/`DelRed` typeclasses cause GHC to pass a "dictionary" argument that updates as the tree height changes. In a reversible circuit there is no dictionary — the type-level information must be encoded as explicit conditional branching. The untyped version (`Untyped.hs`) avoids this entirely: `delformLeft`/`delformRight` simply pattern-match on the tree constructor. This is the version to target for T5-P3b.

### 7d. MUX conditions for `balleft`/`balright` are non-exclusive

Unlike Okasaki's insert `balance` cases (which are mutually exclusive), the three cases of `balleft` and three of `balright` are also exclusive, but the conditions involve nested pattern matching:
- Case 1: color of the deficient subtree (`T R`)
- Case 2: color of the sibling (`T B`)  
- Case 3: color of the sibling and the sibling's left child (`T R (T B ...)`)

These conditions can be evaluated with 3 Toffoli gates each (three 1-bit fields from node records). They are mutually exclusive, so no multi-condition ancilla interaction is needed — cleaner than the insert `balance`.

### 7e. `sub1` is a reversible NOT

`sub1 (T B a x b) = T R a x b` flips the color bit from B to R. This is a single NOT gate on the 1-bit color field. The pre-condition (`sub1` is only called on a black node) must be enforced by the circuit structure. If it is called correctly (as guaranteed by the typed version's types), no ancilla is needed.

### 7f. Path-predicate structure comparison

| Operation | Path predicates | MUX arity | Ancilla bits per level |
|-----------|----------------|-----------|----------------------|
| Insert `balance` | 4 cases on 2 color bits | 4-way | ~2 bits |
| Delete `balleft` | 3 cases on 1–2 color bits | 3-way | ~2 bits |
| Delete `balright` | 3 cases on 1–2 color bits | 3-way | ~2 bits |
| `app` per level | 4 cases on 2 color bits | 4-way | ~2 bits |

Total ancilla for a full delete at depth d: ~8d bits for color discriminants + path tracking. At d=20: ~160 ancilla bits for the balance logic; plus O(d × W) bits for the intermediate node pointer snapshots in the Bennett construction.
