# Brief: Clojure PersistentHashMap — HAMT Insert and Delete (Verbatim Reference)

## Citation

- **Source type:** Implementation reference (Java source, not a paper)
- **Author:** Rich Hickey (primary), Clojure contributors
- **File:** `clojure/lang/PersistentHashMap.java`
- **Repository:** https://github.com/clojure/clojure
- **Raw URL:** https://raw.githubusercontent.com/clojure/clojure/master/src/jvm/clojure/lang/PersistentHashMap.java
- **Acquired file:** `docs/literature/memory/Clojure_PersistentHashMap.java` (1364 lines, 38011 bytes)
- **Latest commit touching this file:** `56d37996b18df811c20f391c840e7fd26ed2f58d` (2022-06-09, "CLJ-1327: Pinned the serialVersionUID...")
- **License:** Eclipse Public License 1.0
- **Comment block in file:** "A persistent rendition of Phil Bagwell's Hash Array Mapped Trie / Uses path copying for persistence / HashCollision leaves vs. extended hashing / Node polymorphism vs. conditionals / No sub-tree pools or root-resizing"

This is the canonical persistent HAMT implementation descended directly from Bagwell's design. It is the ground-truth reference for insert and delete algorithms as there is no complete pseudocode in either Bagwell 2001 or Bagwell 2000.

---

## 1. Index Helper Methods — VERBATIM

### `mask` and `bitpos` — 5-bit hash slice and single-bit position

From `PersistentHashMap.java` lines 276–278 and 1221–1223:

```java
static int mask(int hash, int shift){
    //return ((hash << shift) >>> 27);// & 0x01f;
    return (hash >>> shift) & 0x01f;
}
```

```java
private static int bitpos(int hash, int shift){
    return 1 << mask(hash, shift);
}
```

### `index` — popcount-based compressed-array index

From `BitmapIndexedNode`, lines 682–684:

```java
final int index(int bit){
    return Integer.bitCount(bitmap & (bit - 1));
}
```

**These three helpers are the entire AMT indexing mechanism.** `mask` extracts 5 bits of the hash at depth `shift` (0, 5, 10, ...). `bitpos` converts those 5 bits into a single set bit in a 32-bit word. `index` counts how many set bits in the bitmap fall *below* that bit (i.e., `popcount(bitmap & (bit-1))`), giving the compressed array index. `Integer.bitCount` is `popcount` / CTPop.

---

## 2. Array Representation

**`BitmapIndexedNode`** (lines 675–928): Used when a node has 1–15 non-null children.
- `int bitmap`: 32-bit mask, one bit per possible child slot (slots 0–31 correspond to 5-bit hash values)
- `Object[] array`: interleaved `[key0, val0, key1, val1, ...]` for inline key/value pairs; when `keyOrNull == null`, the slot holds a sub-node pointer in `valOrNode`
- Key `null` sentinel: `array[2*idx] == null` means this slot points to a sub-node (not a leaf), the node pointer is `array[2*idx+1]`

**`ArrayNode`** (lines 403–673): Used when a node has ≥ 16 non-null children (uncompressed 32-slot array).
- `INode[] array`: 32-element array, `null` for empty slots (no bitmap needed)

**`HashCollisionNode`** (lines 930–1085): Used when two distinct keys have identical 32-bit hashes.
- `int hash`: the common hash value
- `Object[] array`: interleaved `[key0, val0, key1, val1, ...]` (linear scan to find keys)
- `int count`: number of entries

**`removePair`** helper (lines 1193–1198):

```java
private static Object[] removePair(Object[] array, int i) {
    Object[] newArray = new Object[array.length - 2];
    System.arraycopy(array, 0, newArray, 0, 2*i);
    System.arraycopy(array, 2*(i+1), newArray, 2*i, newArray.length - 2*i);
    return newArray;
}
```

---

## 3. Insert Algorithm — VERBATIM

### Top-level persistent insert

From `PersistentHashMap.assoc`, lines 137–149:

```java
public IPersistentMap assoc(Object key, Object val){
    if(key == null) {
        if(hasNull && val == nullValue)
            return this;
        return new PersistentHashMap(meta(), hasNull ? count : count + 1, root, true, val);
    }
    Box addedLeaf = new Box(null);
    INode newroot = (root == null ? BitmapIndexedNode.EMPTY : root) 
            .assoc(0, hash(key), key, val, addedLeaf);
    if(newroot == root)
        return this;
    return new PersistentHashMap(meta(), addedLeaf.val == null ? count : count + 1, newroot, hasNull, nullValue);
}
```

`Box addedLeaf` is an out-parameter: set to non-null only when a *new* leaf was inserted (not an update). Used to decide whether to increment count.

### `BitmapIndexedNode.assoc` — recursive insert (persistent path-copying version)

From lines 692–740:

```java
public INode assoc(int shift, int hash, Object key, Object val, Box addedLeaf){
    int bit = bitpos(hash, shift);
    int idx = index(bit);
    if((bitmap & bit) != 0) {
        Object keyOrNull = array[2*idx];
        Object valOrNode = array[2*idx+1];
        if(keyOrNull == null) {
            INode n = ((INode) valOrNode).assoc(shift + 5, hash, key, val, addedLeaf);
            if(n == valOrNode)
                return this;
            return new BitmapIndexedNode(null, bitmap, cloneAndSet(array, 2*idx+1, n));
        } 
        if(Util.equiv(key, keyOrNull)) {
            if(val == valOrNode)
                return this;
            return new BitmapIndexedNode(null, bitmap, cloneAndSet(array, 2*idx+1, val));
        } 
        addedLeaf.val = addedLeaf;
        return new BitmapIndexedNode(null, bitmap, 
                cloneAndSet(array, 
                        2*idx, null, 
                        2*idx+1, createNode(shift + 5, keyOrNull, valOrNode, hash, key, val)));
    } else {
        int n = Integer.bitCount(bitmap);
        if(n >= 16) {
            INode[] nodes = new INode[32];
            int jdx = mask(hash, shift);
            nodes[jdx] = EMPTY.assoc(shift + 5, hash, key, val, addedLeaf);  
            int j = 0;
            for(int i = 0; i < 32; i++)
                if(((bitmap >>> i) & 1) != 0) {
                    if (array[j] == null)
                        nodes[i] = (INode) array[j+1];
                    else
                        nodes[i] = EMPTY.assoc(shift + 5, hash(array[j]), array[j], array[j+1], addedLeaf);
                    j += 2;
                }
            return new ArrayNode(null, n + 1, nodes);
        } else {
            Object[] newArray = new Object[2*(n+1)];
            System.arraycopy(array, 0, newArray, 0, 2*idx);
            newArray[2*idx] = key;
            addedLeaf.val = addedLeaf; 
            newArray[2*idx+1] = val;
            System.arraycopy(array, 2*idx, newArray, 2*(idx+1), 2*(n-idx));
            return new BitmapIndexedNode(null, bitmap | bit, newArray);
        }
    }
}
```

**Insert logic, case by case:**

1. **Bit already set (`(bitmap & bit) != 0`):**
   - **Sub-node slot** (`keyOrNull == null`): recurse into the child node at `shift+5`. Path-copy on the way back.
   - **Same key** (`Util.equiv(key, keyOrNull)`): update the value in place (path-copy the array).
   - **Different key, same bit** (hash collision at this level): replace the inline key/value pair with a new sub-node via `createNode` (which recurses to the next level to resolve the collision).

2. **Bit not set (new slot):**
   - **Overflow (n ≥ 16)**: promote to `ArrayNode` — allocate a 32-slot array, scatter existing entries, insert new one.
   - **Normal case (n < 16)**: expand the array by 2, insert the new key/value at the sorted position `idx`, set the new bit in the bitmap.

### `createNode` — collision resolution helper

From lines 1200–1208:

```java
private static INode createNode(int shift, Object key1, Object val1, int key2hash, Object key2, Object val2) {
    int key1hash = hash(key1);
    if(key1hash == key2hash)
        return new HashCollisionNode(null, key1hash, 2, new Object[] {key1, val1, key2, val2});
    Box addedLeaf = new Box(null);
    AtomicReference<Thread> edit = new AtomicReference<Thread>();
    return BitmapIndexedNode.EMPTY
        .assoc(edit, shift, key1hash, key1, val1, addedLeaf)
        .assoc(edit, shift, key2hash, key2, val2, addedLeaf);
}
```

If the two keys have identical full 32-bit hashes, create a `HashCollisionNode`. Otherwise, create a new `BitmapIndexedNode` two levels down by inserting both keys at `shift+5`.

### `HashCollisionNode.assoc` — insert into collision list

From lines 944–961:

```java
public INode assoc(int shift, int hash, Object key, Object val, Box addedLeaf){
    if(hash == this.hash) {
        int idx = findIndex(key);
        if(idx != -1) {
            if(array[idx + 1] == val)
                return this;
            return new HashCollisionNode(null, hash, count, cloneAndSet(array, idx + 1, val));
        }
        Object[] newArray = new Object[2 * (count + 1)];
        System.arraycopy(array, 0, newArray, 0, 2 * count);
        newArray[2 * count] = key;
        newArray[2 * count + 1] = val;
        addedLeaf.val = addedLeaf;
        return new HashCollisionNode(edit, hash, count + 1, newArray);
    }
    // nest it in a bitmap node
    return new BitmapIndexedNode(null, bitpos(this.hash, shift), new Object[] {null, this})
        .assoc(shift, hash, key, val, addedLeaf);
}
```

If the incoming `hash` matches `this.hash` (true collision): linear scan for the key, update if found, else append. If `hash != this.hash`: wrap `this` in a new `BitmapIndexedNode` and continue the normal insert from that level.

### `findIndex` — linear scan in collision list

From lines 1005–1012:

```java
public int findIndex(Object key){
    for(int i = 0; i < 2*count; i+=2)
        {
        if(Util.equiv(key, array[i]))
            return i;
        }
    return -1;
}
```

---

## 4. Delete Algorithm — VERBATIM

### Top-level persistent delete

From `PersistentHashMap.without`, lines 167–176:

```java
public IPersistentMap without(Object key){
    if(key == null)
        return hasNull ? new PersistentHashMap(meta(), count - 1, root, false, null) : this;
    if(root == null)
        return this;
    INode newroot = root.without(0, hash(key), key);
    if(newroot == root)
        return this;
    return new PersistentHashMap(meta(), count - 1, newroot, hasNull, nullValue); 
}
```

### `BitmapIndexedNode.without` — recursive delete (persistent)

From lines 742–765:

```java
public INode without(int shift, int hash, Object key){
    int bit = bitpos(hash, shift);
    if((bitmap & bit) == 0)
        return this;
    int idx = index(bit);
    Object keyOrNull = array[2*idx];
    Object valOrNode = array[2*idx+1];
    if(keyOrNull == null) {
        INode n = ((INode) valOrNode).without(shift + 5, hash, key);
        if (n == valOrNode)
            return this;
        if (n != null)
            return new BitmapIndexedNode(null, bitmap, cloneAndSet(array, 2*idx+1, n));
        if (bitmap == bit) 
            return null;
        return new BitmapIndexedNode(null, bitmap ^ bit, removePair(array, idx));
    }
    if(Util.equiv(key, keyOrNull)) {
        if (bitmap == bit)
            return null;
        return new BitmapIndexedNode(null, bitmap ^ bit, removePair(array, idx));
    }
    return this;
}
```

**Delete logic, case by case:**

1. **Bit not set**: key not present, return `this` unchanged.
2. **Sub-node slot** (`keyOrNull == null`): recurse into child at `shift+5`.
   - Child returned same node: no change, return `this`.
   - Child returned non-null: path-copy with updated child pointer.
   - Child returned `null` (child sub-trie became empty):
     - If this node would also become empty (`bitmap == bit`): return `null` (collapse upward).
     - Otherwise: clear the bit and shrink the array via `removePair`.
3. **Inline key match** (`Util.equiv(key, keyOrNull)`):
   - If this was the only entry (`bitmap == bit`): return `null` (collapse).
   - Otherwise: clear the bit and shrink the array via `removePair`.
4. **Key not found** (bit set but wrong key): return `this`.

### `ArrayNode.without` — delete from uncompressed 32-slot node

From lines 425–439:

```java
public INode without(int shift, int hash, Object key){
    int idx = mask(hash, shift);
    INode node = array[idx];
    if(node == null)
        return this;
    INode n = node.without(shift + 5, hash, key);
    if(n == node)
        return this;
    if (n == null) {
        if (count <= 8) // shrink
            return pack(null, idx);
        return new ArrayNode(null, count - 1, cloneAndSet(array, idx, n));
    } else 
        return new ArrayNode(null, count, cloneAndSet(array, idx, n));
}
```

**Key case:** when a child becomes `null` and `count <= 8`, the `ArrayNode` **packs back** into a `BitmapIndexedNode` via `pack`. This is the ArrayNode↔BitmapIndexedNode threshold (promote at 16, demote at 8 — hysteresis to avoid thrashing).

### `ArrayNode.pack` — shrink ArrayNode back to BitmapIndexedNode

From lines 536–553:

```java
private INode pack(AtomicReference<Thread> edit, int idx) {
    Object[] newArray = new Object[2*(count - 1)];
    int j = 1;
    int bitmap = 0;
    for(int i = 0; i < idx; i++)
        if (array[i] != null) {
            newArray[j] = array[i];
            bitmap |= 1 << i;
            j += 2;
        }
    for(int i = idx + 1; i < array.length; i++)
        if (array[i] != null) {
            newArray[j] = array[i];
            bitmap |= 1 << i;
            j += 2;
        }
    return new BitmapIndexedNode(edit, bitmap, newArray);
}
```

Note: `newArray` starts at index 1 (odd offset) — entries are packed as `[null, node, null, node, ...]` because in `BitmapIndexedNode`, a `null` key signals a sub-node pointer. The `j` index starts at 1 (the `valOrNode` slot), incrementing by 2. Slot 0 (`key`) stays `null` implicitly because `Object[]` is zero-initialised.

### `HashCollisionNode.without` — delete from collision list

From lines 964–971:

```java
public INode without(int shift, int hash, Object key){
    int idx = findIndex(key);
    if(idx == -1)
        return this;
    if(count == 1)
        return null;
    return new HashCollisionNode(null, hash, count - 1, removePair(array, idx/2));
}
```

If only one entry remains and it matches, return `null` (collapse upward to the parent's `without` logic). Otherwise shrink the array. Note `idx/2` because `findIndex` returns a byte-pair index but `removePair` takes a pair index.

---

## 5. Collision-List Handling (`HashCollisionNode`)

`HashCollisionNode` exists because HAMT can only use 5-bit hash slices per level: with a 32-bit hash, after consuming all 32 bits (6 levels × 5 = 30 bits, plus the root), two distinct keys *can* have identical full 32-bit hashes. When that happens, the implementation falls back to a linear list (`HashCollisionNode`) rather than applying further hashing.

**Structure:** `{hash: Int, count: Int, array: Object[2*count]}` — flat interleaved key/value array, `Util.equiv` for key equality.

**When triggered:** in `BitmapIndexedNode.assoc`, when two keys collide at a given slot and `createNode` detects `key1hash == key2hash`. Also in `HashCollisionNode.assoc` when a new key with the same hash is inserted.

**When exited:** a `HashCollisionNode` is re-wrapped in a `BitmapIndexedNode` if a new key with a *different* hash arrives (the `hash != this.hash` branch in `HashCollisionNode.assoc`).

**Cost:** O(n) lookup/insert/delete within the collision list (linear scan). Expected size: tiny (probability of a 32-bit hash collision is 2^{-32}).

---

## 6. Reversibility Prediction

### Insert

Per level of a `BitmapIndexedNode`:
- `bitpos(hash, shift)` → 1 shift + 1 AND = ~2W CNOTs (free, wired shifts)
- `index(bit)` = `popcount(bitmap & (bit-1))` → CTPop + AND = ~150 Toffoli (W=32; see bagwell_hamt_brief.md §7)
- Branch on `(bitmap & bit)` → ~10 Toffoli
- **Bit-set case (hit):** recurse + path-copy (`cloneAndSet` = copy W-bit pointer) → ~W CNOT = 32 CNOT
- **Bit-not-set, n < 16 (new leaf):** array expand by 2 slots + `System.arraycopy` (shift all entries at index > idx) → ~2W CNOT per shifted entry; amortised ~W CNOT = 32 CNOT; set bitmap bit → 1 OR (~1 Toffoli)
- **Overflow (n ≥ 16):** promote to `ArrayNode` — scatter 16 entries: 16 × ~150 Toffoli = 2400 Toffoli; rare (once per node lifetime)

**Typical per-hop cost (n < 16 case):** ~150 (CTPop) + ~30 (branch + array ops) = **~180 Toffoli per level**.

Tree depth = ⌈log₃₂(N)⌉. Total for full insert path:
- N ≤ 32K (depth 3): ~540 Toffoli forward; ×2 Bennett + copy = ~1100 Toffoli total
- N ≤ 1M (depth 4): ~720 Toffoli forward; ~1500 Toffoli total
- N ≤ 32M (depth 5): ~900 Toffoli forward; ~1900 Toffoli total

### Delete

Per level, same CTPop + branch cost as insert (~150+30 Toffoli). Additional cost vs. insert:

- `removePair` (array shrink by 2): `System.arraycopy` to close the gap — shifts up to 2*(n-1) words = ~2W*(n-1) CNOT; at n=8 and W=64: ~896 CNOT
- Bitmap clear: `bitmap ^ bit` (XOR) → 1 CNOT
- **Collapse case (`bitmap == bit`, return null):** no array allocation needed; cost is just the null return propagation

**Total delete cost is comparable to insert.** The dominant additional cost relative to insert is the `removePair` array shrink — see §7 below.

---

## 7. What Is Nontrivial About Reversibilising HAMT Delete

### The bitmap-shrink case

`BitmapIndexedNode.without` returns `new BitmapIndexedNode(null, bitmap ^ bit, removePair(array, idx))`. `removePair` allocates a new array of length `array.length - 2` and copies all pairs except index `i`. In a reversible circuit:

**The problem:** the removed pair `(array[2*i], array[2*i+1])` is discarded in the classical algorithm. In a reversible circuit, information cannot be discarded — the pair must go *somewhere*. Two options:

**(a) Ancilla preservation** (recommended — fits Bennett tape model): preserve the removed `(key, value)` pair in dedicated ancilla registers. The forward pass copies the pair to ancilla before "removing" it (actually: zero out the slot in the now-smaller view). The uncompute pass restores it. Cost: ~2W CNOT to save, ~2W CNOT to restore = 4W CNOT = 256 CNOT at W=64 per delete. **Ancilla overhead:** 2W bits per tree level that contains a delete = 2W × depth ancilla bits = 128 × 5 = 640 bits for a depth-5 tree. This is O(W × log₃₂(N)) ancilla, acceptable for Bennett's model.

**(b) Sparse representation** (avoids shrinking): keep a fixed-size 32-slot array per node (like `ArrayNode`) and maintain a validity bitmap separately. Delete only clears the bitmap bit and zeros the slot; no `removePair`. Avoids the tricky reversible array-element-removal entirely. Cost: larger nodes (fixed 32 slots × 2 = 64 words per node), larger CNOT cost for path-copying. Ancilla: O(32W × depth) = larger by factor 32/n compared to (a).

**T5-P3c preference is (a)** — simpler, fits the Bennett tape model, scales better in ancilla with N.

### The `ArrayNode.pack` case

When `ArrayNode.without` triggers `pack` (count falls from 9 to 8), the entire 32-slot array must be repacked into a `BitmapIndexedNode`. This requires:
1. Scan all 32 slots, collect non-null entries
2. Build the new bitmap (set bits for non-null slots)
3. Write a new compact interleaved array

In a reversible circuit, the original 32-slot array cannot be deallocated — it must be uncomputed by the Bennett reverse pass. The `pack` result is the new node; the old 32-slot `ArrayNode` becomes ancilla (zeroed in the uncompute). Cost: ~32W CNOT to copy existing entries + ~150 Toffoli (CTPop for the bitmap) per `pack` operation.

**Flag for T5-P3c:** the `ArrayNode` ↔ `BitmapIndexedNode` threshold transition (pack/unpack) is the most complex reversibility piece. Recommend either (a) handling it explicitly with ancilla storage of the 32-slot array during pack, or (b) avoiding `ArrayNode` entirely in the reversible implementation by capping node density at 15 (never promote to `ArrayNode`). Option (b) loses some cache efficiency but eliminates the pack/unpack complexity entirely. Assess for T5-P3c scope.

### CTPop is not a bijection

As noted in bagwell_hamt_brief.md §8: `popcount` maps 2^32 inputs to {0..32}. It is used inside the forward pass and uncomputed by the Bennett reverse. The output value (the compressed index) is an intermediate result, not a persistent output — Bennett handles this correctly without special treatment.

### Path-copying is inherently reversible

The persistent (path-copying) style of `PersistentHashMap` is actually *easier* to reversibilise than a mutable in-place HAMT: each `assoc`/`without` produces a new root node via path-copying. The old nodes are not mutated. In the reversible circuit, the old path is the Bennett uncompute path — it simply runs the path-copy in reverse, restoring the pre-insert/delete state. The `cloneAndSet` operations become CNOTs (copy the changed field, XOR back in the uncompute).
