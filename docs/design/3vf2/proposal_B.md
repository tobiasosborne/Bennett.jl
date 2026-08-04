# Bennett-3vf2 — Design Proposal **B**

**`@jl_diverror_exception` load in the `_growend!` closure body under `ptr_cells`**

Proposer B. Design doc only — no `src/` or `test/` edits were made.
Repo `/home/tobiasosborne/Projects/Bennett.jl`, branch `main`, HEAD `51c81cd`.
All line numbers below are at that HEAD.

---

## 0. TL;DR

**Chosen mechanism: neither (i) name whitelist nor (ii) throw-callee use-shape —
a third option, `(ii′) dead-use drop`:**

> Under `ptr_cells`, a non-volatile / non-atomic `load ptr, ptr @GlobalVariable`
> whose result has **at least one use and every use inside a block already in the
> Bennett-utzc `dead_blocks` set** is DROPPED (no `IRInst`, name deleted from
> `names`). Any other unrecognised global load still hits the existing
> `bennettvm-416r.13` fail-loud, now with the offending live-use block named.

The reason this beats both briefed options is not aesthetic. It is that its
soundness is a **theorem about the pruner that already runs three lines earlier**
(§4), rather than a claim about Julia's naming conventions (i) or about a callee
allowlist (ii). It also does not need a name set at all, so it has **no
Julia-version drift surface** for exception-global names.

Two of the parent brief's stated ground-truth facts turned out to be **wrong**,
and both errors cut against option (ii):

1. The load's only use is **NOT** `ijl_throw`. It is an `addrspacecast ptr →
   ptr addrspace(12)`, which *then* feeds `ijl_throw` (§2.3). A classifier
   keyed on "uses are calls to throw-family callees" **matches zero of the four
   sites** and would have to grow a transitive cast walk.
2. The exception globals are **not the only unrecognised global kind already
   present in this very function**. `@jl_sym#convert#463` (a Julia `Symbol`
   global) is also there, matching neither existing arm; it is invisible today
   only because codegen happened to leave its load *inside* a dead block
   (§2.4). A `jl_*_exception` name whitelist does not cover it.

Blast radius: **~30 LOC**, one new kwarg threaded through one call site.
BennettVM: **zero changes** (confirmed §7). Gate-count baselines: **untouched,
39/39 verified green at HEAD** (§6).

---

## 1. What I verified independently (Rule 10)

Every claim in §2 comes from a probe I ran myself in this session. Scratch
files are under
`/tmp/claude-1000/-home-tobiasosborne-Projects-Bennett-jl/8eb2701c-6e3c-48d0-ae52-c7a5f1cc6df3/scratchpad/`
with the `d3B_` prefix. Julia was run strictly one process at a time
(`pgrep -a julia` clean before starting).

---

## 2. Probe transcripts

### 2.1 The wall reproduces, and the `ptr_cells=false` path walls *elsewhere*

`d3B_probe1.jl` — `extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64})`,
where `_push40ys(n) = (v = Int64[]; push!(v, n); @inbounds v[1])`:

```
======================================================================
P1: ptr_cells=true wall
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`#_growend!##0#a7027856` (callable=Tuple{Base.var"#_growend!##0#_growend!##1"{...}},
argtypes=Tuple{}) — ir_extract.jl: load in @julia_#_growend!##0_1141:%L13:
  %jl_diverror_exception = load ptr, ptr @jl_diverror_exception, align 8
— load of an UNRECOGNIZED Julia JIT global `@"jl_diverror_exception"` ...
======================================================================
P2: ptr_cells=false wall
julia_set.jl: ... FAILED for callee `throw_boundserror#4d501e80` ...
— ir_extract.jl: VoidType reached _type_width ... (Bennett-dq8l / U81).
```

**Reading.** At `ptr_cells=false` the set does not even reach the `_growend!`
closure — it dies first on an unrelated `throw_boundserror` / U81 void-width
wall. The 416r.13 reject is *structurally* `ptr_cells`-only (it sits inside
`if ptr_cells && ...` at `instructions.jl:3829`). This settles §6's gating
question before any design choice is made.

### 2.2 The guard is structurally dead, exactly as briefed

`d3B_growend.ll` (dumped via `_code_llvm_by_sig`), block `%L13`:

```llvm
L13:                                              ; preds = %L9
  ...
  %20 = mul i64 5, %.unbox6
  %21 = icmp ne i64 %20, -9223372036854775808
  %22 = or i1 true, %21                          ; <-- literally `or i1 true, X`
  %divisor_valid = and i1 true, %22
  %jl_diverror_exception = load ptr, ptr @jl_diverror_exception, align 8, ...,
                            !invariant.load !0, !nonnull !0
  br i1 %divisor_valid, label %pass, label %fail
```

Four such sites (`%L13`, `%L20`, `%L25`, `%pass58`); the divisors are the
literals 4 and 8 in the growth-factor computation. `%divisor_valid` is
`and i1 true, (or i1 true, X)` — constant `true` by inspection. Julia bakes
this for literal divisors; the `fail` arm is unreachable by construction.

### 2.3 **CORRECTION**: the only use is an `addrspacecast`, not `ijl_throw`

`d3B_probe2.jl`, use-walk over `LLVM.uses` at each load:

```
GLOBAL @jl_diverror_exception  |  @jl_diverror_exception = external constant ptr
   initializer === nothing : true
   isconstant: true  linkage: LLVMExternalLinkage
======================================================================
[julia_#_growend!##0_455] load @jl_diverror_exception in block %L13  (parent dead? false)
    use: opc=LLVMAddrSpaceCast callee= in %fail dead=true isphi=false
    total uses = 1
[...] load ... in block %L20   -> use: LLVMAddrSpaceCast in %fail10  dead=true, uses=1
[...] load ... in block %L25   -> use: LLVMAddrSpaceCast in %fail57  dead=true, uses=1
[...] load ... in block %pass58-> use: LLVMAddrSpaceCast in %fail62  dead=true, uses=1
  [julia_#_growend!##0_455] dead blocks = 15 / 50
```

and the target block:

```llvm
fail:                                             ; preds = %L13
  %95 = addrspacecast ptr %jl_diverror_exception to ptr addrspace(12)
  call void @ijl_throw(ptr addrspace(12) %95)
  unreachable
```

**This is the fact that decides the design.** Option (ii) as briefed —
"only uses are calls to throw-family callees" — has a hit rate of **0/4**.
To work it would need a transitive walk through address-space casts (and,
for other Julia idioms, through `bitcast` / `getelementptr` / `inttoptr`),
i.e. a small alias-following analysis. Every extra hop is another place a
loose classifier can wrongly admit. The *block*-based criterion needs no hops.

### 2.4 The unrecognised-global population is bigger than the exception set

`d3B_probe3.jl`, every `load` whose pointer operand is a `GlobalVariable`, in
the real `_growend!` body, with utzc's own `_vec_vm_dead_blocks` as the oracle:

```
entry fn = julia_#_growend!##0_455
dead blocks = 15

--- utzc guards on every dead block ---
  %L71 preds=1 escape=OK skeleton=OK      %fail       preds=1 escape=OK skeleton=OK
  %L90 preds=1 escape=OK skeleton=OK      %fail10     preds=1 escape=OK skeleton=OK
  %L96 preds=2 escape=OK skeleton=OK      %fail57     preds=1 escape=OK skeleton=OK
  %after_throw   preds=0 escape=OK skeleton=OK   %fail62 preds=1 escape=OK skeleton=OK
  %after_noret   preds=0 escape=OK skeleton=OK   %fail68 preds=1 escape=OK skeleton=OK
  %after_throw20 preds=0 escape=OK skeleton=OK   %oob    preds=1 escape=OK skeleton=OK
  %after_noret21 preds=0 escape=OK skeleton=OK   %oob44  preds=1 escape=OK skeleton=OK
  %after_noret52 preds=0 escape=OK skeleton=OK

--- ALL GlobalVariable loads (any type) in f ---
  @jl_diverror_exception        rt=ptr defblk=%L13         nuses=1 all_uses_dead=true
  @jl_diverror_exception        rt=ptr defblk=%L20         nuses=1 all_uses_dead=true
  @jl_diverror_exception        rt=ptr defblk=%L25         nuses=1 all_uses_dead=true
  @jl_sym#convert#463           rt=ptr defblk=%L71         nuses=1 all_uses_dead=true
  @jl_global#461                rt=ptr defblk=%L90         nuses=1 all_uses_dead=true
  @+Core.ConcurrencyViolationError#460 rt=ptr defblk=%L90  nuses=1 all_uses_dead=true
  @jl_global#459                rt=ptr defblk=%L96         nuses=1 all_uses_dead=true
  @+Core.ConcurrencyViolationError#460 rt=ptr defblk=%L96  nuses=1 all_uses_dead=true
  @+Core.GenericMemoryRef#457   rt=ptr defblk=%oob         nuses=1 all_uses_dead=true
  @+Core.GenericMemoryRef#457   rt=ptr defblk=%oob44       nuses=1 all_uses_dead=true
  @jl_diverror_exception        rt=ptr defblk=%pass58      nuses=1 all_uses_dead=true
  @jl_global#464                rt=ptr defblk=%emptymem    nuses=1 all_uses_dead=false
  @+Core.GenericMemory#465      rt=ptr defblk=%nonemptymem nuses=1 all_uses_dead=false
```

Four independent readings, all load-bearing:

1. **All 15 dead blocks pass both utzc guards** (`_assert_dead_block_no_live_escape`,
   `_assert_dead_block_is_throw_skeleton`, called directly). Pruning is fully
   discharged for this function; the pruner will not itself become the next wall.
2. **Exactly the 4 diverror loads are (live-block def) ∧ (all uses dead)** — and
   they are the *only* loads reaching the generic reject. The criterion
   discriminates perfectly on the real corpus with zero tuning.
3. **The two genuinely-live global loads** (`@jl_global#464` in `%emptymem`,
   `@+Core.GenericMemory#465` in `%nonemptymem`) both have `all_uses_dead=false`
   and are both already handled by an *existing* recognised arm (singleton-data
   / type-tag). The new arm must not — and by construction cannot — reach them:
   it is placed *after* both existing arms return.
4. **`@jl_sym#convert#463` is a fourth global kind, already present, unrecognised.**
   It hides today only because its load sits in `%L71`, which is dead and whose
   body the pruner drops before conversion. Julia's codegen hoists these loads
   opportunistically — it already hoisted the diverror ones out of `%fail`.
   A `jl_*_exception` name whitelist is one codegen change away from walling on
   `@jl_sym#...`; the dead-use gate covers it now, for free, with no new names.

### 2.5 The forecast: memmove is next, confirmed by simulation

I cannot edit `src/`, so I simulated the post-fix state by rewriting the 4
loads to point at a *recognised* global (which the singleton arm drops in
exactly the same way — no `IRInst`, no downstream reference), then re-running
the real pipeline entry `_parsed_ir_from_ir_string(...; ptr_cells=true)`
(`d3B_probe5.jl`; the earlier `.ll` round-trip attempt in `d3B_probe4.jl` is
NOT equivalent — `raw=true` keeps addrspace-10 sret fields and dies on
Bennett-7wsz's own reject; use `raw=false` / `debuginfo=:none` as
`extract_parsed_ir_by_sig` does at `entry.jl:152`):

```
=== BASELINE via _parsed_ir_from_ir_string ===
ir_extract.jl: load in @julia_#_growend!##0_454:%L13: ... UNRECOGNIZED Julia JIT global ...

=== SIMULATED POST-FIX (next wall) ===
ir_extract.jl: call in @julia_#_growend!##0_454:%L79:
  call void @llvm.memmove.p0.p0.i64(ptr %memory_ref12.ptr_or_offset, ptr %.unbox52, i64 %46, i1 false)
  — llvm.memmove.p0.p0.i64: memmove is not yet lowered to reversible gates. ...
    Tracked in Bennett-8bys (Phase 3 ...). (Bennett-37mt Phase 1 — memmove deferred to Bennett-8bys)
```

The corrected forecast in the bead notes is right: **`llvm.memmove` is the next
wall, and it is Bennett-8bys/37mt, not 3vf2**. Live-block callee census from
`d3B_probe3.jl` for completeness:

```
julia.get_pgcstack, llvm.dbg.declare, julia.safepoint, llvm.ctlz.i64,
llvm.julia.gc_preserve_begin, llvm.memmove.p0.p0.i64, llvm.julia.gc_preserve_end,
julia.write_barrier, llvm.memcpy.p0.p0.i64, llvm.smul.with.overflow.i64,
jl_alloc_genericmemory_unchecked
```

Everything except `llvm.memmove` is either benign-dropped, explicitly handled
(`julia.write_barrier` at `instructions.jl:3262`, `llvm.smul.with.overflow` via
Bennett-lbot, `llvm.memcpy` via 37mt Phase 1), or extracts as an opaque
`IRCall` (`jl_alloc_genericmemory_unchecked`) — consistent with the bead's note.

### 2.6 Load hygiene: safe to drop

`d3B_probe7.jl`, on all four sites:

```
load in %L13   isvolatile=0 ordering=LLVMAtomicOrderingNotAtomic gv_isconstant=true gv_linkage=LLVMExternalLinkage
load in %L20   isvolatile=0 ordering=LLVMAtomicOrderingNotAtomic gv_isconstant=true gv_linkage=LLVMExternalLinkage
load in %L25   isvolatile=0 ordering=LLVMAtomicOrderingNotAtomic gv_isconstant=true gv_linkage=LLVMExternalLinkage
load in %pass57 isvolatile=0 ordering=LLVMAtomicOrderingNotAtomic gv_isconstant=true gv_linkage=LLVMExternalLinkage
successor-check: no unreachable-terminated block has any successors
```

Non-volatile, non-atomic ⇒ the load has **no observable effect**; dropping a
use-less non-volatile load is semantics-preserving in the LLVM sense, not just
in ours. (`LLVM.isvolatile` is not exported by LLVM.jl v#fEIbx — use
`LLVM.API.LLVMGetVolatile` / `LLVM.API.LLVMGetOrdering`. Noted for the
implementer; it cost me one probe iteration.)

### 2.7 Hand-written RED fixtures (the unit-test shape)

`d3B_fixA.ll` (benign shape) and `d3B_fixB.ll` (hazard: same load ALSO read in
the live `%pass` block via `ptrtoint`), through
`extract_parsed_ir_from_ll(...; entry_function=..., ptr_cells=...)`:

```
--- d3B_fixA.ll ptr_cells=true ---
  ERR: ... load in @f3vf2_a:%top: %exc = load ptr, ptr @jl_diverror_exception, align 8
       — load of an UNRECOGNIZED Julia JIT global ...
--- d3B_fixA.ll ptr_cells=false ---
  ERR: ... addrspacecast in @f3vf2_a:%fail: %c = addrspacecast ptr %exc to ptr addrspace(12)
       — unsupported LLVM opcode
--- d3B_fixB.ll ptr_cells=true ---
  ERR: ... load in @f3vf2_b:%top: ... UNRECOGNIZED Julia JIT global ...
```

Both fixtures are RED today with the 3vf2 message. Note the `ptr_cells=false`
row: with the pruner gated off, the dead block is walked normally and dies on
the `addrspacecast` — independent confirmation that this whole family of
behaviour lives behind the `ptr_cells` gate (§6).

---

## 3. The mechanism

Under `ptr_cells`, in the `load` arm of `_convert_instruction`, after the
type-tag arm and the singleton-data arm have both declined, and **before** the
`bennettvm-416r.13` fail-loud:

```
if the pointer operand is a GlobalVariable
   and the load is non-volatile and non-atomic
   and the load result has ≥ 1 use
   and EVERY use's parent basic block is in `dead_blocks`
then
   delete!(names, inst.ref)      # belt-and-braces (see §5)
   return nothing                # emit no IRInst
end
```

Otherwise fall through to the existing reject, with its message extended to
name the live-use block that disqualified the drop.

`dead_blocks` is the *same* `Set{_LLVMRef}` the pruner already computed at
`module_walk.jl:426`; it is threaded in as a new keyword argument. No new
analysis, no new name set, no new callee list.

Naming: I'd call the helper `_all_uses_in_dead_blocks(inst, dead_blocks)` and
site the doc-comment under the banner *"Bennett-3vf2 / CW-D: dead-use drop —
the dual of `_assert_dead_block_no_live_escape`"*.

---

## 4. Why it is sound — the one-paragraph theorem

> **Drop soundness.** Let `d` be an instruction in a live block, every use of
> which lies in a block `b ∈ dead_blocks`. The utzc pruner
> (`module_walk.jl:444-450`) replaces each such `b`'s body with `IRInst[]` and
> its terminator with `IRBranch(nothing, :__unreachable__, nothing)`. Therefore
> **no `IRInst` in the emitted `ParsedIR` references `d`**. Emitting no `IRInst`
> for `d` consequently cannot leave a dangling SSA operand. Since `d` is a
> non-volatile, non-atomic `load`, it has no observable effect either. ∎

This is the exact dual of the guard the pruner already asserts:

| direction | who owns it | verdict |
|---|---|---|
| value defined in **dead** block, used in **live** block | `_assert_dead_block_no_live_escape` (`module_walk.jl:89`) | **fail loud** — would dangle after pruning |
| value defined in **live** block, used only in **dead** blocks | **3vf2, this proposal** | **droppable** — nothing survives to reference it |
| value defined in **live** block, any use in a **live** block | existing 416r.13 reject | **fail loud** — genuinely unmodelled |

Together the three rules make value flow across the live/dead boundary total.
That completeness is the strongest argument for this design: it is not a patch
for one Julia global, it closes a *category* the pruner left half-specified.

**Corollary (no φ refinement needed).** A φ node's use is conceptually
attributed to its incoming edge, not to its own block — so a naive
"user's parent block" test could in principle mis-classify a φ in a live block
fed from a dead block. That configuration is **impossible here**: a block whose
terminator is `unreachable` has zero successors (verified empirically, §2.6),
hence is never anybody's predecessor, hence never supplies a φ incoming value.
A φ *user* in a live block is therefore always a genuine live use → fail loud;
a φ user in a dead block is a dead use. The plain parent-block test is exact.
This corollary must be written into the code comment — a future reader will
otherwise "fix" it into something wrong.

---

## 5. Exact insertion points

| # | file:line (HEAD `51c81cd`) | change |
|---|---|---|
| 1 | `src/extract/instructions.jl:2747-2775` | add kwarg `dead_blocks::Set{_LLVMRef}=Set{_LLVMRef}()` to `_convert_instruction`'s signature, documented alongside `ptr_cells` / `tag_ids` / `tag_ssa` as "threaded from `module_walk.jl`, the sole owner". Default-empty ⇒ every other caller inert. |
| 2 | `src/extract/instructions.jl:3814-3816` (between the `end` of the `_is_singleton_data_global_name` block at 3795-3798 and the `if haskey(names, ptr.ref)` block at 3801) — **or**, equivalently and more readably, immediately before the 416r.13 reject at `:3829` | the new arm. I prefer **before `:3829`**: it keeps the two "recognise this global by name" arms adjacent, and makes the arm read as a *carve-out from the reject it guards*, which is what it is. |
| 3 | `src/extract/instructions.jl:3871-3880` | extend the reject message: append `" This load's result IS used in the live block %<label>; only a load whose every use lies in a provably-dead (`unreachable`-terminated) block may be dropped (Bennett-3vf2)."` when `dead_blocks` is non-empty and the disqualifier is a live use. |
| 4 | `src/extract/module_walk.jl:577-583` | pass `dead_blocks=dead_blocks` at the single `_convert_instruction` call site that already forwards `ptr_cells`. |
| 5 | new helper, `src/extract/instructions.jl` near the arm (or `vector_vm_cfg.jl` next to `_vec_vm_dead_blocks:12` if you prefer co-location with its oracle) | `_all_uses_in_dead_blocks(inst, dead)::Bool` — `LLVM.uses` walk, `false` on zero uses, `false` on any non-`Instruction` user (a `ConstantExpr` user has no parent block ⇒ conservatively live ⇒ fail loud). |

**No other `_convert_instruction` call site changes.** The two others —
`heap.jl:2066` and `vector_vm_cfg.jl:137` — forward neither `ptr_cells` nor
the new kwarg, so both stay byte-identical.

### 5.1 Ordering: is `dead_blocks` available at conversion time?

Yes, verified by reading `_module_to_parsed_ir_on_func`:

* `module_walk.jl:311` — pass 1 names **all** instructions, in **all** blocks
  (dead ones included).
* `module_walk.jl:426` — `dead_blocks = ptr_cells ? _vec_vm_dead_blocks(func) : Set{_LLVMRef}()`.
* `module_walk.jl:428` — pass 2, the block-conversion loop begins.
* `module_walk.jl:444` — `if bb.ref in dead_blocks` → body dropped, `:__unreachable__` emitted.
* `module_walk.jl:577` — the `_convert_instruction` call, inside pass 2.

So `dead_blocks` is complete **before the first instruction is converted**.
There is no ordering hazard and no need to defer or two-phase anything. This
was worth checking: had `dead_blocks` been computed lazily per block, a load in
a live block preceding its dead consumer would have seen an incomplete set.

### 5.2 What does downstream `resolve!` see? Pure drop, no `.globals` entry.

The singleton-data arm (`:3795-3798`) *aliases* — `names[inst.ref] = Symbol(pname)`
— because a singleton is read as data by surviving instructions and must
collapse to one canonical `.globals` key. **Our case is the opposite**: nothing
survives that reads it, so there is nothing to alias *to*, and materialising a
`.globals` cell would ship a VM global that is defined, bound by `GLOBAL_BASE`,
and never read — dead weight in every downstream `ParsedIR`.

So: **pure drop, no `.globals` entry, no alias.** And go one step further —
`delete!(names, inst.ref)`. `_operand` fails loud on an unknown ref
(`helpers.jl:204-207`: *"unknown operand ref for: ... the producing instruction
was skipped or is not yet supported"*). Deleting therefore converts the
hypothetical "theorem is wrong / a use slipped through" case from a **silent
dangling operand that KeyErrors at VM run time** — precisely the failure mode
416r.13 was created to prevent — into a **loud extraction-time error**.
`dest = names[inst.ref]` is read at `instructions.jl:2776`, i.e. before our arm,
so deletion is safe. This is cheap and it is the difference between a design
that fails safe and one that merely fails.

---

## 6. `ptr_cells` gating verdict

**Gated — and gated three times over, which is the right amount.**

1. The arm sits inside the existing `if ptr_cells && ptr isa LLVM.GlobalVariable`
   region (`:3768` / `:3829`), so it is syntactically unreachable at
   `ptr_cells=false`.
2. `dead_blocks` is itself `ptr_cells`-gated at `module_walk.jl:426` — empty at
   `false` — so even if the arm were reached, `_all_uses_in_dead_blocks` would
   return `false` for every load and the arm would decline.
3. The kwarg's default is `Set{_LLVMRef}()`, so the two non-`module_walk`
   callers are unaffected.

**Where does the reject it replaces fire at `ptr_cells=false`?** *It doesn't* —
probed twice. (a) On the real corpus, `ptr_cells=false` walls earlier and
elsewhere (U81 `throw_boundserror`, §2.1). (b) On the isolated unit fixture,
`ptr_cells=false` walks the *un*pruned `%fail` block and dies on the
`addrspacecast` (§2.7). At `ptr_cells=false` the load itself already takes the
silent `return nothing  # non-integer load — skip` fall-through at
`instructions.jl:3882` — i.e. the circuit path has *always* dropped this load;
3vf2 only makes the closed-world path agree, under a proof the circuit path
never had.

**Gate-count baselines.** The circuit path is `ptr_cells=false` end to end, so
baselines cannot move. Verified green at HEAD before proposing:

```
$ julia --project --check-bounds=yes test/test_gate_count_regression.jl
Test Summary:                   | Pass  Total  Time
Gate count regression baselines |   39     39  8.1s
```

This must be re-run and re-shown as 39/39 in the implementer's commit message.

---

## 7. BennettVM

**Zero changes.** Confirmed by inspection of the sibling repo:
`BennettVM.jl/src/ir/unreachable_halt.jl` plus the `:__unreachable__` handling
at `src/ir/ingest.jl:327-343` (synthetic sink block injected so the branch
target never dangles), `src/history/Injective.jl:277` (L1-injective halt), and
`src/interpreter/Interpreter.jl:1861-1885` (`status === :error`, loud). Existing
coverage: `BennettVM.jl/test/test_utzc_unreachable_sink.jl`.

Nothing 3vf2 emits is new to BVM: the pruned diamond's shape (keep-branch +
`:__unreachable__` target) is byte-identical to what utzc already produces. The
*only* delta 3vf2 introduces is that one live-block instruction is no longer
emitted — which BVM cannot observe. See §8.5 for the cross-repo test call.

---

## 8. Failure modes

### 8.1 A future Julia reads bytes off the exception singleton in a live block

E.g. codegen that materialises a `catch e` handler inspecting the exception
object. Then some live instruction uses the load → `_all_uses_in_dead_blocks`
returns `false` → **existing 416r.13 reject fires**, now with the live-use block
named. Loud, at the load site, with the bead ids. This is the design's central
property and it holds by construction, not by vigilance.

Note this is exactly where a **bare name whitelist (option (i)) fails silently**:
it would recognise `@jl_diverror_exception` by name, drop the load, and leave a
dangling operand for the live reader. Option (i) *alone* is not safe here; the
brief's option (iii) exists precisely because of this, and (iii)'s assertion is
this proposal's *primary* mechanism — at which point (iii)'s whitelist half is
redundant. Occam applies.

### 8.2 A load with **zero** uses

`_all_uses_in_dead_blocks` returns `false` on an empty use list, so a zero-use
unrecognised global load still fails loud. Deliberate: a use-less load is not
evidence of a modelled construct, it is evidence that the walker's picture of
the function is incomplete, and 3vf2 should not be the thing that swallows it.
(Dropping it would be *semantically* harmless; refusing is the fail-fast choice
and costs nothing, since the case does not occur in the corpus.)

### 8.3 A `ConstantExpr` user (no parent block)

`LLVM.user(u)` need not be an `Instruction` — a `ConstantExpr` referencing the
load is impossible (constants can't reference instructions), but a defensive
`usr isa LLVM.Instruction || return false` costs one line and keeps the helper
total. Conservative direction = fail loud.

### 8.4 Volatile / atomic load of a mutable global

Excluded by the explicit `LLVMGetVolatile == 0` and
`LLVMGetOrdering == NotAtomic` conditions (§2.6 shows all four real sites
satisfy them). A volatile load is an observable event and must not be dropped
even if use-less; it falls through to the reject.

### 8.5 The pruner itself walls first

If some dead block fails `_assert_dead_block_is_throw_skeleton`, the pruner
errors before our arm helps. Probed: **all 15 dead blocks in `_growend!` pass
both guards today** (§2.4). Recorded so a future regression is attributable.

### 8.6 Interaction with the `sret` / `tag_ssa` bookkeeping

The dropped load is not an `sret` producer (it is a global read, not a store)
and is not a type-tag (`tag_ssa` is only populated by the `:3768` arm, which
declined). Deleting its `names` entry cannot orphan either structure. The
implementer should still run `test_7wsz_ptr_sret_fields.jl` and
`test_iwo9_typetag.jl` (§9.3) rather than take my word for it.

---

## 9. Test plan (RED-GREEN)

### 9.1 RED first — new file `test/test_3vf2_dead_use_global_load.jl`

Hand-written `.ll` fixtures, **decoupled from `_growend!` drift** (this is the
point: Julia will re-mangle and re-block `_growend!` every minor release; the
unit test must not care). Both are already written and confirmed RED (§2.7) —
the implementer can lift them verbatim from `d3B_fixA.ll` / `d3B_fixB.ll`.

* **(a) benign shape → GREEN after the fix.** `f3vf2_a`: live `%top` with
  `or i1 true, X` guard + `load ptr, ptr @jl_diverror_exception`;
  `%fail` = `addrspacecast` → `ijl_throw` → `unreachable`; `%pass` = `sdiv` →
  `ret`. Assert, at `ptr_cells=true`, the *values* (Rule 4): 3 blocks
  (`:top`, `:fail`, `:pass`); `%fail` has `0` insts and an
  `IRBranch(nothing, :__unreachable__, nothing)` terminator; `%top` contains
  **no** `IRLoad` and no instruction whose dest is the load's name; `%pass`
  carries the `sdiv`; `ParsedIR.globals` gained **no** key (pure drop, §5.2).
* **(b) hazard shape → stays RED forever.** `f3vf2_b`: identical, plus
  `%live = ptrtoint ptr %exc to i64` in the live `%pass`. Assert the extraction
  throws, and that the message contains `"UNRECOGNIZED Julia JIT global"`,
  `"jl_diverror_exception"`, `"Bennett-3vf2"` and the live block name `"pass"`.
  **This is the most important test in the file** — it pins the inverted-risk
  boundary the brief worried about.
* **(c) zero-use variant** (§8.2) → still rejects.
* **(d) volatile variant** (`load volatile ptr, ...`, uses all dead) → still
  rejects (§8.4).
* **(e) name-agnosticism** — repeat (a) with the global renamed
  `@jl_sym#convert#999` and again `@some_future_julia_global`. Both must go
  GREEN. This is the test that a name-whitelist implementation **cannot** pass,
  so it is also the design-choice regression: if someone later "simplifies" the
  arm into a whitelist, (e) goes red and says why.
* **(f) `ptr_cells=false` byte-identity** — assert fixture (a) at
  `ptr_cells=false` still throws the pre-existing `addrspacecast ... unsupported
  LLVM opcode` (§2.7), i.e. the default path is untouched.

### 9.2 Integration pin — advance `test_40ys_instanceless_callees.jl` (I)

Testset **(I)** at `test/test_40ys_instanceless_callees.jl:434-457` currently
accepts a disjunction including `"jl_diverror_exception"` /
`"UNRECOGNIZED Julia JIT global"` / `"bennettvm-416r.13"`. Per the file's own
convention (`:459-471`: *"when the named bead lands this goes RED — that is the
signal to advance the assertion to the next wall, NOT to delete it"*):

* **remove** the `jl_diverror_exception` / `UNRECOGNIZED` / `416r.13` disjuncts,
* **add** `occursin("memmove", e.msg)` / `occursin("Bennett-8bys", e.msg)` /
  `occursin("Bennett-37mt", e.msg)`,
* **keep** the U15 / Bennett-5oyt disjunct — the *root* `_push40ys` body still
  walls on the `movq %fs:0` pgcstack read, and which set member fails first is
  registration order, not a contract (the `test_lf14` landing convention),
* add a **negative** assertion `@test !occursin("jl_diverror_exception", e.msg)`
  so a regression cannot quietly re-open the wall.

Testset **(J)** (`:493`) carries a prose note *"the closure on
`@jl_diverror_exception` / 416r.13"* — update the comment; its assertions
(root absent under `:skip`) are unchanged since the closure still walls, now on
memmove.

### 9.3 Existing-test sweep (the u2kk lesson: re-run the *whole* `ptr_cells` set)

Per-file runs must use `--check-bounds=yes` to match `Pkg.test()` (Bennett-2mj3;
`test_utzc_dead_block_pruner.jl:234` literally interpolates
`Base.JLOptions().check_bounds` into a testset name, so it is known to be
mode-sensitive here).

Mandatory, in this order:

```
test_utzc_dead_block_pruner.jl      # the pruner whose set we now consume
test_416r13_jlglobal_singleton.jl   # the arm immediately above ours
test_iwo9_typetag.jl                # the arm above that
test_lf14_ptr_return_cells.jl       # the u2kk lesson — landing-convention tests
test_40ys_instanceless_callees.jl   # advanced above
test_7wsz_ptr_sret_fields.jl        # HEAD-adjacent; sret bookkeeping (§8.6)
test_klgz_determinism_guard.jl      # shares the reject site (GOT-stub classifier)
test_haiy_ptr_cells_store_load_gep.jl
test_nd45_ptr_cells_call_emission_multifn.jl
test_r92o_gc_alloc_obj.jl
test_416r12_closed_world_heap.jl
test_d1b_julia_set.jl
test_gate_count_regression.jl       # must print 39/39
```

then full `Pkg.test()` before push. Register the new file in
`test/runtests.jl` in canonical order (next to `test_utzc_dead_block_pruner.jl`).

### 9.4 Cross-repo (BennettVM)

**Argument that existing coverage suffices, with one cheap addition.**

3vf2 changes *nothing* about the IR BVM receives for the diamond: keep-branch +
empty block + `IRBranch(nothing, :__unreachable__, nothing)` is byte-identical
to what `test_utzc_unreachable_sink.jl` already exercises. The only delta is a
*subtracted* live-block instruction, which BVM cannot observe. So no new BVM
mechanism is under test and a new BVM fixture would be testing utzc, not 3vf2.

That said, the *end-to-end* claim "a 3vf2-extracted body runs and reverses" has
never been executed, and it is cheap: take the fixture-(a) `ParsedIR`, ship it
through `lower_vm` + `run!` + reverse, assert the `%pass` value
(`sdiv(n,4)`) and L1-injective reversal, plus a forced-guard run landing in the
`:error` `:__unreachable__` sink. **Recommend adding it** as
`BennettVM.jl/test/test_3vf2_dead_use_global_load.jl`, but scoped as *end-to-end
confidence*, not as a gate on 3vf2's exit — 3vf2's contract is extraction-side.

---

## 10. Exit criterion

**3vf2 is done when:**

1. `extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64}; ptr_cells=true)`
   no longer mentions `jl_diverror_exception` or `UNRECOGNIZED Julia JIT global`
   anywhere in its failure, for **any** member of the closed-world set;
2. the `_growend!` closure body specifically advances to the
   `llvm.memmove.p0.p0.i64` wall (§2.5 shows this is the immediate successor);
3. `test/test_3vf2_dead_use_global_load.jl` is green including the hazard (b),
   name-agnosticism (e) and `ptr_cells=false` byte-identity (f) cases;
4. `test_40ys` (I) is advanced and green; `test_gate_count_regression` is 39/39;
   full `Pkg.test()` green.

**Explicitly NOT 3vf2:**

* `llvm.memmove.p0.p0.i64` → **Bennett-8bys / Bennett-37mt** (already tracked).
* the root `_push40ys` body's `movq %fs:0` pgcstack wall → **Bennett-5oyt / U15**.
* `on_extract_error=:skip` dropping the root silently → **Bennett-9tg3**
  (pinned as known-gap (J)).
* caller/callee cell-width mismatch → **Bennett-ce9t** (known-gap (K)).
* `ptrtoint` on type tags → **Bennett-kvdv / iwo9**.

`bennettvm-xkl` (P0, the push!-Vector chain) is **not** closed by 3vf2; 3vf2
clears wall 3 of ≥4.

---

## 11. Risk register

| # | risk | likelihood | severity | mitigation / residual |
|---|---|---|---|---|
| R1 | Julia adds a new pre-allocated exception/interned global name | **high** (certain over releases) | — | **Eliminated by design.** No name set exists. This is the single biggest reason to prefer this over (i)/(iii). |
| R2 | Julia stops hoisting the load into the live predecessor (sinks it back into `%fail`) | medium | none | The load is then inside a pruned block and never converted at all. Both idioms work; 3vf2 is idiom-agnostic. Worth a worklog line so a future agent isn't confused when the arm stops firing. |
| R3 | Julia emits a *live* read of an exception singleton (`catch e` inspection) | low | high if silent | **Fails loud** (§8.1) naming the live block. Correct outcome: it is a genuine modelling gap deserving its own bead. |
| R4 | `_vec_vm_dead_blocks`'s definition of "dead" widens later (e.g. to `llvm.trap`-terminated or 0-pred blocks generally) | low | medium | Our arm's soundness is *parametric* in `dead_blocks`: it holds for any set the pruner actually empties. Widening the set widens the theorem consistently. But if anyone ever makes the pruner *keep* a block in `dead_blocks`, the theorem breaks — pin this coupling in a comment at both `vector_vm_cfg.jl:12` and the new arm. |
| R5 | A future refactor "simplifies" the dead-use gate into a name whitelist | medium | high | Test (e) (§9.1) is the tripwire; it goes red and its failure message names the design decision. |
| R6 | φ-in-live-block-from-dead-edge invalidates the parent-block test | **impossible** (zero-successor corollary, §4) | — | Comment the corollary in-code, else a future reader "fixes" it. |
| R7 | Additional unrecognised global kinds (`@jl_sym#...`) surface as walls | medium | low | Already covered by this arm *if* their uses are dead (§2.4 item 4); a live use is R3. |
| R8 | Threading a new kwarg breaks a caller | low | low | Only one caller forwards `ptr_cells` (`module_walk.jl:577`); other two default to empty. Verified by grep. |
| R9 | Gate-count / circuit-path drift | **none** | — | `ptr_cells=false` triple-gated (§6); 39/39 pinned. |
| R10 | The next wall (memmove) makes 3vf2 look like it "didn't help" | certain | none | State plainly in the worklog and the bead close: 3vf2's deliverable is *wall 3 of ≥4*, measured by the (I) disjunction advancing to `memmove`. |

---

## 12. Honest case for the alternatives

I want the reviewer to be able to reject this cleanly, so:

**Option (i), name whitelist**, is genuinely smaller — ~15 LOC, no threading,
no `LLVM.uses` walk, and it sits in the same shape as the two arms above it,
which is worth something for readability. If the implementer values *local
resemblance to existing code* above *category completeness*, (i) is defensible
for today's corpus. My objections stand on evidence, not taste: (a) it silently
mis-drops on a live read (§8.1) so it needs (iii)'s assertion anyway, and once
you have the assertion the names are redundant; (b) `@jl_sym#convert#463` is
already in the same function and outside any plausible `jl_*_exception` set
(§2.4); (c) R1 is a recurring bead cost with no upper bound.

**Option (ii) as briefed is not implementable as stated** — the use is an
`addrspacecast`, not a call (§2.3). Its repaired form (transitive walk through
casts to a throw-family callee) is *strictly more* code than this proposal and
*strictly less* sound, because it re-derives, hop by hop and heuristically, the
"this value can't escape" property that `dead_blocks` already establishes
exactly.

**Option (iii) hybrid** is this proposal minus the redundancy: keep the
assertion (which is the safety), drop the whitelist (which is the drift).

---

## 13. Implementation shape (for the implementer)

* CORE change (`extract/`) ⇒ CLAUDE.md §2 3+1 applies; this is one of the two
  proposer docs.
* Red-green: write `test/test_3vf2_dead_use_global_load.jl` from the fixtures in
  §9.1 **first**, confirm the exact RED messages in §2.7, then add the arm.
* One bead per commit; bundle the `.beads/embeddeddolt/` churn into the same
  commit (CLAUDE.md, Bennett-58rl / U214).
* Worklog: prepend to the highest-numbered chunk under `worklog/`
  (`ls worklog/ | sort -r | head -1`) — do **not** run `scripts/shard_worklog.py`.
  Worth recording, because none of it is derivable from the diff:
  the addrspacecast correction (§2.3), the `@jl_sym#convert#463` sighting
  (§2.4), the zero-successor corollary (§4), the `LLVM.isvolatile` /
  `LLVM.API.LLVMGetVolatile` API gotcha (§2.6), and the
  `raw=true` vs `raw=false` `.ll`-round-trip trap that makes a naive forecast
  probe report Bennett-7wsz instead of memmove (§2.5).
