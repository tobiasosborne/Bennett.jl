# Proposer A — sret aggregate-return support (Bennett-dv1z)

## Scope and intent

Add support in `src/ir_extract.jl` for Julia functions that LLVM lowers via the
`sret` calling convention. The design is contained entirely in `ir_extract.jl`:
no changes to `ir_types.jl`, `lower.jl`, `bennett.jl`, `gates.jl`, or the simulator.
This satisfies CLAUDE.md invariant #4 (no incidental core changes during a 3+1
proposer process) and means existing tests **cannot** regress on gate counts: the
IR they see downstream is byte-for-byte identical when sret is absent.

The strategy is "extract-time synthesis": when sret is detected, the walker
fabricates a virtual aggregate SSA value by replaying the callee's stores into
the sret pointer as a chain of `IRInsertValue` instructions, then emits an
`IRRet` referring to that synthetic aggregate. Downstream lowering sees exactly
the same shape of IR it already handles for n=2 by-value returns; gate-count
baselines for the new larger returns are determined by the existing
`lower_insertvalue!` / `lower_extractvalue!` paths.

The design covers four sret variants observed in real Julia/LLVM output:

| Variant | Trigger | Store shape |
|---|---|---|
| Direct | optimize=true, single-block return | `store iM val, ptr %sret_return` and `store ... ptr %gepN` (constant-offset GEPs) |
| Memcpy | optimize=false | function builds `%local = alloca [N x iM]`, stores into it, then `llvm.memcpy(%sret_return, %local, K)` |
| Multi-block | conditional/branched returns | each predecessor block independently writes to GEPs of `%sret_return`; only one `ret void` |
| Phi-merged | optimizer hoisted the writes | sret pointer is the same root, but values may come from phi nodes — handled transparently by reusing the existing phi-resolution path in lower.jl |

The Direct variant is the only one needed for SHA-256 (BC.3) under the project's
default `optimize=true`. The Memcpy variant is supported because `optimize=false`
is documented in CLAUDE.md as "predictable IR for testing" and the entire
preprocessing pipeline (`DEFAULT_PREPROCESSING_PASSES`) explicitly exists to
canonicalise it. Multi-block and phi-merged are required for any non-trivial
function (any branching tuple constructor — error returns, conditional pairs).

## 1. Detection

### Where

The detection runs once, at the top of `_module_to_parsed_ir`, immediately after
the `func` is located (currently `src/ir_extract.jl:139–146`) and before the
existing return-type derivation block (`src/ir_extract.jl:152–160`). It must
happen before parameter naming because we need to skip the sret parameter when
building `args`, and it must happen before block conversion because we need to
know the sret pointer's SSA name to recognise stores into it.

### How

A new helper `_detect_sret(func)` returns either `nothing` (no sret present) or a
`SretInfo` named-tuple shaped:

```
SretInfo:
  param_index    :: Int                 # 1-based position in LLVM.parameters(func)
  param_ref      :: LLVM.API.LLVMValueRef  # for fast identity tests in store walks
  agg_type       :: LLVM.ArrayType      # the [N x iM] from the sret() attribute
  n_elems        :: Int                 # LLVM.length(agg_type)
  elem_width     :: Int                 # LLVM.width(LLVM.eltype(agg_type)) — must be integer
  elem_byte_size :: Int                 # ceil(elem_width / 8) — for GEP offset → index
  agg_byte_size  :: Int                 # n_elems * elem_byte_size
```

Implementation uses the C API exactly as the brief specifies:

```
kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
```

This kind ID is queried lazily inside the helper (LLVM.jl makes no guarantees
about kind-ID stability across module contexts; resolving it once per call is
cheap and avoids module-state leakage). For each parameter `p` at index `i`
(1-based, mirroring `LLVM.parameter_attributes`):

```
attr = LLVM.API.LLVMGetEnumAttributeAtIndex(func, UInt32(i), kind_sret)
attr == C_NULL && continue
ty = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(attr))
```

Constraints (each is a hard `error()`, never silent):

- `ty isa LLVM.ArrayType` — sret pointee must be `[N x iM]`. Reject struct-typed
  sret with `error("sret pointee is $ty; only [N x iM] aggregates are supported (Bennett-dv1z scope)")`.
- `LLVM.eltype(ty) isa LLVM.IntegerType` — element must be a primitive integer.
- `LLVM.width(LLVM.eltype(ty)) ∈ {8, 16, 32, 64}` — match the existing scalar
  width policy. Reject i1/i4/iN-arbitrary with a precise error citing the type.
- `LLVM.value_type(p) isa LLVM.PointerType` — sret param must be a pointer
  (LangRef requirement, but worth asserting to fail loud on malformed IR).

Only one sret parameter is allowed. If two parameters have the attribute, that
is an LLVM bug, not a Julia ABI we should silently accept — `error` immediately.

### Functions without sret (no regression)

If the loop completes without finding `sret`, `_detect_sret` returns `nothing`
and the rest of `_module_to_parsed_ir` proceeds unchanged. The existing
`ret_width` / `ret_elem_widths` derivation at lines 152–160 runs as today, the
parameter-naming loop at 169–191 sees the same parameters in the same order,
and `_convert_instruction` for `LLVMRet` at lines 450–453 reads from `ops[1]`
exactly as before (because `ret` for non-void will have an operand). Any module
where Julia chose by-value return — including all current n=1 and n=2 tests —
is bitwise-unaffected. The gate-count baselines for `swap_pair`,
`complex_mul_real`, `dot_product`, `test_increment`, etc. are guaranteed by
construction.

## 2. ret_elem_widths / ret_width derivation

When `_detect_sret` returns `SretInfo`, override the existing block at lines
152–160:

```
if sret_info !== nothing
    rt = sret_info.agg_type           # synthetic — for downstream consumers that
                                      # might inspect; we never call _type_width(LLVM.VoidType)
    ret_width = sret_info.n_elems * sret_info.elem_width
    ret_elem_widths = [sret_info.elem_width for _ in 1:sret_info.n_elems]
else
    # existing logic at 152–160 unchanged
    ft = LLVM.function_type(func)
    rt = LLVM.return_type(ft)
    ret_width = _type_width(rt)
    ret_elem_widths = if rt isa LLVM.ArrayType
        [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
    else
        [ret_width]
    end
end
```

The constructed `ret_elem_widths` is identical in shape to what the n=2 by-value
case produces today, which is exactly what the simulator's `_read_output` (lines
42–55 of `src/simulator.jl`) reads to split the output bit vector into a tuple.
No simulator change is needed.

`_type_width` (`src/ir_extract.jl:1062–1076`) does not need to learn about
`VoidType`, because we never call it on the void return type — the sret path
short-circuits before the existing call. This is a deliberate choice: putting
"`tp isa LLVM.VoidType` → 0" in `_type_width` would silently swallow any other
unintended void return (e.g., a future bug where we route a real void function
through the integer pipeline). Failing loud on `VoidType` is the right default.

## 3. Args list handling

The sret parameter is not a function input; it is a calling-convention artefact
for shipping the return value back to the caller. It must NOT appear in
`parsed.args`. Concretely, in the parameter-naming loop at lines 169–191, the
sret parameter is named (so we can recognise it as the base of stores below)
but is excluded from the `push!(args, ...)` calls.

The cleanest split is at line 178–190, where the type dispatch for `IntegerType
/ FloatingPointType / PointerType` decides what to push into `args`. Add an
early skip:

```
for (i, p) in enumerate(LLVM.parameters(func))
    nm = LLVM.name(p)
    sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
    names[p.ref] = sym

    # sret param: name it (so store-target tracking works) but DON'T add to args
    if sret_info !== nothing && i == sret_info.param_index
        sret_root_sym = sym         # remember for later
        continue
    end

    ptype = LLVM.value_type(p)
    if ptype isa LLVM.IntegerType
        push!(args, (sym, LLVM.width(ptype)))
    elseif ...  # existing branches, unchanged
    end
end
```

`sret_root_sym` is captured into the `_module_to_parsed_ir` local scope and
threaded into the helper that does the store walk (section 4).

The parameter-index threading uses `enumerate(...)` which is a single-token
change. The sret detection used 1-based `param_index` for symmetry with
`LLVM.parameter_attributes`'s indexing convention; if the C API uses something
different (e.g. attribute index 0 means return-position, ≥1 means parameters)
we adjust in `_detect_sret`, not here.

### Why this is the right place

The args list is consumed at three places:

1. `LoweringResult.input_widths` (`src/lower.jl:403`), which the simulator uses
   to bind tuple inputs to wires (`_simulate`, `src/simulator.jl:18–24`).
2. `lower_call!` for inlining (`src/lower.jl:1614`), where it indexes
   `callee_parsed.args` to map caller arguments into callee input slots.
3. The wire-allocation loop that builds `input_wires` from `parsed.args`.

All three would break if we passed an opaque pointer through as a virtual input.
Skipping it at extraction time is the only correct option — there's no
post-extraction filter that could clean it up without subtly diverging from how
LLVM-style by-value-return functions look downstream.

## 4. Store tracking

The callee body writes the return value either directly to the sret pointer
(offset 0 → element 0) or via a `getelementptr` with a constant offset off the
sret pointer (offset N → element N / elem_byte_size).

### What we collect

For each `LLVMStore` instruction whose pointer operand is either
`sret_root_sym` itself or a constant-offset GEP rooted at `sret_root_sym`, we
remember:

```
SretWrite:
  block_label    :: Symbol      # which IRBasicBlock
  inst_position  :: Int         # ordinal of this store within the block
                                # (later writes overwrite earlier ones — last-write-wins)
  elem_index     :: Int         # 0-based element index
  value_op       :: IROperand   # the SSA name (or constant) being stored
  store_inst     :: LLVM.Instruction  # for diagnostics
```

These are gathered during a pre-walk over `LLVM.blocks(func)` that runs
**after** the existing two-pass naming (lines 162–199) but **before** the
block-conversion loop at lines 201–224. The pre-walk is needed because the
block-conversion loop needs to know, for each block, whether the store at
position `k` is an sret write (in which case it must NOT be emitted as `IRStore`
into the block's instruction list — sret writes don't survive into the lowered
circuit; they're materialised at `ret void` time as an `IRInsertValue` chain).

A new helper, `_collect_sret_writes(func, names, sret_info)`, returns a
`Dict{Symbol, Vector{SretWrite}}` keyed by block label and a
`Set{LLVM.API.LLVMValueRef}` of "sret-write store instructions to suppress" so
the block-conversion loop can quickly check `inst.ref ∈ suppressed_refs`.

### How we map a store to an element index

Three patterns are supported under `optimize=true`:

**(a) Direct store to the sret root:** `store iM %v, ptr %sret_return`. Element
index is 0; element width must equal `sret_info.elem_width`.

**(b) GEP with byte offset, then store:** the canonical Julia/LLVM shape from
the brief, `%pK = getelementptr inbounds i8, ptr %sret_return, i64 K` followed
by `store iM %v, ptr %pK`. We classify the GEP via:

- The base operand is the sret pointer SSA (matched by `LLVMValueRef` identity
  against `sret_info.param_ref`).
- Exactly one index, which must be a `LLVM.ConstantInt`.
- Source element type (via `LLVM.API.LLVMGetGEPSourceElementType`) must be
  either an i8 (byte-offset GEP, common Julia shape) or `[N x iM]` (typed GEP).

For byte-offset GEPs, the offset is `convert(Int, idx_const)` and the element
index is `offset / sret_info.elem_byte_size`. The division must be exact; if it
is not, we have a misaligned write — `error("sret store at byte offset $offset
is not a multiple of element size $(sret_info.elem_byte_size); partial-element
writes are not supported")`.

For typed GEPs, the index is the constant directly, no divison.

The GEP itself is *not* emitted as `IRPtrOffset` — it's an internal computation
we flatten away. The pre-walk records the GEP-result SSA → element-index
mapping in a side-table so the subsequent store can be recognised. We then mark
**both** the GEP instruction and the store instruction in `suppressed_refs`, so
the block-conversion loop skips them.

**(c) GEP-of-GEP chains** (rare, but legal): we recurse — if the GEP base is
itself a sret-derived GEP, we accumulate the byte offsets. This pattern can
appear when the optimizer combines partial offsets. If at any level the GEP
becomes non-constant (variable index, or base is an arbitrary SSA pointer), we
`error` with the specific pattern in the message.

### Multi-block functions (conditional sret writes)

The pre-walk handles each block independently and stores writes per block. A
function with three blocks like:

```
top: store i32 %a, %sret_return
     %p1 = gep i8, %sret_return, 4
     store i32 %b, %p1
     br i1 %cond, label %if_then, label %if_else
if_then: %p2 = gep i8, %sret_return, 8
         store i32 %x, %p2
         br label %merge
if_else: %p2 = gep i8, %sret_return, 8
         store i32 %y, %p2
         br label %merge
merge:   ret void
```

is the realistic case: elements 0 and 1 are unconditionally written in `top`,
element 2 is conditionally written in `if_then` or `if_else`. The pre-walk
collects all four writes; the synthesis at `ret void` time (section 5) needs to
*select* the right value for element 2 based on which predecessor of `merge`
was taken.

We resolve this by leaning on the existing phi-resolution machinery rather than
reinventing it. At `ret void` synthesis time, for each element index `k` we ask:
"in how many *distinct* blocks is element `k` written?"

- **Exactly one block**: the value is unambiguous; reference `value_op`
  directly.
- **Two or more blocks**: synthesise a fresh `IRPhi` instruction that lives in
  the `ret`-block and merges the per-predecessor values. The IRPhi's `incoming`
  list is `(value_op, source_block)` pairs reflecting the multi-block
  collection. This is identical in shape to a real Julia phi, so the existing
  `resolve_phi_predicated!` in lower.jl handles it.

There is a subtlety here: if a block writes element `k` more than once (e.g.,
`store v1, %p; ...; store v2, %p`), only the *last* write is observable — that
is the standard memory-model semantics. The pre-walk handles this by keeping
a per-(block, element) entry that is *overwritten* when a later store appears,
preserving only the last write per block per element. `inst_position` is what
disambiguates "later" within a block.

If a path through the CFG reaches `ret void` without writing some element `k`,
the value of that element is undefined per LLVM rules
(`alloca`/`sret` memory starts as undef). For Bennett.jl this would produce a
non-deterministic circuit, so we `error("sret element $k is not written on all
paths to ret void; partial-coverage sret is not supported")`. The check is:
for every element `k`, every path-distinct predecessor of the `ret` block must
write `k` at least once.

The dominator/reachability check needed is small but non-trivial; for the MVP we
implement a conservative approximation:

- Compute the set of blocks that can reach the unique `ret void` block via
  forward CFG traversal (these are the "live" blocks).
- For each element `k`, require that at least one block in this set writes `k`.
- If exactly one block writes `k`, accept (it dominates `ret` along the only
  path that uses it).
- If multiple blocks write `k`, require that each of them is a predecessor of
  the `ret` block (direct predecessor only — phi-style merge). This is the
  only shape we synthesise an IRPhi for; deeper hoisting is left to LLVM's
  `mem2reg` / `sroa` passes (`DEFAULT_PREPROCESSING_PASSES` already runs them
  when `preprocess=true`).
- If none of the above hold, `error` with a precise message naming the element
  and the offending block topology.

For the SHA-256 use case all writes happen in a single block (the function is
straight-line aggregate construction at the end), so this conservative shape is
sufficient. Phi-merged conditionally-written elements unlock branching tuple
constructors like `f(x) = x > 0 ? (a, b, c) : (d, e, f)`.

### Why not emit IRStore + IRLoad?

A naive alternative is to lower sret stores as real `IRStore` instructions into
a synthetic alloca representing the return slot, then read it back at `ret`
time with `IRLoad`s. That would technically work, but it goes through
`lower_store!` → shadow-memory MUX (`src/lower.jl:1736+`), which costs O(N²W)
gates for N-element returns — totally wrong for what is conceptually wire
copying. Extract-time synthesis to `IRInsertValue` chains lowers to the
existing aggregate path that costs exactly N*W CNOTs (= the per-element wire
copies inside `lower_insertvalue!` at lines 1573–1579), matching the n=2
gate-count expectation.

## 5. IRRet synthesis at `ret void`

When the block-conversion loop encounters the unique `LLVMRet` instruction in a
function that has sret detected, it synthesises a sequence of instructions that,
together, behave exactly like the by-value insertvalue chain LLVM produces for
n=2 today.

### The synthesis

For an N-element sret aggregate, we emit:

```
%__sret_v0 = insertvalue [N x iM] zeroinitializer, iM <elem_0_op>, 0
%__sret_v1 = insertvalue [N x iM] %__sret_v0,    iM <elem_1_op>, 1
...
%__sret_vN-1 = insertvalue [N x iM] %__sret_vN-2, iM <elem_N-1_op>, N-1
ret [N x iM] %__sret_vN-1
```

In `IRInst` terms (per `src/ir_types.jl:45–52`):

```
IRInsertValue(__sret_v0,  IROperand(:const, :__zero_agg__, 0), elem_0_op, 0, M, N)
IRInsertValue(__sret_v1,  ssa(__sret_v0),                       elem_1_op, 1, M, N)
...
IRInsertValue(__sret_vN-1, ssa(__sret_vN-2),                    elem_N-1_op, N-1, M, N)
IRRet(ssa(__sret_vN-1), N*M)
```

Synthetic SSA names use `_auto_name(counter)` so they cannot collide with
user-visible names. The `:__zero_agg__` constant is exactly the sentinel
already used by `_operand` at line 1049 for `LLVM.ConstantAggregateZero`, so
`lower_insertvalue!` at line 1564 already handles it. Zero new code paths in
lower.jl.

### Where the synthesis lives

The block-conversion loop (lines 202–224) iterates blocks and calls
`_convert_instruction` per instruction, with terminators routed into the block's
`terminator` slot. We add a thin wrapper:

```
for inst in LLVM.instructions(bb)
    # Suppress sret-write stores and their constant-offset GEPs
    if sret_info !== nothing && inst.ref in suppressed_refs
        continue
    end

    # ret void with sret → synthesise the IRInsertValue chain + IRRet
    if sret_info !== nothing && LLVM.opcode(inst) == LLVM.API.LLVMRet &&
       length(LLVM.operands(inst)) == 0
        synth_insts, synth_ret = _synthesise_sret_return(
            sret_info, sret_writes, label, counter, names)
        append!(insts, synth_insts)
        terminator = synth_ret
        continue
    end

    ir_inst = _convert_instruction(inst, names, counter)
    # ... existing dispatch unchanged
end
```

`_synthesise_sret_return` does three things:

1. **Resolve per-element value operands.** For each `k ∈ 0:N-1`, look up
   `sret_writes` for "writes of element k visible at this ret block". If
   exactly one source block writes it, take that `value_op`. If multiple, emit
   an `IRPhi` (added to `synth_insts`) and reference its dest. The phi's
   `incoming` list must use the *original* block labels of the writers — these
   are the same labels that appear in `predecessors(ret_block)` from
   `LLVM.predecessors`, so they line up with what `resolve_phi_predicated!`
   expects.

2. **Emit the insertvalue chain.** N synthetic `IRInsertValue` instructions
   appended to `synth_insts`, chaining through `_auto_name(counter)`-generated
   aggregate SSAs.

3. **Emit the IRRet.** Single `IRRet(ssa(last_agg_name), N*M)`.

### Why insertvalue, not a flat IRRet over a Vector{IROperand}?

The temptation is to add a new `IRRet`-multi variant carrying a vector of
operands and skip the synthetic insertvalue. We resist this for two reasons:

- **Invariant #4**: any change to `IRRet` is a core type change, requires its
  own 3+1 process, and ripples into `_narrow_ir`, `_ssa_operands`, lower.jl,
  bennett.jl, and the simulator.
- **Symmetry with by-value**: the n=2 path already produces an insertvalue
  chain in real LLVM IR. Synthesising the same shape for sret means
  downstream tests (gate counts, constant folding, liveness analysis) cannot
  observe a difference — the lowered circuit is structurally identical to
  what an n=2 function with the same element values would produce.

### The optimize=false memcpy variant

When `optimize=false`, Julia builds:

```
%local = alloca [N x iM]
store ... ptr %local
%g1 = gep i8, %local, 4
store ... ptr %g1
...
call void @llvm.memcpy.p0.p0.i64(%sret_return, %local, K, false)
ret void
```

The pre-walk extends to recognise this pattern with two additions:

- **Alloca recognition.** If the function contains exactly one alloca whose
  pointee type is `[N x iM]` matching `sret_info.agg_type`, we treat that
  alloca's SSA name as a *secondary sret root*. Stores into either the alloca
  or constant-offset GEPs from it count as sret writes.
- **Memcpy recognition.** A call to `llvm.memcpy.p0.p0.iN` where source is the
  alloca, destination is the sret pointer, length is exactly
  `sret_info.agg_byte_size`, and `is_volatile=false` is suppressed (added to
  `suppressed_refs`); it carries no information beyond what the alloca stores
  already gave us.

If the alloca is multiple, or memcpy length disagrees with the aggregate size,
or memcpy is volatile/unaligned, or there is more than one memcpy, we **error**
with a precise message rather than guessing. CLAUDE.md invariant #1.

This memcpy support is included even though `optimize=true` is the default,
because tests under `optimize=false` are common (CLAUDE.md cites it explicitly
in invariant #5 as "predictable IR for testing"). It is also the form
`DEFAULT_PREPROCESSING_PASSES` (`sroa`, `mem2reg`) is *designed* to canonicalise
into the direct form — so an alternative valid implementation would be to
*require* `preprocess=true` for `optimize=false` sret. We reject this
alternative: it shifts complexity onto the user and is a footgun under the
"fail fast" principle (the user gets a confusing pass-pipeline error rather
than a clean "memcpy sret detected" message). See "Alternatives considered"
below.

## 6. Error boundaries

Every unsupported sret pattern is a hard `error()` with a precise message
naming the offending pattern. No silent fallback, no skip-and-continue.

### Errors raised

| Condition | Message |
|---|---|
| sret pointee is not `[N x iM]` (e.g. struct type) | `"sret pointee is $ty; only [N x iM] aggregates are supported (Bennett-dv1z scope)"` |
| Element width is not in {8, 16, 32, 64} | `"sret element width $w is not in {8,16,32,64}; got $ty"` |
| Two or more parameters carry sret | `"function has multiple sret parameters at indices $idxs; expected exactly one"` |
| sret param type is not pointer | `"sret parameter at index $i has non-pointer type $ptype; LLVM IR is malformed"` |
| Store to sret with width != elem_width | `"sret store at byte offset $offset stores $sw-bit value, but element width is $(elem_width); width-mismatch sret writes are not supported"` |
| Store at non-multiple-of-elem byte offset | `"sret store at byte offset $offset is not a multiple of element size $(elem_byte_size); partial-element writes are not supported"` |
| GEP with non-constant index off sret pointer | `"sret pointer is indexed dynamically by SSA value %$sym; only constant-offset stores are supported"` |
| GEP with byte offset >= aggregate size | `"sret store at byte offset $offset is past end of aggregate (size $agg_byte_size)"` |
| Element `k` not written on any path | `"sret element $k is never written on any path to ret void"` |
| Element `k` written by non-predecessor block (deep hoisting) | `"sret element $k is written in block $blk which does not directly precede the ret block; lift via mem2reg/sroa or set preprocess=true"` |
| Memcpy length != aggregate size | `"sret memcpy length $len does not match aggregate size $agg_byte_size"` |
| Multiple allocas of sret type | `"function has $n allocas of sret type [$N x i$M]; expected exactly one in optimize=false sret form"` |
| Volatile or non-zero-aligned memcpy into sret | `"sret memcpy is volatile or unaligned; this is not a recognised Julia sret pattern"` |
| Multiple `ret void` instructions | `"function has $n ret instructions; sret support requires exactly one ret void"` |
| Sret pointer escapes (passed to a call, stored, bitcast to non-trivial type) | `"sret pointer escapes via $instkind; only direct stores and constant-offset GEPs are supported"` |

### Why these are errors, not warnings

The Bennett.jl pipeline's correctness invariant is "all ancillae return to
zero, and the output equals the function on every input." Silently dropping a
write or accepting a partial-coverage sret means the produced circuit is wrong
*on certain inputs*. Tests would intermittently pass under `verify_reversibility`
(which doesn't check correctness, only ancilla zeroing) and fail in benchmarks
in ways that look like compiler bugs much later. Failing at extraction time
with a precise message keeps the bug-hunting cost local.

## Test plan

A new file `test/test_sret.jl` is added, registered in `test/runtests.jl`. The
file exercises the sret path at multiple widths and shapes. Each test calls
`reversible_compile`, `simulate`, `verify_reversibility`, and asserts the
output tuple element-wise against the Julia function on representative inputs.

### Tests added

```
@testset "sret aggregate returns" begin

    @testset "n=3 i8 (smallest sret)" begin
        f3(a::Int8, b::Int8, c::Int8) = (a + Int8(1), b * Int8(2), c ⊻ Int8(0x55))
        circuit = reversible_compile(f3, Int8, Int8, Int8)
        for a in Int8(0):Int8(15), b in Int8(0):Int8(15), c in Int8(0):Int8(15)
            @test simulate(circuit, (a, b, c)) == f3(a, b, c)
        end
        @test verify_reversibility(circuit)
    end

    @testset "n=3 UInt32 (the SHA-256 unblock case)" begin
        f3u32(a::UInt32, b::UInt32, c::UInt32) = (a + UInt32(1), b * UInt32(3), c ⊻ UInt32(0xDEADBEEF))
        circuit = reversible_compile(f3u32, UInt32, UInt32, UInt32)
        # Spot-check (full sweep is 2^96, infeasible)
        for (a, b, c) in [(UInt32(0), UInt32(0), UInt32(0)),
                          (UInt32(1), UInt32(2), UInt32(3)),
                          (typemax(UInt32), typemax(UInt32), typemax(UInt32)),
                          (UInt32(0x12345678), UInt32(0xCAFEBABE), UInt32(0))]
            @test simulate(circuit, (a, b, c)) == f3u32(a, b, c)
        end
        @test verify_reversibility(circuit)
    end

    @testset "n=4 UInt32" begin
        f4u32(a::UInt32, b::UInt32, c::UInt32, d::UInt32) =
            (a, b, c, d)  # pure swizzle, exercises pure store/synthesis
        # ... ditto sweep
    end

    @testset "n=5 UInt32 (asymmetric)" begin
        # Five-element return — important because it crosses into a width
        # that no by-value path ever handled (existing tests stop at n=2).
    end

    @testset "n=8 UInt32 (full SHA-256 hash output)" begin
        f8u32(a::UInt32, b::UInt32, c::UInt32, d::UInt32,
              e::UInt32, f::UInt32, g::UInt32, h::UInt32) =
            (a + e, b + f, c + g, d + h, a ⊻ b, c ⊻ d, e ⊻ f, g ⊻ h)
        # Spot-check; this is the SHA-256 round-state shape.
    end

    @testset "n=16 UInt32 (over-spec stress)" begin
        # Verify the algorithm scales without quadratic blowup. Just check
        # a handful of inputs and verify_reversibility.
    end

    @testset "Mixed widths (homogeneous aggregate)" begin
        # NB: Julia's tuple ABI tends to break homogeneous-element groups out
        # of mixed-width tuples. We test (i8, i8, i8) and (i32, i32, i32)
        # separately rather than (i8, i32, i64), because mixed-width sret
        # aggregates would be a *struct* type, which we explicitly reject.
        # Add a *negative* test: a function returning (Int8, Int32) must
        # produce a clean error message at compile time.
        @test_throws ErrorException reversible_compile(
            (a::Int8, b::Int32) -> (a, b), Int8, Int32)
    end

    @testset "Conditional return (multi-block sret)" begin
        cond_ret(a::UInt32, b::UInt32, c::UInt32, sw::UInt32) =
            sw == UInt32(0) ? (a, b, c) : (b, c, a)
        circuit = reversible_compile(cond_ret, UInt32, UInt32, UInt32, UInt32)
        for sw in [UInt32(0), UInt32(1)],
            (a, b, c) in [(UInt32(1), UInt32(2), UInt32(3)),
                          (UInt32(0), UInt32(0xFFFFFFFF), UInt32(0xCAFE))]
            @test simulate(circuit, (a, b, c, sw)) == cond_ret(a, b, c, sw)
        end
        @test verify_reversibility(circuit)
    end

    @testset "Optimize=false (memcpy sret)" begin
        f3(a::Int8, b::Int8, c::Int8) = (a + Int8(1), b * Int8(2), c ⊻ Int8(0x55))
        # Re-extract via the public path, this time forcing the memcpy form.
        # extract_parsed_ir(f3, Tuple{Int8, Int8, Int8}; optimize=false)
        # is the relevant call — but reversible_compile defaults to optimize=true;
        # we add a test that calls extract_parsed_ir directly and compiles
        # via lower() + bennett(), then verifies.
        parsed = extract_parsed_ir(f3, Tuple{Int8, Int8, Int8}; optimize=false)
        lr = lower(parsed)
        circuit = bennett(lr)
        for a in Int8(0):Int8(7), b in Int8(0):Int8(7), c in Int8(0):Int8(7)
            @test simulate(circuit, (a, b, c)) == f3(a, b, c)
        end
        @test verify_reversibility(circuit)
    end

    @testset "Gate-count baselines for sret" begin
        # Records new baselines so future regressions are caught (CLAUDE.md
        # invariant #6). The expected counts come from running once and
        # locking in the value:
        #
        #   f3 i8  : ?  gates  (3 inputs, 3 outputs of width 8)
        #   f3 u32 : ?  gates
        #   f8 u32 : ?  gates
        #
        # Concrete numbers added once we observe them; the test asserts
        # exact equality.
    end

    @testset "Error: unsupported sret patterns" begin
        # Each negative test asserts a precise error message via
        # @test_throws(ErrorException, ...) and a regex check on the message.
        # Patterns:
        #   - struct-typed sret (mix of widths)
        #   - sret pointer escaping into a call (constructed via @ccall in
        #     a test fixture)
        #   - element not written on all paths (synthetic IR if needed)
    end
end
```

### Existing tests must not regress

The full test suite is run via `julia --project -e 'using Pkg; Pkg.test()'`.
The specific tests whose gate counts are most diagnostic:

- `test/test_tuple.jl` — `swap_pair`, `complex_mul_real`, `dot_product`. These
  all use n=2 by-value returns, which are *not* affected by the sret path
  (detection returns `nothing`). Gate counts must be unchanged.
- `test/test_increment.jl` — i8 addition baseline = 86 gates (CLAUDE.md
  baseline #6). Single-output, no sret. Must be unchanged.
- All width tests (`test_int16/32/64.jl`) — same story. Unchanged.
- All soft-float tests (`test_softfloat.jl`, `test_float_circuit.jl`) — these
  return single i64 / i1 values, no sret. Unchanged.

Verification recipe before merging the implementation:

```
git diff main -- src/ir_extract.jl src/ir_types.jl src/lower.jl
# Should show changes ONLY in ir_extract.jl, NOT in the other two files.

julia --project -e 'using Pkg; Pkg.test()'
# All existing tests pass.

julia --project test/test_sret.jl
# All new tests pass.

# Spot-check that gate counts on existing tuple tests are exactly preserved:
julia --project test/test_tuple.jl 2>&1 | grep -E "Swap pair|Complex mul|Dot product"
# Compare against pre-change output line-by-line.
```

## Edge cases

### Single-block vs multi-block

- **Single-block (the SHA-256 case)**: all sret writes are in the unique block
  that contains `ret void`. `_synthesise_sret_return` resolves each element to
  exactly one source — no IRPhi needed. The synthesised `IRInsertValue` chain
  is appended to the block's instruction list, and the synthetic IRRet replaces
  the original `LLVMRet` as the block's terminator. Trivial.

- **Multi-block, all writes in immediate predecessors of the ret block**: each
  predecessor writes its share. The conservative coverage check passes because
  every element is written by at least one predecessor along every path.
  IRPhis are synthesised for elements with multiple writers. The phi is added
  to the *ret block's* instruction list (before the synthesised insertvalue
  chain), with `incoming = [(value_op, source_block) for source_block in
  predecessors_that_write_this_element]`. Existing `resolve_phi_predicated!`
  handles it.

- **Multi-block, deep hoisting** (writes in a non-predecessor block): rejected
  with a precise error pointing the user at `preprocess=true` to flatten the
  CFG.

### The n=2 by-value path

n=2 functions never trigger sret detection (Julia returns `[2 x i32]` by value).
The existing block at lines 152–160 runs unchanged, the IR walker emits real
`insertvalue` instructions from LLVM directly, and no synthetic instructions
are added. The n=2 path is fully orthogonal to the sret path; both can coexist.

### What if Julia switches a borderline case (n=2 with i64 elements) to sret?

Julia's ABI cutoff is "more than 16 bytes." n=2 i64 = 16 bytes is on the boundary
and could go either way depending on Julia version / ABI tuning. The detection
code is symmetric: it asks the LLVM IR what shape the function actually has
*right now*, and dispatches accordingly. There is no hardcoded n=3 threshold.
If a future Julia version routes n=2 i64 through sret, our path picks it up
silently (and the `swap_pair` / `complex_mul_real` test results would just go
through the synthesis path with no observable change — gate counts identical
because the lowered IR shape is identical).

### `_iwidth` on void operand

`_convert_instruction`'s ret branch (lines 450–453) does
`_iwidth(ops[1])`, which would crash on `void` if we let it run. We avoid this
entirely by intercepting `ret void` in the wrapper described in section 5,
*before* `_convert_instruction` is called. The existing branch is untouched
and continues to handle `ret iM %v` and `ret [N x iM] %agg` exactly as today.

### Suppression of intermediate GEPs and stores

When we suppress a constant-offset GEP (because it's an sret-write target), we
also need to ensure no other instruction in the function references it. In
practice `optimize=true` produces a one-use chain (gep → store) and the gep
result is otherwise dead, so suppressing it is safe. We assert this:
`_collect_sret_writes` checks each suppressed GEP's use list (via
`LLVM.uses(gep)`) and confirms the only user is the suppressed store. If the
GEP is shared with anything else, we **don't** suppress it (we still mark the
store as the sret write, and the GEP itself becomes a real `IRPtrOffset` that
flows through the normal path; the store is suppressed but the GEP survives —
harmless, the resulting IRPtrOffset just produces a wire view that no one
reads).

This is a deliberate "loud about ambiguity, conservative about elision" stance.

### Aggregate return without explicit insertvalue (zeroinitializer return)

A function like `f() = (UInt32(0), UInt32(0), UInt32(0))` may compile to an
sret with stores of constants. Our path handles this trivially: each store's
value operand is a `LLVM.ConstantInt`, which `_operand` already converts to
`iconst(0)`. The synthesised insertvalue chain inserts `iconst(0)` for each
element, which lowers to … a NOTGate per set bit (none, in this case) and a
chain of CNOTs that copy zero. Clean.

### What if there's no `ret void`?

A function that always errors might compile to a body with `unreachable` and no
ret. The existing code (line 222) errors with `"Block $label has no
terminator"` for non-terminator-bearing blocks; this is a pre-existing failure
mode unaffected by sret. If the sret pre-walk finds a function with sret
attribute but no `ret void` instruction, we error with `"function has sret
parameter but no ret void; cannot synthesise return value"`.

## Alternatives considered

### Alternative: IR-rewriting pass that converts sret → by-value

**The idea.** Before the IR walker runs, run a custom LLVM pass that:
1. Strips the sret attribute from the parameter
2. Rewrites the function signature from `void (ptr sret, ...)` to `[N x iM] (...)`
3. Threads an alloca through the function and rewrites all sret stores to alloca
   stores
4. Replaces `ret void` with `ret [N x iM] %loaded_alloca`
5. Lets `mem2reg`/`sroa` clean up the alloca, leaving real `insertvalue` chains

**Why we considered it.** It shifts all the complexity into a single LLVM pass,
after which `_module_to_parsed_ir` sees only the n=2-style by-value form it
already handles. No extract-time synthesis, no per-block store tracking, no
synthetic IRPhi, no synthetic IRInsertValue — the existing code path runs end
to end with zero changes.

**Why we rejected it.** Three reasons:

1. **LLVM.jl pass authoring is a hill.** Rewriting a function signature in
   LLVM (changing its return type from void to `[N x iM]`) is not a
   pre-existing pass — it requires building a new function, copying the body,
   updating all instruction operand types, and updating the function's call
   sites (none in our case, but the API still requires the formality).
   LLVM.jl's New Pass Manager bindings (`_run_passes!` at line 85) accept
   string pipeline names; running custom IR-rewriting requires more LLVM.jl C
   API surface than we currently use, and it's not idempotent (running it
   twice on a sret-free module would crash). It would balloon the change
   beyond `ir_extract.jl`.

2. **Failure modes are opaque.** If the rewriter mis-handles a corner case
   (e.g., a multi-block sret with phi-merged element writes), the resulting
   "by-value" IR is malformed and the downstream walker explodes with an
   error pointing at the rewritten IR — not the original Julia function. The
   error-localisation cost is high for a future debugger. Extract-time
   synthesis errors point at the real LLVM IR (which the user can dump with
   `extract_ir(f, types)`), which is what they understand.

3. **Gate-count parity is implicit, not enforced.** The rewrite-pass approach
   relies on `mem2reg` + `sroa` collapsing the alloca exactly the same way
   they do for by-value n=2 returns. In practice this is true today, but we
   can't *prove* it without per-pattern verification, and any future LLVM
   version that handles the alloca slightly differently would silently change
   gate counts. The synthesis approach by contrast emits the *exact same
   IRInsertValue shape* the by-value path produces — so gate-count parity is
   compositional, not dependent on LLVM passes behaving a specific way.

The rewrite approach is faster to implement (zero changes to `ir_extract.jl`'s
walker logic) but harder to debug and less robust over time. We choose
synthesis.

### Alternative: extend `IRRet` to carry a vector of operands

Add `struct IRRetMulti <: IRInst; ops::Vector{IROperand}; widths::Vector{Int} end`
and emit it directly without the synthetic insertvalue chain. The lowering
would then iterate the operands and concatenate their wire arrays.

**Rejected** because it touches `ir_types.jl`, `_narrow_ir`, `_ssa_operands`,
and lower.jl — an explicit core-pipeline change requiring its own 3+1 process
(invariant #4). The synthetic insertvalue path achieves the same result in
ir_extract.jl alone and reuses code paths that already have full test
coverage.

### Alternative: require `preprocess=true` for sret functions

Make the user opt into the canonical IR shape via the existing `preprocess`
flag, which already runs `sroa`/`mem2reg` and would presumably normalise the
sret form into the canonical direct-store shape.

**Rejected** because (a) it doesn't actually canonicalise the function
*signature* — `sroa`/`mem2reg` work on body memory, not on calling conventions
— so the sret param survives and we still have to handle it; (b) it's a
footgun: forgetting to pass `preprocess=true` produces a confusing
"Unsupported LLVM type for width: void" error rather than a clean
"sret detected" path; (c) `optimize=false` is documented as the *predictable*
mode for testing in CLAUDE.md, and forcing it to require additional flags
breaks that contract.

## Integration risk

### Tests that could be affected

In principle: zero. The sret path is gated on a positive detection of the
attribute on a function parameter. Functions without sret are byte-for-byte
identical in their parsed IR.

In practice, the risk surface is:

1. **Parameter index threading.** If `LLVM.parameter_attributes`'s indexing
   doesn't match `LLVM.parameters`'s order in some edge case (e.g., variadic
   functions, swiftcc with extra implicit args), the sret param could be
   misidentified. Mitigation: identity-check via `param_ref` at usage sites,
   not just index. Tests: any function with multiple pointer parameters
   (e.g., `test_combined.jl` uses pgcstack + tuple-by-pointer args).

2. **`LLVM.uses` traversal cost.** The pre-walk asserts each suppressed GEP has
   only one user. For very large functions (SHA-256 round = ~50 instructions,
   trivial; but future functions could be larger), use-list traversal is O(uses).
   Mitigation: cache the result; the pre-walk is run once per compilation, and
   sret functions are a tiny fraction of total instructions (≤ 2N for an
   N-element aggregate).

3. **Constant-folding interaction.** The synthetic insertvalue chain feeds
   `lower_insertvalue!`, which feeds `_fold_constants` (`src/lower.jl:418+`)
   if `fold_constants=true`. The synthetic CNOT-copies of zero from
   `:__zero_agg__` should constant-fold cleanly because the constant_wires
   set already contains the zero-aggregate wires. We verify by spot-checking
   that the n=3 i8 test produces no excess gates beyond the bare minimum.

### How to verify no regression

The minimal verification recipe:

```
# Before applying the implementation:
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tee before.log
julia --project test/test_tuple.jl 2>&1 | grep -E "[0-9]+$" > before_tuples.txt

# After applying:
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | tee after.log
julia --project test/test_tuple.jl 2>&1 | grep -E "[0-9]+$" > after_tuples.txt

diff before_tuples.txt after_tuples.txt   # MUST be empty
diff <(grep -E "Test Summary" before.log) \
     <(grep -E "Test Summary" after.log)  # MUST be empty for existing tests
```

For the BC.3 SHA-256 unblock specifically: the pre-existing `test_combined.jl`
test that uses a real SHA-256 round must continue to pass at its baseline
(17,712 gates per WORKLOG line 1716). Whether the *full* SHA-256 (8-output
hash) compiles to an additional milestone gate count is a BC.3 concern, not a
regression concern — but it's the proof of life that the sret path works end
to end.

## Implementation footprint

Total lines added to `src/ir_extract.jl`: estimated ~150-200, distributed:

- `_detect_sret`: ~30 lines
- `_collect_sret_writes`: ~70 lines (the meat — store walking, GEP unfolding,
  alloca recognition for the memcpy variant, suppression set construction)
- `_synthesise_sret_return`: ~50 lines (per-element value resolution, optional
  IRPhi synthesis, insertvalue chain emission, IRRet construction)
- Modifications to `_module_to_parsed_ir`: ~20 lines (call detection, override
  ret_width derivation, thread sret_info through parameter loop and
  block-conversion loop)

Zero lines changed in: `ir_types.jl`, `lower.jl`, `bennett.jl`, `gates.jl`,
`simulator.jl`, `Bennett.jl`.

## Summary

The design contains all sret support in `ir_extract.jl` by treating sret as a
calling-convention artefact to translate away at extraction time. The output
is byte-identical to what an n=2-style by-value return produces today, which
means zero regression risk on existing tests and full reuse of the existing
lowering paths for `IRInsertValue`, `IRPhi`, and `IRRet`.

The four sret variants (direct, memcpy, multi-block, phi-merged) are handled
explicitly, with hard errors for any pattern outside the supported set. The
test plan spans n=3, 4, 5, 8, 16; mixed widths (negative test); conditional
returns (multi-block); and `optimize=false` (memcpy variant). Gate-count
baselines are recorded for the new sret tests and locked in via
`@test gate_count(circuit) == N` style assertions.

The approach is designed to fail loud, fail fast, and never produce a wrong
circuit silently — the same invariants the project as a whole upholds.
