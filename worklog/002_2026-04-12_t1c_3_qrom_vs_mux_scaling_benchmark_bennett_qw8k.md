## 2026-04-12 — T1c.3: QROM vs MUX scaling benchmark (Bennett-qw8k)

### Head-to-head at W=8, varying L

Ran `benchmark/bc3_qrom_vs_mux.jl`:

```
  L  | QROM gates | MUX tree gates | Ratio (MUX/QROM)
  ---+------------+----------------+-----------------
    4|         70 |            222 |    3.2×
    8|        146 |            506 |    3.5×
   16|        312 |           1088 |    3.5×
   32|        632 |           2240 |    3.5×
   64|       1270 |           4542 |    3.6×
  128|       2550 |           9150 |    3.6×
```

**QROM wins at every L ≥ 4 with no crossover.** Ratio grows slowly (~log L factor
from MUX tree's log L-deep binary chain), stays ≈3.5× at practical W=8.

### Toffoli-only comparison (the dominant cost in fault-tolerant quantum circuits)

| L | QROM Toffoli | MUX Toffoli | Ratio  |
|---|--------------|-------------|--------|
|  4|           12 |          48 | 4.0×  |
|  8|           28 |         112 | 4.0×  |
| 16|           60 |         240 | 4.0×  |
| 32|          124 |         496 | 4.0×  |
| 64|          252 |        1008 | 4.0×  |
|128|          508 |        2032 | 4.0×  |

**QROM Toffoli = 4(L-1) exactly, matches Babbush-Gidney §III.C claim.**
MUX tree is 4×. Constant ratio because both paths use 1 Toffoli per MUX bit per
level, but MUX tree has log L levels × L/2 MUXes × W bits = L·W·log L Toffolis,
while QROM has 2(L-1) ≈ L regardless of W.

### Wider elements (L=8, varying W)

| W  | QROM total | MUX total | Ratio |
|----|-----------|-----------|-------|
|  8 |       166 |       526 | 3.2× |
| 16 |       232 |      1040 | 4.5× |
| 32 |       356 |      2060 | 5.8× |
| 64 |       578 |      4074 | 7.0× |

**QROM's W-scaling advantage widens with width.** QROM's Toffoli stays at 28
(= 4(8-1)) for every W; MUX tree scales linearly with W because each MUX
operates bitwise.

### MUX EXCH reference (T1b callees)

| Primitive             | Total | Toffoli | Wires |
|-----------------------|-------|---------|-------|
| soft_mux_load_4x8     | 7,514 |   1,658 | 2,753 |
| soft_mux_load_8x8     | 9,590 |   2,674 | 3,777 |
| QROM L=4 W=8          |    70 |      12 |    23 |
| QROM L=8 W=8          |   146 |      28 |    26 |

**QROM is 107× smaller than MUX EXCH at L=4, 66× smaller at L=8.** The huge
gap is because MUX EXCH compiles a full Julia function with nested ifelse
chains — branchless but O(W)-per-slot — whereas QROM compiles to a minimal
binary-tree-of-ANDs circuit. MUX EXCH remains the right choice for WRITABLE
alloca-backed arrays (T1b.3), but for read-only constant tables QROM
unambiguously dominates.

### Artifact

`benchmark/bc3_qrom_vs_mux.jl` — reproducible, run with `julia --project` to
regenerate the tables. Each entry runs `verify_reversibility` so regressions
surface immediately.

### What this unblocks

- **BC.3 full SHA-256** — SHA uses no tables but the bit-reversal/round-constant
  arrays (K[64]) can go through QROM. Mild speedup expected.
- **AES benchmark** — 256-entry S-box is QROM's ideal target: 4(256-1) ≈ 1024
  Toffolis post-Bennett vs the MUX tree's ≈ 60k. Order-of-magnitude headline.
- **Soft-float trig/log tables** — currently not implemented; would become
  feasible with QROM as the backing primitive.

## 2026-04-12 — T2a.1+T2a.2: MemorySSA investigation + ingest (Bennett-law3, Bennett-81bs)

### Investigation conclusion

**GO via printer-pass-output parsing.** `docs/memory/memssa_investigation.md`
documents the trade space: LLVM.jl 9.4.6 exposes MemorySSA only through
pipeline passes (`print<memoryssa>`, `verify<memoryssa>`), not as a queryable
C-API object. But we CAN run the printer and capture its stderr output via a
Julia `Pipe`, then parse the annotation comments — the output is stable LLVM
textual IR format (`; N = MemoryDef(M)`, `; MemoryUse(N)`, `; N = MemoryPhi(...)`).

Rejected alternatives: direct ccall (portability), custom C++ pass (build infra
in a pure-Julia package), full reimplementation (2500 LOC of LLVM analysis).

### Implementation — `src/memssa.jl`

```julia
struct MemSSAInfo
    def_at_line::Dict{Int, Int}              # line → Def id
    def_clobber::Dict{Int, Union{Int, Symbol}}  # Def → clobbered (Int or :live_on_entry)
    use_at_line::Dict{Int, Int}              # line → Def the use reads from
    phis::Dict{Int, Vector{Tuple{Symbol, Int}}}  # Phi id → [(block, incoming_id), …]
    annotated_ir::String
end

run_memssa(f, arg_types; preprocess=true) -> MemSSAInfo
parse_memssa_annotations(txt) -> MemSSAInfo  # standalone parser (testable)
```

Parser uses regex on annotation lines:
  - `_RE_MEM_DEF` → `"; (\d+) = MemoryDef((\d+|liveOnEntry))"`
  - `_RE_MEM_USE` → `"; MemoryUse((\d+|liveOnEntry))"`
  - `_RE_MEM_PHI` → `"; (\d+) = MemoryPhi(...)"` with nested `{bb,id}` splits

Annotations precede their instruction — track as pending, attach to next
non-annotation line. Blank lines left pending (LLVM sometimes inserts them).

### Integration — `extract_parsed_ir`

New kwarg `use_memory_ssa::Bool=false`. When true:
1. Run MemorySSA printer pass on the raw (possibly preprocessed) IR, capture
   output via `redirect_stderr` → `Pipe`.
2. Parse the capture into `MemSSAInfo`.
3. Stamp onto `ParsedIR.memssa` alongside the existing walked IR.

Backward-compat: `parsed.memssa === nothing` when the kwarg is false. No existing
call sites affected.

### ParsedIR extension

Added `memssa::Any` field (typed Any to avoid circular dep with `src/memssa.jl`
which imports `ParsedIR`). Three constructor overloads preserve every existing
call site.

### Capture mechanism — cache the gotcha

```julia
pipe = Pipe()
LLVM.Context() do _ctx
    mod = parse(LLVM.Module, ir_string)
    Base.redirect_stderr(pipe) do
        @dispose pb = LLVM.NewPMPassBuilder() begin
            LLVM.add!(pb, "print<memoryssa>")
            LLVM.run!(pb, mod)
        end
    end
end
close(pipe.in)
annotated = read(pipe, String)
```

- `IOBuffer` does NOT work with `redirect_stderr`; must use `Pipe`.
- Must `close(pipe.in)` after the pass runs, before reading. Otherwise `read`
  blocks.
- Handles 10KB+ captures without issue.

### What this unblocks

- T2a.3 (Bennett-08wr): integration tests for cases T0 preprocessing misses
  (conditional stores, aliased pointers, phi-merged memory states).
- Beyond: once `lower_load!` consults `ctx.memssa.use_at_line` to identify the
  exact MemoryDef its Use clobbers, we can correctly lower arbitrary memory
  patterns — not just the MVP "single alloca, linear stores, var-idx load"
  covered by `ptr_provenance`.

### Test coverage — `test/test_memssa.jl`

15 assertions:
- Basic Def/Use parse on hand-crafted annotation fragment
- MemoryPhi parse on diamond-CFG fragment
- End-to-end `run_memssa(f, arg_types)` on a Julia function with allocas
- No-op behavior for memory-free functions
- `use_memory_ssa=true` kwarg round-trip through `extract_parsed_ir`

## 2026-04-12 — T2a.3: integration tests — cases T0 misses (Bennett-08wr)

### Scope

Demonstrate that for memory patterns T0 preprocessing (sroa / mem2reg /
simplifycfg / instcombine) cannot fully eliminate, MemorySSA's Def/Use/Phi
graph captures the necessary information to drive a correct lowering. Wiring
that info into `lower_load!` for actual gate-count wins is a follow-up (filed
as implicit technical debt — `ctx.memssa` is populated but currently unused
by lowering decisions).

### Test file — `test/test_memssa_integration.jl`

23 assertions across 5 patterns:

1. **var-index load into local array** — SROA cannot split an alloca accessed
   by a runtime index. After preprocessing, stores/loads survive; MemorySSA
   annotates each with Def/Use IDs.

2. **conditional store in diamond CFG produces MemoryPhi** — The canonical
   paper-winning case: `if cond; a[i] = x; end; a[i]`. Memssa synthesizes a
   `MemoryPhi` at the merge block, telling us the load's value depends on
   which branch was taken — info that `ptr_provenance` currently loses.

3. **sequential stores + load** — Multiple stores to the same `Ref`; each
   store creates a distinct MemoryDef, the load's MemoryUse points to the
   final one. Demonstrates clobber-chain walking.

4. **memssa-off matches T0 behavior exactly** — Regression guard: turning on
   `use_memory_ssa` doesn't mutate the walked IR (same blocks, args, ret_width).
   Pure addition via the `parsed.memssa` field.

5. **annotation graph consistency** — Every Use's referenced Def ID exists in
   `def_clobber` (or is the live-on-entry sentinel `0`). Every Def's clobber
   target exists. No dangling IDs — confirms parser integrity against a real
   Julia function's memssa output.

### Gotcha: SROA + loop = vector instructions

Originally included a `for k in 1:4; s += a[k]; end` test case. With
`preprocess=true`, SROA splits the 4-element array into an `<i8 x 4>` vector
and emits `insertelement` / `extractelement` — which our IR walker doesn't
handle. Switched to a `Ref` pattern (scalar alloca) to avoid vectorization.

Vector-instruction support is separate (Bennett-vb2 per the VISION PRD
Tier 4). Filed implicit as future work.

### Expected follow-up work (not in scope for T2a.3)

- Wire `ctx.memssa.use_at_line[line]` into `lower_load!`: when present and
  the referenced Def is a specific store, look up that store's value in `vw`
  and alias-copy. When it's a `MemoryPhi`, construct a value-phi at load time.
- Correlate memssa's line-indexed annotations with LLVM.jl's instruction walk
  (currently keyed by text-line position in the annotated IR — will need a
  second pass that matches instructions by their textual form).
- Gate-count benchmark on cases (1) and (2): measure whether memssa-informed
  lowering beats our current heuristic `ptr_provenance`.

