## Session close — 2026-04-12 (second-of-day, memory plan push)

### Shipped this session (13 issues closed)

| Task | Issue | Commit | Deliverable |
|------|-------|--------|-------------|
| closed-with-note | Bennett-h8iw | (WORKLOG) | Cuccaro dispatch misdiagnosis analysis |
| filed follow-up | Bennett-gsxe | (new) | 2n-3 Toffoli optimization for `lower_add_cuccaro!` |
| T1c.1 | Bennett-hz31 | b9d6183 | Babbush-Gidney QROM primitive |
| T1c.2 | Bennett-za54 | 726a494 | `lower_var_gep!` dispatches const tables to QROM |
| T1c.3 | Bennett-qw8k | 64bd85a | QROM vs MUX scaling benchmark |
| T2a.1 | Bennett-law3 | c560eb9 | MemorySSA investigation doc |
| T2a.2 | Bennett-81bs | c560eb9 | `src/memssa.jl` + `use_memory_ssa` kwarg |
| T2a.3 | Bennett-08wr | ab6b52e | MemorySSA integration tests (cases T0 misses) |
| T3a.1 | Bennett-bdni | cba1b42 | 4-round Feistel reversible hash |
| T3a.2 | Bennett-tqik | faf066d | Feistel vs Okasaki benchmark |
| T3b.1 | Bennett-oy9e | e16cf22 | Shadow memory protocol design doc |
| T3b.2 | Bennett-2ayo | e16cf22 | Shadow memory primitives |
| T3b.3 | Bennett-10rm | 65238e7 | Universal memory dispatcher |
| BC.4  | Bennett-6c8y | 592a8fb | BENCHMARKS.md extended head-to-head |

Test suite: all green (0 failures, 0 errors). Memory plan critical path
complete. `bd stats`: 127 closed / 52 open / 0 in-progress.

### Headline results

- **QROM** (T1c): 4(L-1) Toffoli post-Bennett, W-independent. 134× smaller
  than MUX tree at L=4 W=8 (56 gates vs 7,514). End-to-end: a Julia tuple
  lookup `f(x) = let tbl=(...); tbl[(x&m)+1]; end` compiles to a few hundred
  gates instead of the thousands our old MUX path emitted.
- **Feistel** (T3a): 8W Toffoli post-Bennett. 148× smaller than Okasaki
  persistent RB-tree's 71k gates per 3-node insert.
- **Shadow memory** (T3b): 3W CNOT per store, W CNOT per load, zero Toffoli
  from the mechanism. 297× smaller than MUX EXCH per op. Activates
  automatically for static-idx writes.
- **Universal dispatcher** (T3b.3): picks the cheapest correct strategy
  per operation. Mixed-strategy functions (e.g., static-idx init + dynamic
  read) work end-to-end.
- **MemorySSA** (T2a): parser + ingest + 23 integration tests. Paper-winning
  narrative unlocked: "first compiler to consume LLVM MemorySSA for
  reversible-memory analysis."

### What's left on the memory plan

The critical path is complete; what remains is supporting infrastructure
and benchmarks, all lower priority:

- **T0.3 Bennett-glh** (P2) — integrate Julia's EscapeAnalysis for
  allocation-site classification; complementary to the universal dispatcher's
  runtime decisions.
- **T0.4 Bennett-c68** (P2) — 20-function corpus benchmark to measure
  store/alloca elimination rate empirically.
- **BC.3 Bennett-xy75** (P2) — full SHA-256 (not just round) benchmark;
  stress-test at ~30K gates.
- **T2b Bennett-k4q3 / e5ke** (P3) — `@linear` macro + mechanical reversal
  of linear functions. Orthogonal to the memory strategies (a 5th strategy
  once landed, but separate workstream).

Paper tasks (P.1/P.2) still explicitly deferred per user direction —
implementation and benchmarking before drafting.

### What's left but didn't fit — noted follow-ups

- **Wire MemorySSA into `lower_load!`** — currently `parsed.memssa` is
  populated when the kwarg is set but `_lower_load_via_mux!` doesn't consult
  it. Doing so would let us correctly handle conditional stores that
  currently fall through to MUX EXCH (losing the branch-dependent value info).
- **SAT-pebbling scheduler for shadow tape slots** — shadow primitives expose
  the right interface (one slot per store, pebbleable) but
  `src/sat_pebbling.jl` isn't yet taught to schedule them. Design doc
  covers this (§4.5).
- **Non-power-of-two L for QROM** — current MVP restriction. Paper Fig 3 §III.A
  shows the truncation trick; easy extension when needed for a specific
  benchmark.
- **Cuccaro + Bennett self-reversing optimization** (Bennett-07r) — our
  in-place adder is self-uncomputing so Bennett reverse is redundant.
  Halves MD5 Toffoli count when fixed. Architectural change to bennett.jl.
- **Dynamic-idx shadow** — current shadow handles only static idx; dynamic
  would require MUX-select-among-tape-slots. Feasible extension.
- **Tighten `lower_add_cuccaro!` to paper-optimal 2n-3 Toffoli** (Bennett-gsxe).

### Gotchas learned (new since prior WORKLOG session)

1. **`LLVM.initializer(g)` can throw on non-ConstantData globals** —
   Julia emits type-reference globals (GlobalAlias etc.) that `initializer`
   can't resolve. Wrap in try/catch in any global-scanning code.
2. **Module-level `const tbl = (...)` doesn't inline** — creates a
   free-variable lookup in the function body, not a private constant
   global. For QROM dispatch, tuples must be declared inside the function
   via `let`.
3. **`IOBuffer` doesn't work with `redirect_stderr`** — use `Pipe()`, and
   remember to `close(pipe.in)` after the pass runs before reading.
4. **SROA can vectorize arrays in loops** — emits `insertelement` /
   `extractelement` which our IR walker doesn't support. Use `Ref` patterns
   instead of arrays for memssa integration tests.
5. **`length(ops) == 2` GEP skip path** silently drops globals in the raw
   IR — the Case B global-base branch we added is critical for QROM
   dispatch.

### Protocol for next agent

Memory plan critical path is done — don't re-open those tasks. The four
strategies (MUX EXCH, QROM, Feistel, Shadow) + universal dispatcher are the
design; build the remaining work on top of them.

If someone wants to tackle "really complete" round 2, the highest-leverage
next steps are:
1. **Wire MemorySSA into `lower_load!`** — turns the T2a infrastructure
   from diagnostic into functional. Likely ~100 LOC change in `lower.jl`.
2. **BC.3 full SHA-256** — will reveal whether our memory strategies scale.
   PRS15 Table II published comparison numbers available.
3. **Bennett-07r Cuccaro self-reversing** — halves Toffoli count on any
   adder-heavy benchmark (MD5, SHA, crypto). Architectural change to
   `bennett.jl` — mark Cuccaro-group gates as "skip Bennett reverse."

Everything else is polish.

---

## T5-P3b: Okasaki RBT — 2026-04-17 (Bennett-mcgk)

### What was implemented

`src/persistent/okasaki_rbt.jl` — branchless Okasaki 1999 red-black tree insert + lookup,
conforming to the `PersistentMapImpl` protocol (T5-P3a). K=V=Int8, max_n=4, state=NTuple{3,UInt64}.

### State layout

NTuple{3, UInt64}:
- s[1]: node 1 (bits 0:23) | node 2 (bits 24:47)
- s[2]: node 3 (bits 0:23) | node 4 (bits 24:47)
- s[3]: root_idx (bits 0:2) | next_free_count (bits 3:5)

Node 24-bit encoding: color(1) | left_idx(3) | right_idx(3) | key(8) | val(8) | reserved(1)

### Tree representation

Option (a): flat node pool. 4 node slots (indices 1..4), index 0 = null.
Node slots are stable — balance only changes fields (color, child ptrs) not slot assignments.
This makes the branchless "write all 4 slots" pattern natural.

### Balance

All 4 Okasaki balance cases (LL, LR, RL, RR) are computed speculatively every call,
then MUX-selected via `ifelse`. The cases are MUTUALLY EXCLUSIVE when `do_balance=true`,
so there is no false-path sensitization risk — the unused branches' values are computed
but immediately discarded by the outer `ifelse`.

The balance only fires at depth-2 inserts (grandparent = root, parent = nxt1, new = new_slot).
For depth-0 and depth-1 inserts, no balance is needed (the inserted red node has a black parent).

### Gate counts (max_n=4, K=V=Int8, 3-set+1-get demo)

- Total: 108,106
- NOT:   2,172
- CNOT:  78,080
- Toffoli: 27,854
- Wires: 34,197

For comparison, linear_scan stub: 436 total / 90 Toffoli. Okasaki is ~248x more expensive
due to the recursive tree structure with full balance case computation. Expected — the PRD
explicitly says there is no gate budget for T5.

### Delete

Deferred to Bennett-cc0.1. Kahrs 2001 requires `app` (tree-merge, O(log n) recursion)
and `balleft`/`balright` — roughly 2× insert complexity. The `pmap_set` "latest write wins"
semantics fully satisfies the protocol without delete.

### Gotchas

1. **Nested @inline function inside pmap_set works**: `gr(idx)` is a local `@inline` function
   for slot selection. Julia fully inlines it; LLVM IR shows 0 extra calls (only 1 memcpy
   for NTuple return). Verified with `code_llvm`.

2. **Julia global scope `for` loop variable scoping**: `ok_count += 1` inside `for` at global
   scope throws `UndefVarError`. Must wrap tests in functions or use explicit `global` keyword.
   Not a bug in the impl — just a Julia 1.x scoping gotcha.

3. **Max tree height for 4 insertions is 3** (not 4 as the RBT depth formula suggests).
   Verified by enumerating all 4! = 24 insertion orderings. This confirms depth-3 traversal
   in `pmap_get` is sufficient.

4. **The prototype in test_rev_memory.jl** (Bennett-282) uses data-dependent `if` and is NOT
   branchless. Gate count: ~71,920. Our branchless version: ~108,106. The 50% overhead is the
   cost of computing all 4 balance cases speculatively instead of branching. Expected.

5. **Verify_reversibility passes**: 98/98 tests GREEN including `verify_reversibility(c; n_tests=3)`
   and 30+ random circuit-vs-oracle matches covering all 4 balance cases.

6. **False-path sensitization**: analyzed in the source file comment. The MUX structure is safe:
   each `ifelse` chain selects one of {gp_bal, p_bal, n_bal, old_val} based on a single
   `do_balance` predicate and two direction bits (ggl, pgl). The predicates are mutually exclusive.
   No diamond CFG interactions between balance cases.

### Test file

`test/test_persistent_okasaki.jl` — 5 testsets, 98 tests total:
1. verify_pmap_correctness (pure Julia)
2. 50 random + 6 deterministic oracle matches (all 4 balance cases covered)
3. reversible_compile + verify_reversibility
4. 30 random + 7 deterministic circuit-vs-oracle matches
5. Gate count baseline anchor (info only)

All 98 tests GREEN in ~30s.
