# Bennett-a70z scout report — Dict{Int64,Int64} smul.with.overflow elsize-8 wall

Reconnaissance only. Files referenced are absolute; IR excerpts in
`ir_excerpts.txt` (same dir), full dumps `rehash_i64_full.ll` / `rehash_i8_full.ll`.

## 1. Current prover (Bennett-lbot) — code + exact proof logic

**Mechanism** (stateless fuse, two ptr_cells-gated spots, both in
`/home/tobias/Projects/Bennett.jl/src/extract/instructions.jl`):

- **Spot 1 — CALL skip** (`instructions.jl:3131-3136`): a call to
  `llvm.{smul,umul,sadd,uadd}.with.overflow.*` under `ptr_cells` returns
  `nothing` — the `{iN,i1}` aggregate is never modelled; the call's ref may
  only be consumed by its two extractvalues (any other consumer fails loud at
  `_operand`, no dest binding).
- **Spot 2 — extractvalue fuse** (`instructions.jl:2843-2851` dispatch →
  `_fuse_overflow_extractvalue`, `instructions.jl:2509-2534`). Both fields are
  re-derived from the CALL's operands `[a, b, callee]`:
  - idx 0 (wrapped product/sum) → `IRBinOp(dest, :mul|:add, a, b, N)` — always OK.
  - idx 1 (overflow bit) → `iconst(0)` ONLY when provably no-overflow, else
    fail loud.

**The exact proof predicate** (`instructions.jl:2524-2533`):

```julia
    # idx == 1: overflow bit — iconst(0) ONLY when provably no-overflow.
    ca = a isa LLVM.ConstantInt ? _const_int_as_int(a) : nothing
    cb = b isa LLVM.ConstantInt ? _const_int_as_int(b) : nothing
    provably_zero = op === :mul ? (ca in (0, 1) || cb in (0, 1)) :   # x*0, x*1 never overflow
                                  (ca == 0 || cb == 0)               # x+0 never overflows
    provably_zero || _ir_error(inst,
        "overflow bit of $cn is not provably zero (operands $(string(a)), $(string(b))); " *
        "general overflow-bit computation is future work — a placeholder-0 would route away " *
        "from the throw the native code takes and is UNSOUND. (Bennett-lbot)")
    return IRBinOp(dest, :add, iconst(0), iconst(0), _iwidth(inst))   # bit = 0 (i1)
```

So: **MUL is admitted only for a constant operand in {0,1}** (explicitly NOT
-1: `smul(INT_MIN,-1)` overflows), **ADD only for constant 0**. Anything else
— including MUL by constant 8 — fails loud. The lbot close reason and
`worklog/093_2026-07-07_utzc_deadblock_pruner.md:166-215` confirm this was a
3+1 design; "exact overflow-bit computation (mul high-half / add carry) +
{s,u}sub.with.overflow" was explicitly filed as future work.

## 2. Reproduction — exact command + exact error

Command (matches the d1b/klgz invocation style,
`test/test_d1b_julia_set.jl:95`, `test/test_klgz_determinism_guard.jl:54`):

```bash
julia --project -e '
using Bennett
fdict64(a::Int64, b::Int64) = (d = Dict{Int64,Int64}(); d[a] = b; d[a])
Bennett.extract_parsed_ir_set_from_julia(fdict64, Tuple{Int64,Int64};
                                         ptr_cells=true, on_extract_error=:fail_loud)'
```

Exact error (2026-07-21, current main @ 13ce767a):

```
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`rehash!#aee9dcf9` (callable=rehash!, argtypes=Tuple{Dict{Int64, Int64}, Int64}) —
ir_extract.jl: extractvalue in @julia_rehash!_8807:%nonemptymem5:
  %136 = extractvalue { i64, i1 } %134, 1 — overflow bit of
llvm.smul.with.overflow.i64 is not provably zero (operands
  %value_phi = phi i64 [ 16, %L7 ], [ %13, %L8 ], i64 8); general overflow-bit
computation is future work — a placeholder-0 would route away from the throw
the native code takes and is UNSOUND. (Bennett-lbot). This is an accepted
closed-world wall ...; pass on_extract_error=:skip to tolerate it (CW-D2 runway).
```

Under `on_extract_error=:skip`, ONLY `rehash!` fails; the other three bodies
(`fdict64` root, `setindex!`, `ht_keyindex2_shorthash!`) extract fine at i64,
then the closed-world check fails loud on `rehash!` being absent from the set.
So this wall is the single i64-specific extraction blocker for this shape.

## 3. IR ground truth (elsize 8)

See `ir_excerpts.txt` for verbatim blocks. Summary:

- `rehash!` for Dict{Int64,Int64} has **6 smul sites**, all with operand
  pattern `smul(%value_phi, CONST)`: 2× CONST=1 (slots Memory{UInt8}) and
  **4× CONST=8** (keys/vals Memory{Int64}, on both the count==0 and count!=0
  paths). The dynamic operand is always operand 1 (`%value_phi`), the constant
  elsize is always operand 2.
- `%value_phi = phi i64 [16, %L7], [%13, %L8]` where `%13` is
  `1 << (64 - ctlz(newsz-1))` with shift-amount guards — i.e. 16 or a power
  of two up to 2^63, or 0. **Not statically bounded**: no sound static range
  proof "value_phi*8 fits in i64" exists in this IR.
- Each site is the Julia `memorynew` GenericMemory size check, a fixed 9-inst
  shape:
  ```llvm
  %134 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %value_phi, i64 8)
  %135 = extractvalue { i64, i1 } %134, 0
  %136 = extractvalue { i64, i1 } %134, 1
  %137 = icmp slt i64 %value_phi, 0
  %138 = or i1 %136, %137
  %139 = icmp slt i64 9223372036854775806, %135
  %140 = or i1 %138, %139
  %141 = xor i1 %140, true
  br i1 %141, label %pass7, label %fail6
  ```
  `fail6` = `call @jl_argument_error(...); unreachable`. On `pass7` the
  product `%135` is the nbytes arg of `jl_alloc_genericmemory_unchecked`.
- **The overflow bit's ONLY (transitive) consumer is the branch condition
  guarding the throw block.** The product additionally feeds the icmp and the
  alloc size.
- i8/i8 comparison: byte-for-byte the same 6-site topology, but all six
  constants are 1. The elsize constant is the ONLY difference.

## 4. Proof-obligation analysis (THE CRUX)

**Why elsize 1 works today:** `x*1 = x` and `x*0 = 0` are exact for every
i64 input — the overflow bit is a mathematical constant 0, so `iconst(0)` is
sound with zero circuit cost. No CFG or range reasoning involved.

**Why elsize 8 fails:** `smul(x, 8)` genuinely overflows for
`x > 2^60 - 1` (and `x < -2^60`), and `%value_phi` is not statically bounded
(§3). A constant-0 bit would be exact only under a range assumption the IR
does not license.

**Interaction with the utzc dead-block pruner — important subtlety:** the
pruner criterion (`_vec_vm_dead_blocks`,
`/home/tobias/Projects/Bennett.jl/src/extract/vector_vm_cfg.jl:12-22`) marks
**every `unreachable`-terminated block** dead — `fail6` IS in the dead set and
IS pruned (body dropped, replaced by the `:__unreachable__` halt-sink branch;
`module_walk.jl:429-447`). But utzc is a **keep-branch** pruner: the
predecessor's `br i1 %141, %pass7, %fail6` stays, so `%141 → %140 → %138 →
%136` are all live values **in the kept block** `%nonemptymem5`. That is why
the wall still fires despite the pruner: the bit is needed as a *value* to
evaluate the kept branch, not as a block. There is no dominating pre-check
before the smul — the smul IS the check (first ever use of value_phi's
magnitude). If the bit's value at runtime were 1, the correct behaviour is to
route to `fail6` = BVM `:__unreachable__` loud halt — which the existing
machinery already provides. So the ONLY missing piece is a sound value for
the bit; everything downstream (or-chain, xor, branch, pruned throw block)
already extracts today on the elsize-1 path.

**Candidate soundness arguments for elsize 8 (for the proposers):**

1. **Exact bit computation for a constant operand (recommended baseline).**
   For `smul(x, c)` with ConstantInt `c > 0`:
   `overflow ⟺ x > fld(typemax(IntN), c) || x < cld(typemin(IntN), c)`.
   Both bounds fold to constants at extraction time → 2 IRICmp + 1 IRBinOp(:or)
   (or, for power-of-two c=2^k, equivalently
   `ashr(product, k) != x` → 1 ashr + 1 icmp, reusing the already-emitted
   product). Exact, sound for ALL inputs, preserves throw routing.
   Sibling cases fall out for free: `umul(x,c)`: `x > udiv(typemax_u, c)`;
   `sadd(x,c)`: one icmp (`x > typemax - c` for c>0, `x < typemin - c` for
   c<0); `uadd(x,c)`: `x > typemax_u - c`. Negative c and c = -1
   (`smul(INT_MIN,-1)` overflow) handled by the same fld/cld formulas.
2. **Multi-inst emission is already supported.** `_convert_instruction` may
   return a `Vector` of IRInsts — `module_walk.jl:601-604` splices a Vector
   return into the block's inst list. So the fuse can emit a small scalar
   sequence (fresh dests via the `counter` Ref already threaded in). No new
   plumbing needed.
3. **Fully general (both operands dynamic) bit** = mul high-half / add carry —
   the lbot-filed future work. NOT needed for this wall (elsize is always a
   ConstantInt here), but a design may choose to scope it in for the
   two-dynamic case. Note the widening-mul cost in circuits.
4. **Rejected shortcut (per lbot ruling):** placeholder-0 for elsize 8. Would
   silently take `pass7` on a real runtime overflow — unsound, routes away
   from the throw native code takes. Any range-assumption variant ("dict
   sizes are small in the closed world") is a semantic weakening the project
   has consistently refused (Rule 1).
5. **Throw-guard-shape recognition** ("the bit only guards a branch whose
   fail arm is a pruned throw skeleton, so emit bit=0 and accept that overflow
   inputs mis-route") is the SAME unsoundness as (4) dressed up — the
   fail arm is live-reachable at runtime. If proposers go near this, the honest
   variant is: emit the exact bit (1) and rely on the existing
   `:__unreachable__` halt sink for the overflow case.

## 5. BVM-side consumer notes (read-only recon of ~/Projects/BennettVM.jl)

- The fuse emits ONLY ordinary scalar IRInsts (IRBinOp/IRICmp), so BVM never
  sees `{iN,i1}` — lbot close reason: "Bennett.jl-only, no BVM gap". An
  exact-bit design that emits more ordinary scalars keeps that property:
  **no BVM ingest change needed for the bit itself.**
- The product feeds `jl_alloc_genericmemory_unchecked` →
  `IntrinsicGenericMemoryAlloc(dest, nbytes_operand, type_tag)`
  (`BennettVM.jl/src/ir/ingest_call.jl:65-81`, `src/ir/intrinsics.jl:222-238`):
  `nbytes_operand` is documented as "DATA byte size = nelems×elsize (the
  lbot-fused smul product)". The VM is **byte-granular and elsize-agnostic**;
  `src/ir/intrinsics_genericmemory.jl:64-67` explicitly documents wide
  elements: "element i lives at byte-cell data-ptr + i·elsize, ONE cell
  holding the full value — self-consistent for whole-element loads/stores;
  PARTIAL-overlap access remains the VM-wide sub-cell limitation". So
  admitting elsize 8 changes nothing structurally on the BVM side.
- Known still-unmodeled on BVM side (their own fail-louds): GenericMemory
  GROW/copy (`jl_genericmemory_copy*`) and boxed elements.

## 6. Test landscape + open questions / risks

**Existing pins** (`/home/tobias/Projects/Bennett.jl/test/test_lbot_overflow_intrinsic.jl`, 30 asserts, both modes):
- GATE (a): `.ll` fixtures `smul/umul/sadd/uadd(%x, {0,1})` fuse green
  (product IRBinOp + bit=0; no call/extractvalue survive).
- GATE (b): `LBOT_TWO_VAR` (`smul(%x,%y)`, both dynamic) and `LBOT_ADD5`
  (`sadd(%x,5)`) pinned to FAIL LOUD with "not provably zero" +
  "Bennett-lbot" (lines 169-181). **Tripwire:** an exact-bit-for-constant
  design flips `LBOT_ADD5` green (honest update needed, lbot/u2kk pattern);
  a fully general design also flips `LBOT_TWO_VAR`.
- GATE (c): ptr_cells=false byte-identity (fixture still walls pre-lbot-style).
- GATE (d): fdict_d1b (Int8) set advances past the smul wall.
- Other frontier tripwires that pinned smul historically: `test_utzc_dead_block_pruner.jl`,
  `test_yd4f_undef_phi_cells.jl`, `test_qmv7_gc_loaded_memcpy.jl` — check
  whether any pins the i64 wall text.

**Open questions / risks for designers:**
1. **Next wall inside rehash! is UNKNOWN.** Only the first extraction error is
   visible; once the elsize-8 sites fuse, rehash! may hit a further wall
   (:skip probing shows the OTHER three bodies extract at i64, but walls
   *later in rehash! itself* are hidden behind this one). Per
   `worklog/094:49-57` the known post-extraction issue is a RUN-time VM
   failure on Dict GROWTH (14 inserts → rehash-grow copy loop, `KeyError:
   :__v96`) — separate bead territory; two-key no-grow fdict2 works e2e at Int8.
2. i1 result width: the fused bit inst must carry width 1 (`_iwidth(inst)`),
   and intermediate icmps are i1 — fine for IRICmp, but an `:or` IRBinOp at
   width 1 should be checked against lowering expectations (BVM ingest of
   width-1 IRBinOp:or).
3. The or-chain also contains `icmp slt i64 9223372036854775806, %135` — the
   product-vs-typemax-1 check extracts as an ordinary IRICmp already; no work
   needed, but designs should not double-handle it.
4. Six fuse sites per rehash! → the design must be stateless per-extractvalue
   (like lbot), not per-function.
5. Constants: `_const_int_as_int` already decodes the ConstantInt; signedness
   of the decode for large unsigned constants (umul bounds) needs care.
6. Determinism: fresh SSA dests for the emitted sequence must come from the
   threaded `counter` Ref (klgz determinism guard covers name drift).
