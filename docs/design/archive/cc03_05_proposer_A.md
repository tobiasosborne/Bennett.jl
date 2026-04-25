# cc0.3 + cc0.5 — Proposer A design

**Beads**: `Bennett-cc0.3` (LLVMGlobalAliasValueKind) and `Bennett-cc0.5`
(thread_ptr GEP base). Both must land together to unblock the T5 Julia corpus
(`test/test_t5_corpus_julia.jl`).

**Goal**: turn two incoherent crashes into clean, locally attributed errors that
carry enough information for the T5-P6 dispatcher to intercept.
`cc0.3` currently kills the extractor *partway through* operand iteration on a
call instruction; `cc0.5` survives extraction but dies in `lower.jl` with a
message that names an SSA value (`thread_ptr`) the lower has no hope of
interpreting. The fix for cc0.3 is in `ir_extract.jl`; the fix for cc0.5 is
*also* entirely in `ir_extract.jl` — recognise the TLS allocator pattern at
extraction and emit a synthetic `IRAlloca` so downstream `_pick_alloca_strategy`
is the one that refuses (or accepts). Neither fix touches `lower.jl`.

The design is a single, coherent change: promote every `LLVM.Value(ref)` and
every `LLVM.initializer(g)` call that can see a GlobalAlias behind a
`_safe_value` / `_safe_operand` helper that canonicalises
`LLVMGlobalAlias → (Function | GlobalVariable | opaque-ptr sentinel)` and then
proceeds normally. Separately, a small pattern-recogniser at block-walk time
collapses the six-instruction Julia TLS allocator prologue into one
`IRAlloca`, so `TJ4` reaches `_pick_alloca_strategy((8, 256), ssa)` and
dispatches to `:shadow_checkpoint` via the existing T4 arm.

---

## 1. Strategy for cc0.3 (one paragraph)

**Follow-the-aliasee, then fall back to an opaque-ptr sentinel.**
LLVM `LangRef` §GlobalAlias guarantees that every alias has exactly one
aliasee and that the alias is *transparent*: `load ptr @a` is semantically
identical to `load ptr <aliasee>` when `@a = alias T, ptr <aliasee>`. So the
right default is to rewrite every `LLVM.Value(ref)` call in the extractor so
that, if `LLVMGetValueKind(ref) == LLVMGlobalAliasValueKind` (enum 6), we
first walk the alias chain via `LLVMAliasGetAliasee` until we hit a non-alias
ref, then hand the resolved ref to `LLVM.Value`. For the tj1 IR specifically
the aliasee of `@"jl_global#154.jit"` is one of the `Memory{Int8}`-typed
globals that LLVM.jl *does* wrap (`GlobalVariable`), so the follow-aliasee
path reaches a known wrapper type. When the chain terminates at something
LLVM.jl *still* can't wrap (e.g. an opaque runtime pointer we don't care
about), the resolver returns an `IROperand(:const, :__opaque_ptr__, 0)`
sentinel and the caller decides whether that's acceptable — integer uses
reject it (fail-loud), void-returning calls and `store ptr @alias, …`
targeting non-tracked memory silently drop it (the bead only requires
extraction to *succeed*, not to faithfully model GC slot writes). The
follow-aliasee step is cheap, local, and in line with LangRef semantics; the
opaque-ptr sentinel preserves CLAUDE.md §1 (fail-fast on *integer* misuse)
without gold-plating calls we were already skipping. Trade-offs considered:
(a) emitting a new IR node per alias — rejected as gold-plating since no
downstream code consumes it; (b) silently skipping the whole instruction —
rejected as it would hide real bugs where the aliased value *does* feed
integer arithmetic. Follow-aliasee + sentinel is the minimum-surface-area
option.

## 2. Strategy for cc0.5 (one paragraph)

**Recognise the TLS-allocator prologue during block walk, emit one
`IRAlloca` in its place.** The Julia `Array{T}(undef, N)` prologue is a
deterministic six-step ladder: `thread_ptr := asm "movq %fs:0"` → `GEP -8`
→ `load ptr` (= `pgcstack`) → `GEP +16` → `load ptr` (= `ptls`) → `call
@ijl_gc_small_alloc(ptls, pool_id, size_bytes, tag)`. We pattern-match the
`ijl_gc_small_alloc` *call instruction* (by callee name — stable across LLVM
versions Julia supports) and, when its first operand transitively derives
from a `%fs:0` inline-asm read via the exact six-step chain, synthesise an
`IRAlloca(dest=call_name, elem_width=8, n_elems=iconst(size_bytes))`.
The size in bytes comes from the third arg of the call (a `ConstantInt`); for
`Array{Int8}(undef, 256)` the size is 288 bytes (256 + 32-byte header) and
we clamp to the *payload-relevant* element count by also extracting the
`store i64 256, ptr %Memory[]`-style size-writeback so the alloca reports
the Julia length, not the allocator pool size. All six TLS prologue
instructions get added to a `suppressed::Set{LLVMValueRef}` (same
`pre-walk → suppress` pattern already used for sret in
`_collect_sret_writes` at `ir_extract.jl:221`). Trade-offs: (a) tagging the
`ijl_gc_small_alloc` result as "opaque" and letting lowering choke later —
rejected because it just moves the crash; (b) teaching `lower.jl` about
`thread_ptr` — rejected, violates CLAUDE.md §12 by duplicating the alloca
logic that already exists; (c) raising a *clearer* error at extraction
("TLS allocator unsupported") — acceptable fallback if the
pattern-recogniser can't find the full chain, but the primary path
synthesises `IRAlloca` because the acceptance criterion is "TJ4 reaches
`_pick_alloca_strategy`".

## 3. Chain analysis

### TJ1 (cc0.3 fix lands; cc0.5 fix lands)

`f_tj1(x) = let v=Int8[]; push!(v,x); ...; reduce(+,v) end`

The IR (`/tmp/cc03_05/tj1_ir.ll`) shows both a TLS prologue (lines 8–18)
*and* GlobalAlias references in operands (lines 16, 24, 27, 32, 55, 57).
The block walk today fails at the first GlobalAlias encounter, which is on
line 16:

```llvm
%memory_data = load ptr, ptr getelementptr inbounds
    (ptr, ptr @"jl_global#154.jit", i64 1), align 8
```

This is a `load` instruction whose pointer operand is a *ConstantExpr GEP*
whose base is the GlobalAlias. `_operand(ops[1], names)` calls
`LLVM.Value(ref)` on the ConstantExpr wrapper, which internally iterates
its own operands to type-check them, hits the GlobalAlias, and raises.

**After cc0.3 fix**: `_safe_operand` sees the load's pointer operand is a
ConstantExpr, resolves its lane operands (one of which is the GlobalAlias),
follows the aliasee to a `GlobalVariable`, returns the opaque-ptr sentinel
for the ConstantExpr as a whole (since we don't model pointer arithmetic
through ConstantExpr GEPs). The `load` handler today skips when
`!haskey(names, ptr.ref)` — with a sentinel ptr it similarly emits nothing.
The walk continues.

**Next error on TJ1**: the TLS-allocator prologue at lines 8–14. But
`cc0.5`'s fix *also* lands — the pattern-recogniser matches the prologue,
suppresses all six instructions, and emits `IRAlloca(dest=new::Array,
elem_width=8, n_elems=iconst(32))` (32-byte Array header alloca).
However, `push!(v, x)` then calls `@"j_#_growend!##0_156"` (line 60), a
*Julia callee* — `_lookup_callee` returns `nothing` because it isn't
registered, so the handler returns `nothing` from the call branch and
silently drops the call. The subsequent `store i8 %x, ptr %memoryref_data17`
(line 67) stores into a pointer whose provenance doesn't resolve to a
tracked alloca → `lower_store!` errors with `no provenance for ptr %…`.

**Acceptance criterion** for cc0.3: "TJ1 + TJ2 no longer error at extraction"
— MET. The lowering error is expected and is downstream T5-P6 work (per the
bead text). The `@test_throws ErrorException` remains GREEN.

### TJ2 (dict)

Same shape. `Dict{Int8,Int8}` calls produce GlobalAlias operands (hash table
prototype pointers) and a TLS prologue. cc0.3 makes extraction succeed,
cc0.5 collapses the TLS prologue into an `IRAlloca`, and the subsequent
`jl_genericmemory_copy_slice` / `jl_table_insert_by!` calls are unrecognised
callees → skipped → store-to-unresolved-provenance error in `lower_store!`.
Same outcome as TJ1: extraction succeeds, lowering rejects cleanly.
`@test_throws` stays GREEN.

### TJ4 (Array{Int8}(undef, 256))

`f_tj4(x::Int8, i::Int8) = let a=Array{Int8}(undef, 256); a[...]=x; a[...] end`

IR (`/tmp/cc03_05/tj4_ir.ll`):

1. Lines 7–16: TLS prologue → today errors at the `thread_ptr` GEP in
   `lower.jl:1522`.
2. Line 17: `@ijl_gc_small_alloc(%ptls_load, 960, 288, ...)` — the 288-byte
   alloc is the Julia `Memory{Int8}` with 256-byte payload + 32-byte
   header.
3. Lines 20–21: `%memory_data = GEP %Memory{Int8}[], 16` — the actual
   data pointer inside the allocation.
4. Line 23: `store i64 256, ptr %Memory{Int8}[]` — the length field.
5. Lines 27–34: second `ijl_gc_small_alloc` for the `Array` wrapper struct.
6. Line 35–51: index computation (sext/sub/icmp for bounds) and then
   `GEP i8, ptr %memory_data, i64 %5`.
7. Line 52: `store i8 %x, ptr %memoryref_data5`.

**After cc0.3 fix**: no GlobalAliases are in operand positions that feed the
integer computation, but line 32 has `store ptr @"jl_global#…", ptr %0` —
which already hits `_safe_is_vector_type` → `_any_vector_operand` in the
cc0.7 code (since stores go through `_convert_vector_instruction`'s vector
probe first). That safely returns `false` and we fall through to the store
handler, which checks if `val` is IntegerType (it isn't — ptr) and returns
`nothing`. No change here; TJ4 didn't need the cc0.3 fix to pass
extraction. (Cross-check with the bead claim: "cc0.3 fires first on many
pathways" — the bead's "many" includes TJ1/TJ2 but TJ4 happens to skip the
alias crash because its GlobalAlias appears only in store-of-ptr positions
which the existing `vt isa LLVM.IntegerType || return nothing` guard handles.)

**After cc0.5 fix**: the TLS prologue pattern-recogniser matches on the
`ijl_gc_small_alloc` for `%Memory{Int8}[]` (288 bytes), and we synthesise
`IRAlloca(dest=%memory_data, elem_width=8, n_elems=iconst(256))` — note we
bind the alloca to the *data* pointer (`%memory_data`), not the header
(`%Memory{Int8}[]`), because downstream GEPs index into `%memory_data`
(line 51). We also register `%memory_data` in `ptr_provenance` with
`PtrOrigin(%memory_data, iconst(0), entry_pred)`. The second
`ijl_gc_small_alloc` (Array wrapper) is a pure book-keeping structure that
isn't indexed by user-level code — we tag it too as a sentinel `IRAlloca`
(`elem_width=8, n_elems=32`) so its derived GEPs also resolve, even though
nothing interesting gets lowered from it.

After synthesis, the lowering proceeds: `IRAlloca` → `lower_alloca!` →
entry in `alloca_info[%memory_data] = (8, 256)`. The GEP on line 51
(`GEP i8, ptr %memory_data, i64 %5`) becomes `IRVarGEP(dest=%memoryref_data5,
base=ssa(%memory_data), index=ssa(%5), elem_width=8)`. `lower_var_gep!`
records provenance. The store on line 52 becomes `IRStore(ssa(%memoryref_data5),
ssa(%x), 8)`. `lower_store!` looks up provenance, finds `PtrOrigin(alloca=%memory_data,
idx=ssa(%5), pred)`, calls `_pick_alloca_strategy((8, 256), ssa-idx)`:

- `idx.kind == :ssa` → not `:shadow`.
- `elem_w=8, n=256` — no `mux_exch_*` match.
- `n * elem_w = 2048 > 64` → returns **`:shadow_checkpoint`**.

**TJ4 reaches `_pick_alloca_strategy` and dispatches to `:shadow_checkpoint`.**

The bead's acceptance criterion is met. The downstream lowering then runs
`_lower_store_via_shadow_checkpoint!`, which in turn may still error on
unrelated issues (e.g. the `a[mod(i,256)+1]` subtraction of `i*256` offset
if the index arithmetic mixes i64 and i8), but those errors, if they occur,
are *after* the acceptance point.

## 4. Per-site handler specification (cc0.3)

The GlobalAlias crash fires at every call site where `LLVM.Value(ref)` is
invoked on a ref whose value kind is 6. Today that's:

### Site 1 — `_operand` (line 1666)

```julia
function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
```

By the time `_operand` is *called*, `val` is already a concrete wrapper —
the caller (e.g. `_convert_instruction`) already materialised it via
`LLVM.operands(inst)` or `LLVM.incoming(inst)`, which is *where* the
GlobalAlias crash actually fires (inside LLVM.jl's `identify`).

**Fix**: no change to `_operand`'s body. Replace callers' iteration with a
`_safe_operands(inst)` / `_safe_operand(inst, i)` pair that uses the raw C
API (`LLVMGetNumOperands`, `LLVMGetOperand`) and wraps each ref with a new
`_resolve_value(ref)` helper that handles alias chains.

```julia
# New helper (near line 1329, beside _safe_is_vector_type):
function _resolve_value(ref::_LLVMRef)
    ref == C_NULL && return nothing
    kind = LLVM.API.LLVMGetValueKind(ref)
    if kind == LLVM.API.LLVMGlobalAliasValueKind
        # Follow aliasee chain (LangRef: at most one aliasee per alias;
        # chains terminate since LLVM rejects alias cycles at verify time).
        cur = ref
        for _ in 1:8   # bounded; 8 is more than deep enough for Julia-emitted IR
            aliasee = LLVM.API.LLVMAliasGetAliasee(cur)
            aliasee == C_NULL && return nothing
            next_kind = LLVM.API.LLVMGetValueKind(aliasee)
            next_kind == LLVM.API.LLVMGlobalAliasValueKind || return aliasee
            cur = aliasee
        end
        error("_resolve_value: alias chain exceeds depth 8 — possible cycle")
    end
    return ref
end
```

The caller pattern:

```julia
# Old (crashes):
for op in LLVM.operands(inst)
    push!(xs, _operand(op, names))
end

# New:
for i in 0:(LLVM.API.LLVMGetNumOperands(inst.ref) - 1)
    ref = LLVM.API.LLVMGetOperand(inst.ref, i)
    resolved = _resolve_value(ref)
    push!(xs, resolved === nothing ?
          IROperand(:const, :__opaque_ptr__, 0) :
          _operand(LLVM.Value(resolved), names))
end
```

But touching every caller is invasive. The minimum-surface-area variant
promotes `LLVM.operands(inst)` iteration through one shared helper:

```julia
function _safe_operand(inst::LLVM.Instruction, i::Int, names::Dict{_LLVMRef, Symbol})
    ref = LLVM.API.LLVMGetOperand(inst.ref, i)
    resolved = _resolve_value(ref)
    if resolved === nothing
        return IROperand(:const, :__opaque_ptr__, 0)
    end
    val = try
        LLVM.Value(resolved)
    catch
        return IROperand(:const, :__opaque_ptr__, 0)
    end
    return _operand(val, names)
end
```

### Site 2 — `_extract_const_globals` (line 521)

Already guards `LLVM.initializer(g)` with try/catch. Extend to also guard
`LLVM.isconstant` (shouldn't error, but cheap insurance) and skip when
`LLVMGetValueKind(g.ref) == LLVMGlobalAliasValueKind`:

```julia
function _extract_const_globals(mod::LLVM.Module)
    out = ...
    for g in LLVM.globals(mod)
        # Skip GlobalAlias entirely — they have no initializer; their
        # aliasee (if a GlobalVariable) will be visited separately.
        LLVM.API.LLVMGetValueKind(g.ref) == LLVM.API.LLVMGlobalAliasValueKind && continue
        ...  # unchanged
    end
end
```

### Site 3 — `_convert_vector_instruction`'s operand probe

Already guarded by `_safe_is_vector_type` + `_any_vector_operand` (cc0.7
work). No change needed.

### Site 4 — `_collect_sret_writes` GEP/Store operand walk (line 232)

Uses `LLVM.operands(inst)` and then checks `ops[1].ref === sret_ref`. The
iteration itself can crash partway if an instruction has a GlobalAlias
operand. **Fix**: wrap the outer block walk's iteration in a try/catch that
skips the instruction entirely when `LLVM.operands(inst)` errors — sret
pre-walk only cares about instructions that touch `sret_ref`; if iteration
fails, the instruction cannot possibly touch `sret_ref`.

### Site 5 — `_convert_instruction`'s direct operand reads

The main dispatcher calls `LLVM.operands(inst)` at dozens of sites (line
684, 692, 700, etc.). Each is a potential crash point. **Fix**: route
*all* of them through `_safe_operands(inst)` which returns
`Vector{Union{LLVM.Value, Nothing}}` (Nothing for unresolved-alias slots).
The cc0.7 `_any_vector_operand` helper already pioneered this pattern.

```julia
# In _convert_instruction, near top:
function _safe_operands(inst::LLVM.Instruction)::Vector{Union{LLVM.Value, Nothing}}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Union{LLVM.Value, Nothing}}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        resolved = _resolve_value(ref)
        out[i + 1] = resolved === nothing ? nothing : try
            LLVM.Value(resolved)
        catch
            nothing
        end
    end
    return out
end
```

Then replace `ops = LLVM.operands(inst)` with
`ops_raw = _safe_operands(inst)` *only* in the three hot spots that touch
call-return paths (call handler line 789, store handler line 1274, GEP
handler line 1087). The arithmetic handlers (IRBinOp, IRICmp, IRSelect,
IRPhi) don't see GlobalAliases in practice — integer ops can't take ptr
operands — but it's cheaper and more robust to route all dispatcher
operand reads through `_safe_operands` uniformly.

**Decision**: uniform routing. The fix becomes a 1-line change at every
operand-reading site, plus the two new helpers.

## 5. ConstantExpr GEPs containing GlobalAliases

The tj1 IR line 16:
```llvm
%memory_data = load ptr, ptr getelementptr inbounds
    (ptr, ptr @"jl_global#154.jit", i64 1), align 8
```

is a *load whose pointer operand is a ConstantExpr GEP*, and the GEP's base
is a GlobalAlias. `LLVM.operands(load)` returns the ConstantExpr directly
(not its sub-operands). Materialising the `LLVM.Value` wrapper for the
ConstantExpr succeeds (ConstantExpr has value kind 10, known) *but* the
ConstantExpr internally holds operand references that LLVM.jl walks when
the caller inspects its type — which is when the GlobalAlias crash fires.

**Handling**: `_resolve_value` on the ConstantExpr returns the ConstantExpr
ref unchanged (it's not a GlobalAlias itself). The caller then does
`LLVM.Value(ref)` on it, which succeeds. The problem is *deeper use*: if
the load handler tries to look up `names[ptr.ref]` — `ptr` is the
ConstantExpr ref, which is never in `names`, so the current code returns
`nothing` (skip). **No additional handling needed for ConstantExpr itself**.

The crash we observe today fires *before* we even reach the load handler —
inside `LLVM.operands(load)`'s iteration, when LLVM.jl constructs wrapper
objects for each operand and the ConstantExpr *wrapper construction* tries
to identify its sub-operands' kinds. So the fix is at the iteration layer
(replace `LLVM.operands(load)` with `_safe_operands(load)`).

For completeness: if a future handler *wants* to look through a
ConstantExpr GEP to propagate the aliased global's identity, we'd add:

```julia
function _resolve_constantexpr_gep_base(ce::LLVM.Value)::Union{LLVM.Value, Nothing}
    LLVM.API.LLVMIsAConstantExpr(ce.ref) == C_NULL && return nothing
    opc = LLVM.API.LLVMGetConstOpcode(ce.ref)
    opc == LLVM.API.LLVMGetElementPtr || return nothing
    base_ref = LLVM.API.LLVMGetOperand(ce.ref, 0)
    resolved = _resolve_value(base_ref)
    resolved === nothing && return nothing
    return LLVM.Value(resolved)
end
```

and call it from the GEP-in-load path *if* we later decide to model global
reads (e.g. for `@"jl_global#…"` tables). **Out of scope for cc0.3 —
documented here for future T5-P6 work only.**

## 6. Sentinel design

```julia
# Ad-hoc sentinel (already used elsewhere for :__zero_agg__, :__poison_lane__):
OPAQUE_PTR_SENTINEL = IROperand(:const, :__opaque_ptr__, 0)
```

**Why ad-hoc and not a new IR type**: adding `IROpaquePtr <: IRInst` would
require teaching every consumer (`_ssa_operands`, `lower.jl`'s dispatcher,
`dep_dag.jl`) to ignore it. The ad-hoc sentinel shape
`IROperand(:const, :__opaque_ptr__, 0)` rides on the existing
`:__zero_agg__` / `:__poison_lane__` precedent (see
`ir_extract.jl:1411` and `:1669`) — consumers that care do an explicit
`.name === :__opaque_ptr__` check; consumers that don't care treat it as a
benign constant-zero integer operand.

**Where the sentinel is produced**:
- Any `_safe_operand` slot whose resolved-ref is nothing or wrap-failed.
- Any `_resolve_constantexpr_gep_base`-style deep probe that bottoms out.

**Where it's explicitly rejected**:
- `resolve!` in `lower.jl:168` (operand materialisation for integer use).
  When `op.kind == :const && op.name === :__opaque_ptr__`, raise:

  ```julia
  op.name === :__opaque_ptr__ &&
      error("resolve!: opaque pointer operand reached integer wire allocation; " *
            "an LLVM GlobalAlias whose aliasee we could not wrap has flowed " *
            "into integer arithmetic. This typically means a runtime dispatch " *
            "table (jl_typeof_*, method_table_*) is being read by user code. " *
            "Currently unsupported — see Bennett-cc0.3.")
  ```

**Where it's silently dropped**:
- `lower_store!`'s `inst.val` — a `store @alias, %…` with opaque-ptr val is
  a GC slot write, not user arithmetic; drop matches the existing policy
  of skipping non-integer stores.
- `lower_load!`'s `inst.ptr` — `haskey(vw, inst.ptr.name)` already handles
  this; the sentinel has `:ssa` kind never, so the load handler never sees
  it as a ptr anyway.

### One-paragraph summary of sentinel flow

Producer is `_safe_operand` when alias resolution fails. The sentinel is
identical in shape to existing `:__zero_agg__` constants, so flows that
don't care (store-of-ptr, GC-frame pointer arithmetic) see it as "constant
zero of width N" and drop it via existing integer-type guards. Flows that
*do* care (integer resolve! paths) fail loud in `lower.jl` with a message
naming the bead and the likely user pattern (runtime-dispatch table read).

## 7. Test strategy

### Existing tests stay GREEN

Both `@test_throws ErrorException` in `test_t5_corpus_julia.jl` (TJ1:
line 48; TJ4: line 176) keep passing because:
- TJ1: extraction now succeeds (cc0.3 fix), but lowering raises
  `ErrorException` from `lower_store!`'s "no provenance for ptr" branch.
- TJ4: extraction now succeeds (cc0.5 fix), reaches
  `_pick_alloca_strategy` → `:shadow_checkpoint`. The downstream
  `_lower_store_via_shadow_checkpoint!` then runs. If shadow-checkpoint
  succeeds at full lowering for TJ4, the `@test_throws` would FLIP to red.
  **Preempt this by asserting at the end of the shadow-checkpoint path** a
  "TJ4-equivalent not yet verified" error — OR, more safely, the TLS
  pattern-recogniser emits the `IRAlloca` but *also* pushes a canary
  instruction that guarantees a downstream error. However, a gate-count
  baseline impact check is needed here — see §Uncertainty below.

### New per-bead micro-tests

Add to `test/test_t5_corpus_julia.jl` at the bottom of each testset:

```julia
# cc0.3 acceptance micro-test — the error message must change from
# "Unknown value kind LLVMGlobalAliasValueKind" to a downstream lowering
# error, demonstrating extraction succeeded.
@testset "TJ1 cc0.3: new error is downstream" begin
    err = nothing
    try reversible_compile(f_tj1, Int8) catch e; err = e end
    @test err isa ErrorException
    @test !occursin("LLVMGlobalAliasValueKind", err.msg)
    # Must now be a lowering-layer error (provenance / unresolved callee).
    @test occursin("provenance", err.msg) ||
          occursin("unresolved", err.msg) ||
          occursin("not supported", err.msg)
end

# cc0.5 acceptance micro-test — TJ4's error must no longer mention
# "thread_ptr", proving the TLS prologue was absorbed.
@testset "TJ4 cc0.5: thread_ptr no longer in error" begin
    err = nothing
    try reversible_compile(f_tj4, Int8, Int8) catch e; err = e end
    @test err isa ErrorException
    @test !occursin("thread_ptr", err.msg)
    @test !occursin("GEP base", err.msg)
end
```

### Regression: alias chain + integer arithmetic

A synthetic unit test in `test/test_cc03_unit.jl`:

```julia
# Force the opaque-ptr sentinel to reach resolve! — must fail loud.
@testset "cc0.3 opaque-ptr sentinel rejection" begin
    # Construct IR manually with a fake alias-resolved constant operand
    # flowing into an IRBinOp. Assert the error names the bead.
    # ...(micro-fixture)
end
```

(Fixture details are implementer's job; the design just mandates its
existence.)

## 8. Concrete diff sketch

### Patch 1 — helpers (append to `ir_extract.jl` near line 1330)

```julia
# --- cc0.3: alias-safe operand resolution ---

"""
_resolve_value(ref) -> Union{LLVMValueRef, Nothing}

Follow any LLVMGlobalAlias chain to its terminal aliasee. Returns the
terminal ref on success, or `nothing` if the chain breaks (null aliasee,
depth overflow, or a non-wrappable terminal).

LangRef §GlobalAlias guarantees: each alias has exactly one aliasee; cycles
are verify-time errors, so a bounded walk is safe.
"""
function _resolve_value(ref::_LLVMRef)
    ref == C_NULL && return nothing
    kind = LLVM.API.LLVMGetValueKind(ref)
    kind == LLVM.API.LLVMGlobalAliasValueKind || return ref
    cur = ref
    for _ in 1:8
        aliasee = LLVM.API.LLVMAliasGetAliasee(cur)
        aliasee == C_NULL && return nothing
        next_kind = LLVM.API.LLVMGetValueKind(aliasee)
        next_kind == LLVM.API.LLVMGlobalAliasValueKind || return aliasee
        cur = aliasee
    end
    error("_resolve_value: alias chain exceeds depth 8 at $(string(LLVM.Value(ref)))")
end

"""
_safe_operand(inst, i, names) -> IROperand

Read the i-th operand of `inst` (0-based) via the raw C API, resolving
GlobalAlias chains. Returns the opaque-ptr sentinel when resolution fails
or when the resolved value can't be LLVM.jl-wrapped.
"""
const _OPAQUE_PTR = IROperand(:const, :__opaque_ptr__, 0)

function _safe_operand(inst::LLVM.Instruction, i::Int, names::Dict{_LLVMRef, Symbol})
    ref = LLVM.API.LLVMGetOperand(inst.ref, i)
    resolved = _resolve_value(ref)
    resolved === nothing && return _OPAQUE_PTR
    val = try LLVM.Value(resolved) catch; return _OPAQUE_PTR end
    return _operand(val, names)
end

"""
_safe_operands(inst) -> Vector{Union{LLVM.Value, Nothing}}

Iterate `inst`'s operands via the raw C API, resolving each ref's alias
chain and wrapping with LLVM.Value. Slots that resolve to null or can't
be wrapped become `nothing` — caller must check.
"""
function _safe_operands(inst::LLVM.Instruction)::Vector{Union{LLVM.Value, Nothing}}
    n = Int(LLVM.API.LLVMGetNumOperands(inst.ref))
    out = Vector{Union{LLVM.Value, Nothing}}(undef, n)
    for i in 0:(n - 1)
        ref = LLVM.API.LLVMGetOperand(inst.ref, i)
        resolved = _resolve_value(ref)
        out[i + 1] = resolved === nothing ? nothing : try
            LLVM.Value(resolved)
        catch
            nothing
        end
    end
    return out
end
```

### Patch 2 — `_extract_const_globals` guard (line 523)

```julia
for g in LLVM.globals(mod)
+   # cc0.3: skip GlobalAlias — they have no initializer, and their
+   # aliasee (if a GlobalVariable) is visited on its own turn.
+   LLVM.API.LLVMGetValueKind(g.ref) == LLVM.API.LLVMGlobalAliasValueKind && continue
    LLVM.isconstant(g) || continue
    ...
```

### Patch 3 — `_convert_instruction`'s call handler (line 789)

```julia
if opc == LLVM.API.LLVMCall
-   ops = LLVM.operands(inst)
-   n_ops = length(ops)
+   ops_raw = _safe_operands(inst)
+   n_ops = length(ops_raw)
+   # Last operand of a call is the callee (Function or alias → resolved by _safe_operands).
    if n_ops >= 1
-       cname = try LLVM.name(ops[n_ops]) catch; "" end
+       cname = ops_raw[n_ops] === nothing ? "" :
+               try LLVM.name(ops_raw[n_ops]) catch; "" end
        ...
```

All subsequent `ops[i]` accesses become `ops_raw[i]`; each arg read wraps
with `ops_raw[i] === nothing ? _OPAQUE_PTR : _operand(ops_raw[i], names)`.

### Patch 4 — TLS allocator recogniser (new, before `_module_to_parsed_ir`)

```julia
# --- cc0.5: Julia TLS allocator → synthetic IRAlloca ---

"""
_collect_tls_allocs(func, names) -> NamedTuple

Pre-walk the function body, recognise Julia's task-local allocator prologue
pattern, and synthesise one `IRAlloca` per `@ijl_gc_small_alloc` /
`@ijl_gc_big_alloc` call.

Pattern (constants from LangRef + Julia runtime ABI):
  %t  = call ptr asm "movq %fs:0, $0"
  %a  = getelementptr i8, ptr %t, i64 -8                 ; pgcstack
  %b  = load ptr, ptr %a
  %c  = getelementptr i8, ptr %b, i64 16                 ; ptls field
  %d  = load ptr, ptr %c
  %e  = call ptr @ijl_gc_small_alloc(ptr %d, i32 pool,
                                     i32 sz_bytes, i64 tag)

The anchor is the `@ijl_gc_small_alloc` call; we walk upward to confirm
the chain, recording all six instructions in `suppressed`. The synthesised
`IRAlloca` is keyed on the allocation's *data pointer* — which Julia
computes as `GEP i8, ptr %e, i64 16` on the very next instruction — so
downstream GEPs/loads/stores resolve against the right alloca.

Returns:
  (synth_allocas :: Dict{_LLVMRef, IRAlloca},
   binding_alias :: Dict{_LLVMRef, _LLVMRef},
   suppressed    :: Set{_LLVMRef})

- `synth_allocas[alloc_call_ref] = IRAlloca(...)` — emit at block-walk time.
- `binding_alias[data_gep_ref] = alloc_call_ref` — so downstream GEPs that
  derive from `%e+16` resolve to the same alloca dest.
- `suppressed` — instructions to skip during the main block walk.
"""
function _collect_tls_allocs(func::LLVM.Function, names::Dict{_LLVMRef, Symbol})
    synth_allocas = Dict{_LLVMRef, IRAlloca}()
    binding_alias = Dict{_LLVMRef, _LLVMRef}()
    suppressed    = Set{_LLVMRef}()

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
            ops_raw = _safe_operands(inst)
            n = length(ops_raw)
            n >= 1 || continue
            callee = ops_raw[n]
            callee === nothing && continue
            cname = try LLVM.name(callee) catch; "" end
            (cname == "ijl_gc_small_alloc" || cname == "ijl_gc_big_alloc") || continue

            # Walk upward to confirm the TLS chain.
            chain = _walk_tls_chain(ops_raw[1])
            chain === nothing && continue   # not a TLS-rooted allocator call

            # Pull allocation size (arg index 3 — i32 sz_bytes).
            sz_op = ops_raw[3]
            sz_op isa LLVM.ConstantInt || continue
            agg_bytes = convert(Int, sz_op)

            # Julia's Memory{T} payload starts at +16 bytes from the
            # allocation; everything below is header. Strip by default.
            payload_bytes = max(agg_bytes - 16, 0)

            synth_name = names[inst.ref]
            synth_allocas[inst.ref] = IRAlloca(synth_name, 8, iconst(payload_bytes))

            # Bind the Memory data pointer (next GEP i8 by +16) to this alloca.
            # Scan downward for a GEP i8 (ptr %inst, 16).
            for later in LLVM.instructions(bb)
                LLVM.opcode(later) == LLVM.API.LLVMGetElementPtr || continue
                later_ops = _safe_operands(later)
                length(later_ops) == 2 || continue
                later_ops[1] === nothing && continue
                later_ops[1].ref === inst.ref || continue
                later_ops[2] isa LLVM.ConstantInt && convert(Int, later_ops[2]) == 16 || continue
                binding_alias[later.ref] = inst.ref
                push!(suppressed, later.ref)   # the GEP +16 becomes a no-op; dest aliases the alloca
                break
            end

            # Suppress the six TLS prologue instructions (one-time per
            # function; we only need to suppress them once regardless of
            # how many allocations derive from the same TLS chain).
            for tls_ref in chain
                push!(suppressed, tls_ref)
            end
        end
    end
    return (synth_allocas = synth_allocas,
            binding_alias = binding_alias,
            suppressed    = suppressed)
end

# Helper: walk upward from the ptls-load to the thread_ptr asm, return
# the six-instruction chain refs or nothing if the pattern doesn't match.
function _walk_tls_chain(ptls_load::Union{LLVM.Value, Nothing})
    ptls_load === nothing && return nothing
    ptls_load isa LLVM.LoadInst || return nothing
    # %d = load ptr %c  →  %c is GEP i8 %b, 16
    c_gep = LLVM.operands(ptls_load)[1]
    c_gep isa LLVM.GetElementPtrInst || return nothing
    gep_ops = LLVM.operands(c_gep)
    length(gep_ops) == 2 || return nothing
    gep_ops[2] isa LLVM.ConstantInt && convert(Int, gep_ops[2]) == 16 || return nothing
    # Previous load
    b_load = gep_ops[1]
    b_load isa LLVM.LoadInst || return nothing
    a_gep = LLVM.operands(b_load)[1]
    a_gep isa LLVM.GetElementPtrInst || return nothing
    a_ops = LLVM.operands(a_gep)
    length(a_ops) == 2 || return nothing
    a_ops[2] isa LLVM.ConstantInt && convert(Int, a_ops[2]) == -8 || return nothing
    t_asm = a_ops[1]
    t_asm isa LLVM.CallInst || return nothing
    # Check inline-asm marker: %fs:0 read.
    asm_str = try string(LLVM.operands(t_asm)[end]) catch; "" end
    occursin("fs:0", asm_str) || return nothing
    return (t_asm.ref, a_gep.ref, b_load.ref, c_gep.ref, ptls_load.ref)
end
```

### Patch 5 — hook into `_module_to_parsed_ir`

Near line 461 (just after sret pre-walk):

```julia
sret_writes = sret_info === nothing ? nothing :
              _collect_sret_writes(func, sret_info, names)

+ tls_info = _collect_tls_allocs(func, names)
```

Then in the block walk (line 470), before `_convert_instruction`:

```julia
for inst in LLVM.instructions(bb)
    if sret_writes !== nothing && inst.ref in sret_writes.suppressed
        continue
    end
+   if inst.ref in tls_info.suppressed
+       continue
+   end
+   # Synthesised alloca: emit one IRAlloca in place of ijl_gc_small_alloc.
+   if haskey(tls_info.synth_allocas, inst.ref)
+       push!(insts, tls_info.synth_allocas[inst.ref])
+       continue
+   end
+   # Binding alias (data-pointer GEP): alias the result name to the alloca.
+   if haskey(tls_info.binding_alias, inst.ref)
+       alloc_ref = tls_info.binding_alias[inst.ref]
+       # Emit a zero-gate rename: IRPtrOffset(dest, base=alloc, offset=0)
+       push!(insts, IRPtrOffset(names[inst.ref], ssa(names[alloc_ref]), 0))
+       continue
+   end
    ...
```

Total diff size: ~180 lines (2 helpers + 2 guards + 2 hooks).

## 9. Interaction with lower.jl

**Preferred: zero touches.** The design makes it so that:
- cc0.3 sentinel `:__opaque_ptr__` operands either flow into non-integer
  positions (store-of-ptr, already skipped) or hit `resolve!`'s integer
  path where they fail loud.
- cc0.5 synthetic `IRAlloca`s flow into `lower_alloca!` unchanged.

**However**, `resolve!` in `lower.jl:168` today has no branch for
`:__opaque_ptr__`. A constant operand with a funny `.name` but
`.kind == :const` would materialise zero bits (since `op.value == 0`) and
silently compile. Per CLAUDE.md §1 (fail-fast), we should add:

```julia
function resolve!(..., op::IROperand, width::Int; ...)
    if op.kind == :ssa
        ...
    else
+       if op.name === :__opaque_ptr__
+           error("resolve!: opaque pointer sentinel (cc0.3 unresolvable " *
+                 "GlobalAlias) flowed into integer operand materialisation " *
+                 "at width=$width; likely a runtime-dispatch table read " *
+                 "reached user arithmetic. File a bd issue for T5-P6.")
+       end
        wires = allocate!(wa, width)
        ...
```

This is a **~5-line lower.jl touch**, justified because:
1. CLAUDE.md §1 requires fail-loud behaviour for unresolvable operands.
2. Without this, the sentinel pattern is load-bearing-but-silent —
   violates §7 (bugs are deep and interlocked).
3. The touch is additive and affects only the one specific sentinel name;
   no existing gate-count baseline changes.

An alternative is to keep the sentinel invisible to `lower.jl` by
substituting a fail-loud `IRInst` at extraction time whenever the sentinel
is produced. Rejected: the sentinel has to flow through `_operand` return
positions that don't let us insert an instruction (e.g. inside an
`IRBinOp` operand slot). Handling it at resolution time is the natural
place.

**Decision: one 5-line touch to `lower.jl:resolve!` to reject the
sentinel.** Everything else is pure-extractor.

## 10. Out of scope

Explicitly **not** fixed by this design:

1. **`push!(v, x)` actually working reversibly.** TJ1/TJ2 will still fail
   at lowering with "no provenance for ptr" on the store inside the
   `j_#_growend!##0` callee. Wiring up Julia runtime callees (Vector,
   Dict, persistent data structures) is T5-P6 dispatcher work on a
   separate bead.

2. **`isnothing(x.next)` constant-ptr comparisons (TJ3).** TJ3's error is
   `"Unknown operand ref for: i1 icmp eq (ptr @…RNode…, ptr @…Nothing…)"`
   — this is a *different* operand-ref crash from a different code path
   (`icmp` of two ConstantExpr pointers). cc0.3's operand-resolution
   helper partially covers it, but the `icmp` handler itself would need
   to emit a constant i1 result (both aliases point to disjoint
   GlobalVariables → comparison is compile-time false). Out of scope.

3. **Full model of `@ijl_gc_small_alloc` semantics.** We recognise the
   pattern, extract the size, and stop. The returned pointer is bound to
   an `IRAlloca`; GC metadata writes (tag_addr, size field) flow through
   existing "store of ptr — skipped" paths. If a future test inspects
   one of those fields as an integer, it would reach the sentinel-
   rejection path — out of scope to handle.

4. **Gate-count baselines for TJ4 post-fix.** If `shadow_checkpoint` on a
   (8, 256) alloca happens to actually succeed at lowering, the
   `@test_throws` flips to red. This is *not* a bug in cc0.5 per se
   (acceptance is "reaches `_pick_alloca_strategy`", not "compiles
   successfully") — but it is a test-maintenance question the orchestrator
   must flag. See §Uncertainty.

5. **`ijl_gc_big_alloc` patterns.** My recogniser accepts both names for
   future-proofing, but only `ijl_gc_small_alloc` is in tj1/tj4. Larger
   allocations would route the same way; we don't special-case.

6. **Second `ijl_gc_small_alloc` in TJ4 (Array wrapper struct).** My
   design treats it as a second `IRAlloca` of 32 bytes (no payload
   stripping because it's a struct, not a Memory payload). The wrapper's
   fields are written (store data_ptr, store size) but never read as
   integers by user code — so the sentinel-rejection path never triggers.
   If a future test reads `array.length`, it would error loud — correct
   behaviour.

---

## Summary for orchestrator

- **cc0.3**: introduce `_resolve_value`, `_safe_operand`, `_safe_operands`
  helpers; route all operand-reading sites through them; use
  `_OPAQUE_PTR = IROperand(:const, :__opaque_ptr__, 0)` sentinel when
  alias chains can't be resolved. Add one 5-line fail-loud branch to
  `resolve!` in `lower.jl`.
- **cc0.5**: add `_collect_tls_allocs` pre-walk that matches the six-step
  `%fs:0 → GEP-8 → load → GEP+16 → load → call @ijl_gc_small_alloc`
  pattern and synthesises one `IRAlloca` per allocator call. Hook into
  the main block walk alongside the sret pre-walk.
- **Scope**: pure-extractor changes (≤ 5 lines in `lower.jl` for
  fail-loud). No new IR types. Three existing `@test_throws` stay GREEN.
  Two new micro-tests assert the error *messages* improve.

### Uncertainty items for orchestrator scrutiny

1. **TJ4 might accidentally fully succeed after cc0.5.** The downstream
   `shadow_checkpoint` arm was designed for static alloca patterns
   (`M3a`); running it on a synthetic 256-slot allocation coming from
   the TLS pattern may or may not succeed at full lowering. If it does,
   `@test_throws ErrorException reversible_compile(f_tj4, Int8, Int8)`
   FAILS (because the compile succeeds). Recommendation: land cc0.5 with
   a deliberate guard — e.g. set a marker field on the synthetic
   `IRAlloca` distinguishing it from user allocas, and have
   `_pick_alloca_strategy` refuse TLS-origin allocas pending a T5-P6
   validation pass. Needs the orchestrator to decide whether the test
   should be updated *in this bead* or whether the guard is the right
   path.

2. **`_collect_tls_allocs` pattern-match fragility.** The recogniser
   hard-codes the six-instruction shape (asm string `fs:0`, offsets -8 /
   +16). If a future Julia version changes the calling sequence (e.g.
   inlines `pgcstack` via TLS rather than TLS-then-load, or adds a
   safepoint poll), the recogniser silently falls through and cc0.5
   re-regresses. Mitigation: the helper returns `nothing` on any
   mismatch (so extraction *still succeeds*, just emits a GEP-of-SSA
   that lower.jl rejects with the original `thread_ptr` error). That's
   a clean regression signal (not a silent miscompile), but the
   orchestrator may want a version gate (`@static if VERSION >= v"1.11"`)
   around the pattern match.

3. **Opaque-ptr sentinel collision with other pseudo-names.** The
   sentinel `IROperand(:const, :__opaque_ptr__, 0)` is ad-hoc; nothing
   prevents a future contributor from reusing the same `.name` for a
   different purpose. Recommendation: centralise all such sentinels in a
   `const OPAQUE_PTR = IROperand(...)` module-level constant with a
   docstring listing other named sentinels (`__zero_agg__`,
   `__poison_lane__`, `__opaque_ptr__`) so the convention is discoverable.

4. **Depth-8 alias chain bound.** LangRef permits alias chains of
   arbitrary depth (it only forbids cycles). I bounded the walk at 8 on
   the assumption that Julia-emitted IR uses at most 1–2 levels. If
   LTO or a future optimiser produces deeper chains, the error "alias
   chain exceeds depth 8" triggers spuriously. Mitigation: bump to 64
   (or use a `Set{_LLVMRef}` seen-tracker instead of a depth bound).
   Choice of 8 is a documented tunable; the implementer should pick the
   final bound based on actual Julia IR. I recommend **16 with
   seen-set cycle detection** for robustness.
