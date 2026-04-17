# Brief: Bagwell 2001 — Ideal Hash Trees (HAMT)

## WARNING: INSERT/DELETE ALGORITHMS MISSING FROM SOURCE PDFs

**CRITICAL FLAG FOR T5-P3c:** Neither of the two source PDFs (Bagwell 2001 "Ideal Hash Trees" and Bagwell 2000 "Fast and Space Efficient Trie Searches") contains a complete pseudocode or formal algorithm for **insert** or **delete**. The 2001 paper describes insert and delete in prose (§3.2, §3.6) but gives no pseudocode listing. Whoever implements T5-P3c (the reversible HAMT) must consult secondary sources:

**TODO references for T5-P3c insert/delete:**
1. **Clojure's persistent map:** `clojure.lang.PersistentHashMap.java` in the Clojure source tree — the canonical persistent HAMT insert/lookup/delete in Java, directly descended from Bagwell's design.
2. **Scala's TrieMap:** `scala.collection.concurrent.TrieMap` — persistent HAMT with CT (compressed trie) nodes; see Prokopec et al. 2012 "Concurrent Tries with Efficient Non-Blocking Snapshots."
3. **Stucki et al. 2015:** "RRB Vector: A Practical General Purpose Immutable Sequence" — uses the same AMT spine structure and discusses persistent insert/delete in detail.
4. **Steindorfer & Vinju 2015:** "Optimizing Hash-Array Mapped Tries for Fast and Lean Immutable JVM Collections" — gives explicit Java pseudocode for all HAMT operations.

---

## Citation

### Primary source (main HAMT paper)

- **Author:** Phil Bagwell
- **Title:** Ideal Hash Trees
- **Venue:** EPFL Technical Report LAMP-REPORT-2001-001, 2001
- **URL:** https://lampwww.epfl.ch/papers/idealhashtrees.pdf
- **PDF:** `Bagwell2001_HAMT.pdf` (19 pages as typeset, but our copy is 10 pages — ABBREVIATED; see §Source Coverage below)
- **Affiliation:** Es Grands Champs, 1195-Dully, Switzerland

### Secondary source (AMT precursor)

- **Author:** Phil Bagwell
- **Title:** Fast and Space Efficient Trie Searches
- **Venue:** Technical Report, 2000 (2-page excerpt)
- **PDF:** `../triesearches.pdf` (2 pages — ABBREVIATED; covers §1 Introduction and Fig. 1 Array Tree only)
- **Note:** This is the paper that first introduced the AMT (Array Mapped Trie) concept. The full paper also defines Array Compacted Trees (ACT) and Unary Search Trees (UST).

### Source coverage warning

Both PDFs are **abbreviated** — the HAMT PDF covers pages 1–10 of the full 19-page report (missing §§4–7 on partition hashing, external storage, dispatch tables, IP routing), and the triesearches PDF covers only the first 2 pages. The AMT essentials and HAMT search are complete in what we have. Insert/delete prose is partially present. No insert/delete pseudocode is present in either PDF.

---

## 1. Array Mapped Trie (AMT) — AMT Essentials

### Source: Bagwell 2001 §2 "Essentials of the Array Mapped Trie", pp. 2–3

*(p. 2:)*

> "It should be noted that all the algorithms that follow have been optimized for a 32 bit architecture and hence the AMT implementation has a natural cardinality of 32. However it is a trivial matter to adapt the basic AMT to a 64 bit architecture. AMT's for other alphabet cardinalities are covered in the paper, Fast and Space Efficient Trie Searches Bagwell [2000]."

> "A trie is represented by a node and number of arcs leading to sub-tries and each arc represents a member of an alphabet of possible alternatives. Here, to match the natural structure of a 32 bit system architecture, the alphabet is restricted to a cardinality 32 limiting the arcs to the range 0 to 31. The central dilemma in representing such tries is to strike an acceptable balance between the desire for fast traversal speed and minimizing the space lost for empty arcs."

> "The AMT data structure uses just two 32 bit words per node for a good compromise, achieving fast traversal at a cost of only one bit per empty arc. An integer bit map is used to represent the existence of each of the 32 possible arcs and an associated table contains pointers to the appropriate sub-tries or terminal nodes. A one bit in the bit map represents a valid arc, while a zero an empty arc. The pointers in the table are kept in sorted order and correspond to the order of each one bit in the bit map. The tree is depicted in Fig 1."

*(See Fig. 1, p. 3: a two-word node `[Map | SubTrie]` where Map is the 32-bit bitmap and SubTrie is a pointer to a compact array of only the non-null child pointers, ordered by bit position.)*

> "Finding the arc for a symbol s, requires finding its corresponding bit in the bit map and then counting the one bits below it in the map to compute an index into the ordered sub-trie. Today a CTPOP (Count Population) instruction is available on most modern computer architectures including the Intel Itanium, Compaq Alpha, Motorola Power PC, Sun UltraSparc and Cray, or can be emulated with non-memory referencing shift/add instructions, to count selected bits in a bit-map."

*(p. 2–3: The index into the sub-trie array for symbol s is `popcount(Map & ((1 << s) - 1))` — the number of set bits in the bitmap strictly below position s.)*

### Array Tree (precursor, no bitmap compression) — Bagwell 2000 §1, p. 1–2, Fig. 1

*(From triesearches.pdf, p. 2, Fig. 1: "An Array Tree." The Array Tree stores a full-size array at each node (no bitmap compression), with NULL entries for absent children. The AMT replaces this with a bitmap + compact array, giving the space savings.)*

The Fig. 2 search code fragment from triesearches.pdf (p. 2) shows the uncompressed Array Tree search:

```cpp
// Assuming characters are represented as A=0, B=1,...,Z=25
class Table{Table *Base};
  Table *ITable;
  char *pKey; // pKey points to the zero terminated Key string
  ITable=RootTable;
  while((*pKey)&&(ITable=ITable[*pKey++]));
```

*(Fig. 2, triesearches.pdf p. 2. This is the degenerate case — no bitmap compression. The AMT improvement replaces the `ITable[*pKey++]` direct index with a bitmap test + popcount-compressed index.)*

---

## 2. CTPop Emulation Code — VERBATIM

### Source: Bagwell 2001 Fig. 2, p. 3

This is the single most important code artifact for T5-P3c. Reproduced verbatim:

```c
const unsigned int SK5=0x55555555,SK3=0x33333333;
const unsigned int SKF0=0xF0F0F0F,SKFF=0xFF00FF;

        int CTPop(int Map)
          {
          Map-=((Map>>1)&SK5);
          Map=(Map&SK3)+((Map>>2)&SK3);
          Map=(Map&SKF0)+((Map>>4)&SKF0);
          Map+=Map>>8;
          return (Map+(Map>>16))&0x3F;
          }
```

*(Fig. 2, p. 3. Caption: "Emulation of CTPOP")*

**Explanation of the five lines (not in the paper — analysis for T5-P3c):**

Line 1: `Map -= ((Map>>1) & SK5)` — parallel 2-bit popcount: each pair of bits is replaced by the count of set bits in that pair. SK5 = 0x55555555 = `0101...0101` (alternating bits mask).

Line 2: `Map = (Map & SK3) + ((Map >> 2) & SK3)` — merge adjacent 2-bit counts into 4-bit counts. SK3 = 0x33333333 = `0011...0011`.

Line 3: `Map = (Map & SKF0) + ((Map >> 4) & SKF0)` — merge adjacent 4-bit counts into 8-bit counts. SKF0 = 0x0F0F0F0F (alternating nibbles mask; note paper writes `0xF0F0F0F` which is the 8-hex-digit form).

Line 4: `Map += Map >> 8` — merge adjacent byte counts into 16-bit counts.

Line 5: `return (Map + (Map >> 16)) & 0x3F` — final merge and mask to 6 bits (max count is 32, fits in 6 bits).

**This is the Hamming weight / popcount algorithm (Wegner 1960 / Kernighan)** implemented via the parallel prefix sum pattern. It is branchless and uses only shift, AND, ADD, and SUB.

---

## 3. HAMT Search Algorithm — VERBATIM

### Source: Bagwell 2001 §3.1 "Search for a key", p. 4

> "Compute a full 32 bit hash for the key, take the most significant t bits and use them as an integer to index into the root hash table. One of three cases may be encountered. First, the entry is empty indicating that the key is not in the hash tree. Second the entry is a Key/Value pair and the key either matches the desired key indicating success or not, indicating failure. Third, the entry has a 32 bit map sub-hash table and a sub-trie pointer, Base, that points to an ordered list of the non-empty sub-hash table entries."

> "Take the next 5 bits of the hash and use them as an integer to index into the bit Map. If this bit is a zero the hash table entry is empty indicating failure, otherwise, it's a one, so count the one bits below it using CTPOP and use the result as the index into the non-empty entry list at Base. This process is repeated taking five more bits of the hash each time until a terminating key/value pair is found or the search fails. Typically, only a few iterations are required and it is important to note that the key is only compared once and that is with the terminating node key. This contributes significantly to the speed of the search since many memory accesses are avoided. Notice too that misses are detected early and rarely require a key comparison."

*(p. 4: "Assuming that the hash function generates a random distribution of keys then on average the key hash will uniquely define a terminal node after lgN bits. With an AMT 5 bits of the hash are taken at each iteration giving a search cost of ⅕lgN or O(lgN). As will be shown later this can be reduced to an O(1) cost.")*

---

## 4. Insert Algorithm — PROSE ONLY (no pseudocode in PDF)

### Source: Bagwell 2001 §3.2 "Insertion", p. 5

The paper describes insert in prose but provides no pseudocode listing:

> "The initial steps required to add a new key to the hash tree are identical to the search. The search algorithm is followed until one of two failure modes is encountered."

> "Either an empty position is discovered in the hash table or a sub-hash table is found. In this case, if this is in the root hash table, the new key/value pair is simply substituted for the empty position. However, if in a sub-hash table then a new bit must be added to the bit map and the sub-hash table increased by one in size. A new sub-hash table must be allocated, the existing sub-table copied to it, the new key/value entry added in sub-hash sorted order and the old hash table made free."

> "Or the key will collide with an existing one. In which case the existing key must be replaced with a sub-hash table and the next 5 bit hash of the existing key computed. If there is still a collision then this process is repeated until no collision occurs. The existing key is then inserted in the new sub-hash table and the new key added. Each time 5 more bits of the hash are used the probability of a collision reduces by a factor of 1/32. Occasionally an entire 32 bit hash may be consumed and a new one must be computed to differentiate the two keys."

**There is no pseudocode listing for insert in this PDF.** See §Warning above for secondary references.

---

## 5. Delete Algorithm — PROSE ONLY (no pseudocode in PDF)

### Source: Bagwell 2001 §3.6 "Key Removal", p. 9

> "Key removal presents few complications and two cases need to be considered. If the sub-hash tree contains more than two entries then the key entry is removed and marked empty. This requires that a new smaller sub-hash table be allocated and the old one made free. If the sub-hash table contains two entries then the remaining entry is moved to the parent sub-hash table and the current sub-hash table made free."

**No pseudocode.** See §Warning above.

---

## 6. Why log32 Branching Gives Effectively-O(1) Lookup

### Source: Bagwell 2001 §3.1 pp. 4–5 and §3.4 "Lazy Root Hash Table Re-Sizing" pp. 7–8

With 5-bit branching factor (32-way), the tree depth for N keys is ⌈log₃₂ N⌉ = ⌈lgN / 5⌉. For practical key-set sizes:

- N = 8K: depth ≤ 3 (32³ = 32768 > 8K)
- N = 1M: depth ≤ 4 (32⁴ = 1048576)
- N = 32M: depth ≤ 5

With the lazy root-hash-table resizing (§3.4), the root table is periodically doubled, reducing the average depth further. Once the root table has size 2^t and the tree has N keys, the average search cost is ⅕(lgN − t) + 1 hops. At t = ⅕ lgN (root table ~N^(1/5)), this is effectively O(1) in practice.

*(p. 8: "Hence the average search and insert costs become ⅕lgN − ⅕lg(N/T) or ⅕(lgf), i.e. O(1).")*

---

## 7. Reversibility Prediction for CTPop

### CTPop gate cost at W=32

CTPop takes a 32-bit input (the bitmap `Map`) and produces a 6-bit output (the popcount). The five lines of the C function use:

| Operation | Count | Reversible gate cost (W=32) |
|-----------|-------|----------------------------|
| Shift (`>>1`, `>>2`, `>>4`, `>>8`, `>>16`) | 5 | ~5 × W CNOTs = 160 CNOT (wired shift, zero cost in circuit) |
| AND with constant mask (SK5, SK3, SKF0) | 6 | ~6 × W Toffoli ≈ 192 Toffoli |
| ADD/SUB of W-bit values | 5 | ~5 × W Toffoli (ripple-carry) = 160 Toffoli |
| Final mask `& 0x3F` | 1 | ~6 Toffoli (mask top 26 bits) |

**Conservative estimate: ~150–200 Toffoli for a reversible CTPop at W=32.** The shifts are free (wired permutations in a circuit). The dominant cost is the five ADD/SUB operations × ~32 Toffoli each = ~160 Toffoli, plus the AND-with-constant masking operations.

Note: The subtraction on line 1 (`Map -= ...`) and the additions on lines 2–4 are all bounded additions on partial-width sub-words, so many ripple-carry chains are short. A tighter analysis (treating each pair/nibble/byte independently) would give a lower count; ~150 Toffoli is a safe upper bound.

### Per-hop cost (one AMT level traversal)

Each hop: 1 CTPop (~150 Toffoli) + 1 table-index (1 pointer-width MUX, ~W Toffoli = 32 Toffoli) + 1 branch (select on 3 cases, ~10 Toffoli) ≈ **~200 Toffoli per level**.

For a tree of depth d:
- d = 3 (N ≤ 32K): ~600 Toffoli search path
- d = 4 (N ≤ 1M): ~800 Toffoli search path
- d = 5 (N ≤ 32M): ~1000 Toffoli search path

These are for the forward (search) pass only. Under Bennett's construction the full search-and-uncompute cost is 2× + CNOT copy = ~3× total.

---

## 8. What Is Nontrivial About Reversibilising HAMT

### The bitmap mutation problem

HAMT insert mutates the bitmap (sets a bit) and resizes the child array (allocates a larger array, copies, frees old). In a reversible circuit, **allocation must be paired with exact deallocation**. The Bennett construction naturally handles this: the forward pass allocates, the uncompute pass deallocates. But the copy-and-free-old-table step requires: (1) allocate new table, (2) copy all entries, (3) insert new entry, (4) free old table. Steps (1)–(4) must all be reversible and paired in the uncompute. This is manageable with AG13-style EXCH heap but adds ~4 EXCH operations per level = ~4 × 8 × W CNOT per level (at W=32: ~1024 CNOT per level).

### CTPop is not a bijection

The CTPop function maps 2^32 inputs to {0, 1, ..., 32} — highly non-injective. It cannot be directly made reversible. For Bennett's construction this is fine: CTPop is computed as part of the forward pass and its intermediate results (the five scratchpad states of `Map`) are cleaned up by the uncompute pass. The output value (popcount) becomes an ancilla that is used to index the table, then uncomputed when the search backtracks. The key: the uncompute pass has access to the original bitmap input, so it can recompute and cancel CTPop's contribution without ever storing the result permanently.

### Insert/delete are not in the source PDFs

As flagged above, insert and delete pseudocode is absent from both acquired PDFs. The reversible implementation of T5-P3c must be based on secondary sources (Clojure PersistentHashMap, Steindorfer & Vinju 2015, or Stucki et al. 2015) combined with the AMT/HAMT search logic from Bagwell 2001.
