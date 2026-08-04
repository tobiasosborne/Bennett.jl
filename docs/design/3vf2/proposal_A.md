# Bennett-3vf2 — Design Proposal A

**Proposer A**, 2026-08-04, branch `main` @ `51c81cd`.
Scope: the `@jl_diverror_exception` unrecognized-JIT-global wall in the
`_growend!` closure body (`bennettvm-xkl` P0 frontier, wall 3 after
Bennett-40ys and Bennett-7wsz).

> **Design doc only.** No `src/` or `test/` edits were made. All probes ran
> against unmodified `HEAD` with scratch fixtures under
> `scratchpad/d3A_*`; the "post-fix" observations were obtained by *textually*
> patching a dumped `.ll` (deleting the load lines and rewriting the throw
> operand to `ptr null`), which is byte-equivalent to what the proposed arm
> emits.

---

## 0. TL;DR — the decision

**Choose (iii), the hybrid**, in this precise form:

| Layer | Mechanism |
| --- | --- |
| **Recognition** | A literal **name census** of Julia's six pre-allocated exception singletons, transcribed from `julia.h:1055-1060`. A third global-load kind, sibling to the `+Type#N` and `jl_global#N` arms. |
| **Emission** | **Pure drop.** No `IRInst`, **no SSA alias**, **no `.globals` entry**. The value does not exist in the closed world; inventing an address for it would be a lie that a future dereference could read as garbage. |
| **Soundness guard** | An at-site **use-shape assertion**: every use of the load result must be a call to a throw-family callee (`_vec_vm_is_dead_throw_callee`). This is what *licenses* the drop; without it the drop is an unproven claim. |
| **Drift diagnostic** | A **near-miss arm**: a global matching `^jl_[a-z_]+_exception$` that is *not* in the census fails loud with a message naming the census, its `julia.h` provenance, and the one-line fix. |

Net: ~35 LOC across two files, entirely inside the existing `ptr_cells`
gate. Circuit path byte-identical (probe §1.6). Exit criterion is exact and
verified: the `push!` corpus advances to `llvm.memmove.p0.p0.i64`
(Bennett-8bys/37mt), which is **not** in this bead's scope.

Why hybrid rather than pure (i) or pure (ii) is argued in §3; the short
version is that (i) and (ii) are not really competing *mechanisms* — they are
competing about *where the soundness argument lives*. (i) puts it in a name;
(ii) puts it in a use-shape. The name is what makes the drop **auditable**;
the use-shape is what makes the drop **sound**. You want both, and they cost
15 LOC each.

---

## 1. Ground truth — probe transcripts

All probes ran one Julia process at a time. Scripts:
`scratchpad/d3A_probe{1..5}.jl`.

### 1.1 The wall reproduces exactly as filed (probe 1)

```
$ julia --project scratchpad/d3A_probe1.jl
======================================================================
P1: reproduce the wall (ptr_cells=true)
======================================================================
errtype = ErrorException
julia_set.jl: extract_parsed_ir_set_from_julia: extraction FAILED for callee
`#_growend!##0#a7027856` (callable=Tuple{Base.var"#_growend!##0#_growend!##1"{
Vector{Int64}, Int64, Int64, Int64, Int64, Int64, Memory{Int64},
MemoryRef{Int64}}}, argtypes=Tuple{}) — ir_extract.jl: load in
@julia_#_growend!##0_1141:%L13:   %jl_diverror_exception = load ptr, ptr
@jl_diverror_exception, align 8 — load of an UNRECOGNIZED Julia JIT global
`@"jl_diverror_exception"` ...
```

Reject site: `src/extract/instructions.jl:3829-3881` (generic arm), reached
because neither the type-tag arm (3770) nor the singleton arm (3795) matched.

### 1.2 The global's shape, and the module's whole global census (probe 1, P3)

```
n globals = 10
  @+Core.GenericMemoryRef#15566       const=true linkage=Private  init=ERR   typetag?=true  singleton?=false
  @jl_global#15568                    const=true linkage=Private  init=ERR   typetag?=false singleton?=true
  @+Core.ConcurrencyViolationError#15569 const=true linkage=Private init=ERR typetag?=true  singleton?=false
  @jl_diverror_exception              const=true linkage=External init=nothing typetag?=false singleton?=false
  @jl_global#15570                    const=true linkage=Private  init=ERR   typetag?=false singleton?=true
  @jl_sym#convert#15572               const=true linkage=Private  init=ERR   typetag?=false singleton?=false
  @jl_small_typeof                    const=true linkage=External init=nothing typetag?=false singleton?=false
  @jl_global#15573                    const=true linkage=Private  init=ERR   typetag?=false singleton?=true
  @+Core.GenericMemory#15574          const=true linkage=Private  init=ERR   typetag?=true  singleton?=false
  @_j_str_invalid GenericMemory siz...#1 const=true linkage=Private init=[108 x i8] c"..."
```

Two corrections / confirmations relative to the bead notes:

* **Confirmed:** `external constant ptr`, matches neither recogniser. But note
  `LLVM.initializer` returns **`nothing` cleanly** — it does *not* throw the
  `LLVMGlobalAliasValueKind` error the `jl_global#N` singletons throw. So it
  reaches `_extract_const_globals`' `init === nothing` arm
  (`module_walk.jl:957-987`), whose name gate (`_is_singleton_data_global_name`,
  line 982) excludes it → `continue`. **No `.globals` change is needed and none
  happens today.**
* **New:** `@jl_small_typeof` is a *second* unrecognized external constant ptr
  in the same module. It is used by a **ConstantExpr**, not a load, so it never
  reaches the load handler. Out of scope, but worth knowing it is there.

### 1.3 The use-shape, verified per load (probe 2)

```
FUNCTION julia_#_growend!##0_15564  (entry=true)
blocks = 50   dead = 15
   DEAD: %L71 %L90 %L96 %after_throw %after_noret %fail %fail9 %after_throw19
         %after_noret20 %oob %oob43 %after_noret51 %fail56 %fail61 %fail67

LOAD #1  @jl_diverror_exception in %L13     [deadblk=false]  →  ijl_throw in %fail    [dead=true]   ALL-USES-THROW = true
LOAD #2  @jl_diverror_exception in %L20     [deadblk=false]  →  ijl_throw in %fail9   [dead=true]   ALL-USES-THROW = true
LOAD #3  @jl_diverror_exception in %L25     [deadblk=false]  →  ijl_throw in %fail56  [dead=true]   ALL-USES-THROW = true
LOAD #11 @jl_diverror_exception in %pass57  [deadblk=false]  →  ijl_throw in %fail61  [dead=true]   ALL-USES-THROW = true
```

Four loads, four live parent blocks, **exactly one use each**, always
`ijl_throw` in an `unreachable`-terminated block. The bead's scout claim holds
verbatim.

Other unrecognized-global loads exist in this function
(`@jl_sym#convert#15572` in `%L71`) but sit **inside** dead blocks, so the
Bennett-utzc pruner drops their bodies before conversion — they never reach the
load handler. This is why they are not walls and will not become walls after
3vf2.

### 1.4 The guard is `and(true, or(true, X))` — dead at two levels (probe 2, and the raw IR)

Bead notes say `or i1 true, X`; the **branch condition** is one level above:

```llvm
L13:
  %19 = mul i64 5, %.unbox5
  %20 = icmp ne i64 %19, -9223372036854775808
  %21 = or i1 true, %20                     ; ← structurally true
  %divisor_valid = and i1 true, %21         ; ← the br condition
  %jl_diverror_exception = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
```

Both `or i1 true, _` and `and i1 true, _` are Julia's literal-divisor
divisor-validity idiom at `optimize=false`. Neither Bennett nor the utzc pruner
constant-folds them; the pruner keys off the `unreachable` **terminator** of
`%fail`, not off the guard. The kept conditional branch therefore evaluates to
`true` at VM runtime and always takes `%pass` — faithful, no folding needed.

All nine guarded-into-dead-block branches in this function, for completeness:

```
%L13   -> %fail(DEAD),   %pass       cond = and i1 true, %21
%L20   -> %fail9(DEAD),  %pass10     cond = and i1 true, %24
%L25   -> %fail56(DEAD), %pass57     cond = and i1 true, %30
%L58   -> %oob(DEAD),    %idxend     cond = and i1 %44, %memoryref_isinbounds
%L62   -> %L71(DEAD),    %L73        cond = xor i1 %51, true
%L84   -> %L90(DEAD),    %L93        cond = xor i1 %64, true
%idxend-> %oob43(DEAD),  %idxend48   cond = and i1 %92, %memoryref_isinbounds41
%pass57-> %fail61(DEAD), %pass62     cond = and i1 true, %110
%nonemptymem -> %fail67(DEAD), %pass68  cond = xor i1 %123, true
```

### 1.5 Pipeline order — the pruner does **not** save us (empirical)

`module_walk.jl:422` computes `dead_blocks = ptr_cells ? _vec_vm_dead_blocks(func) : ∅`
**before** the block-conversion loop (`:424` onwards), and the pruner short-circuits
at `:434-441` per block. But the diverror loads are **hoisted into live blocks**
(`%L13`, `%L20`, `%L25`, `%pass57`), so they are converted by the normal path and
hit the reject. Confirmed by §1.1: the error fires at `%L13`, a live block.

**Order verdict: the load is processed independently of pruning; the new arm is
required, and pruning is what makes the *drop* safe (the sole consumer's block
body is discarded).** Belt and braces: even with pruning off, `ijl_throw` is in
`benign_prefixes` (`instructions.jl:3391`) and is dropped without resolving its
operands.

Note also that utzc's Guard 1 (`_assert_dead_block_no_live_escape`,
`module_walk.jl:88-101`) checks *dead-defined → live-used*. Our direction is
*live-defined → dead-used*, which that guard deliberately does not police.

### 1.6 `ptr_cells` gating — the circuit path never reaches this (probe 4)

Hand-written fixture A (`scratchpad/d3A_fx_A_ok-shape.ll`), the div-guard
diamond decoupled from `_growend!`:

```
[A ok-shape ptr_cells=true]    WALL: load of an UNRECOGNIZED Julia JIT global `@"jl_diverror_exception"` ...
[A ok-shape ptr_cells=false]   OK blocks=3 insts=4 labels=[:top, :fail, :pass]
```

At `ptr_cells=false` the whole `if ptr_cells && ptr isa LLVM.GlobalVariable`
block (3768) and the reject (3829) are skipped; the load falls to the trailing
`return nothing  # non-integer load — skip` (3882), the SSA name is never
registered, and the only consumer (`ijl_throw`) is benign-dropped. **The
circuit path is already, accidentally, doing exactly what the new arm does
deliberately.**

And on the real corpus at `ptr_cells=false` the set path never gets near this
load — it dies two callees earlier:

```
P1b: extract_parsed_ir_set_from_julia(_push40ys, …; ptr_cells=false)
  → FAILED for callee `throw_boundserror#...`: VoidType reached _type_width (Bennett-dq8l / U81)
```

### 1.7 Post-fix behaviour, simulated (probes 3 and 5)

**(a) The `_growend!` closure, patched:**

```
A: single-function extraction of the PATCHED _growend! closure
dropped 4 loads:
   %jl_diverror_exception   = load ptr, ptr @jl_diverror_exception, align 8
   %jl_diverror_exception8  = load ptr, ptr @jl_diverror_exception, align 8
   %jl_diverror_exception55 = load ptr, ptr @jl_diverror_exception, align 8
   %jl_diverror_exception60 = load ptr, ptr @jl_diverror_exception, align 8

--- ptr_cells=true ---
WALL: ir_extract.jl: call in @julia_#_growend!##0_15564:%L79:
  call void @llvm.memmove.p0.p0.i64(ptr %memory_ref12.ptr_or_offset, ptr %.unbox52,
                                    i64 %46, i1 false)
  — memmove is not yet lowered to reversible gates ... Tracked in Bennett-8bys
    (Bennett-37mt Phase 1 — memmove deferred to Bennett-8bys)

--- ptr_cells=false ---
WALL: sret struct field 0 has type LLVM.PointerType(ptr) ... (Bennett-dv1z / Bennett-7wsz)
```

The corrected forecast in the bead notes is **confirmed exactly**: next wall is
`llvm.memmove`, already tracked, out of scope.

**(b) The whole closed-world set** (probe 3, part B — per-callee, diverror
patched out, `ptr_cells=true`):

```
n callees = 6
  typeof(Base.throw_boundserror) / Tuple{Vector{Int64}, Tuple{Int64}}   → OK (blocks=3)
  Type{BoundsError} / Tuple{Any, Tuple{Int64}}                          → WALL: llvm.memcpy dst not alloca-backed
  Base.var"#_growend!##0#_growend!##1"{...}                             → WALL: llvm.memmove (Bennett-8bys)
  Type{ConcurrencyViolationError} / Tuple{String}                       → WALL: unsupported LLVM type for width query: PointerType
  typeof(Core.throw_inexacterror) / Tuple{Symbol, Type, Int64}          → OK (blocks=3)
  Type{InexactError} / Tuple{Symbol, Any, Vararg{Any}}                  → WALL: no julia_* function in module
```

The three `Type{<:Exception}` constructors are **dropped before extraction** by
`drop_throw_leaves=true` (`julia_set.jl:349-352`), so the live set is
`{throw_boundserror ✓, _growend! closure ✗memmove, throw_inexacterror ✓}`.
**After 3vf2, `extract_parsed_ir_set_from_julia(_push40ys, …; ptr_cells=true)`
lands on `llvm.memmove` and nothing else.**

**(c) Exact GREEN target for the unit fixture** (probe 5 — fixture A with the
load deleted):

```
ptr_cells=true   ret_width=64  args=[(:n, 64)]  globals=0
   %top   insts=3   IRICmp(:c0, :ne, Const(4), Const(0), 64)
                    IRBinOp(:c1, :or, Const(-1), SSA(:c0), 1)
                    IRBinOp(:divisor_valid, :and, Const(-1), SSA(:c1), 1)
                    TERM IRBranch(SSA(:divisor_valid), :pass, :fail)
   %fail  insts=0   TERM IRBranch(nothing, :__unreachable__, nothing)
   %pass  insts=1   IRBinOp(:q, :sdiv, SSA(:n), Const(4), 64)
                    TERM IRRet(SSA(:q), 64)

ptr_cells=false  — BYTE-IDENTICAL to the above.
```

That identity is load-bearing for §7 (BVM): the arm introduces **no new
VM-facing construct**. It removes one instruction; the surviving diamond and its
`:__unreachable__` sink are exactly what Bennett-utzc already ships and BVM
already covers.

### 1.8 The census, from Julia's own source

```
$ grep -n "_exception" $JULIA/include/julia/julia.h
1055:extern JL_DLLIMPORT jl_value_t *jl_stackovf_exception JL_GLOBALLY_ROOTED;
1056:extern JL_DLLIMPORT jl_value_t *jl_memory_exception JL_GLOBALLY_ROOTED;
1057:extern JL_DLLIMPORT jl_value_t *jl_readonlymemory_exception JL_GLOBALLY_ROOTED;
1058:extern JL_DLLIMPORT jl_value_t *jl_diverror_exception JL_GLOBALLY_ROOTED;
1059:extern JL_DLLIMPORT jl_value_t *jl_undefref_exception JL_GLOBALLY_ROOTED;
1060:extern JL_DLLIMPORT jl_value_t *jl_interrupt_exception JL_GLOBALLY_ROOTED;
```

(Julia 1.12.3.) Exactly **six**, declared as one contiguous block, all matching
`^jl_[a-z]+_exception$`. `jl_current_exception` / `jl_exception_occurred` are
**functions**, not `GlobalVariable`s, so they cannot reach this arm even though
one of them matches the pattern loosely.

---

## 2. What the value *is*, and therefore what to emit

`@jl_diverror_exception` holds the address of a **pre-allocated, globally-rooted
`DivideError()` object** in the Julia runtime's heap. Two consequences:

1. **It is not in the closed world.** BennettVM's arena contains what the
   extractor put there. There is no `DivideError` object, no type tag for it, no
   fields. Any address we hand out for it is fictional.
2. **Nothing observes it.** Verified per-load in §1.3: the sole consumer is
   `ijl_throw`, which Bennett drops (twice over: utzc block pruning, and
   `benign_prefixes`).

So the honest model is **"this value does not exist; nobody may read it"**, which
in ParsedIR terms is: emit nothing, bind nothing.

### 2.1 Why *not* mint an identity like the type-tag arm

The type-tag arm emits `IRBinOp(dest, :or, iconst(id), iconst(0), 64)` and pushes
into `tag_ssa`, because a type tag **is** consumed — it round-trips through
`ptrtoint`/`inttoptr` into an ignored `gc_alloc_obj` tag argument
(`instructions.jl:2896-2935`). Minting is right there because the consumer only
needs *an identity*, never *the bytes*.

Minting for an exception singleton would be strictly worse:

* It manufactures a plausible-looking 64-bit cell value that a future
  dereference would read as **arena cell `id`** — someone else's data. That is
  exactly the silent-corruption class CLAUDE.md §1 exists to prevent.
* It emits a dead instruction into a **live** block, so BVM executes an `or`
  whose result nothing reads — cost is trivial, but it is noise in a hot path
  and in every gate/instruction census.
* If it did *not* join `tag_ssa`, a downstream `ptrtoint %exc` would fail loud at
  `instructions.jl:2914` anyway — the same protection a pure drop gets for free
  from `_operand`. So minting buys nothing and costs the fiction.

### 2.2 Why the drop needs no `.globals` entry and no SSA alias

* `.globals`: contrast with the `jl_global#N` singleton arm, which materialises a
  zeroed 16-cell Memory header **because the header is read as data** (a
  length@cell0 that bounds a copy loop). Here nothing is read; a `.globals` entry
  would be an unreferenced key. Verified: `_extract_const_globals` already skips
  this global (§1.2).
* **SSA alias**: contrast again with the singleton arm, which does
  `names[inst.ref] = Symbol(pname)` because the singleton pointer flows into
  `IRPtrOffset`/`IRStore`/φ in live blocks — the alias is what stops a dangling
  operand, and it must collapse the repeated loads to one canonical key. Here the
  single consumer is dropped, so there is nothing to bind.

  **Leaving the name unregistered is a feature, not an oversight:** if a live
  consumer ever appears, `_operand` (`helpers.jl:203-207`) fails loud with
  *"unknown operand ref … the producing instruction was skipped"*. That is the
  built-in tripwire. The use-shape assertion (§3.3) exists to convert that
  slightly-vague downstream error into a named, at-site one.

**Downstream `resolve!` sees nothing.** No IRInst is emitted, no name is bound,
so `lowering/operand.jl:resolve!` never encounters the value; the ParsedIR is
identical to one produced from IR in which the load was never emitted (proved
byte-for-byte in §1.7c).

---

## 3. The contested axis — analysis and verdict

### 3.1 The framing

(i) and (ii) are usually pitched as "whitelist vs shape", but they are answering
different questions:

* **(i) name** answers *"what is this value?"* → "a runtime exception singleton
  we do not model." That is a **semantic** claim, checkable against `julia.h`.
* **(ii) use-shape** answers *"does anyone need this value?"* → "no, its only
  consumers are instructions we discard." That is a **soundness** claim,
  checkable against `LLVM.uses`.

The drop is licensed by the *second* claim. The *first* claim is what makes the
arm auditable, bounded, and explicable in the reject message. Treating them as
alternatives forces you to give one of those up.

### 3.2 The case against pure (ii) as the *recognition* rule

Use-shape-only recognition is tempting (it never needs updating) but has three
concrete defects:

1. **It couples admission to an unrelated allowlist.** `_vec_vm_is_dead_throw_callee`
   and `benign_prefixes` exist because Bennett currently *discards* throws. If
   BennettVM ever models a reversible throw (and `:__unreachable__` already hints
   at wanting to), those consumers stop being discardable — but a use-shape arm
   would have been silently dropping their operands for months. The failure would
   surface as a missing argument at the VM, far from here.
2. **It removes a tripwire.** Probe 4 fixture D (`@jl_some_future_global`,
   `external constant ptr`, sole use `ijl_throw`) currently fails loud:

   ```
   [D other-global ptr_cells=true]  WALL: load of an UNRECOGNIZED Julia JIT global
                                    `@"jl_some_future_global"` ...
   ```
   Under (ii) this becomes a **silent admit**. Whatever that hypothetical global
   is — a task-local pointer, a world-age counter, a GC flag — we would never
   learn it exists. Under (i)+(iii) it still walls, and the wall carries a name.
3. **It breaks the CW-D3 posture and the reject message.** Both existing arms are
   name-based on purpose ("recognise by NAME, never by the JIT address" —
   `constexpr.jl:126-133`), and the generic reject enumerates
   *"the recognized runtime-global kinds are: (1) … (2) …"*. A shape-based kind
   cannot be enumerated in that sentence; the message degrades to
   "…(3) anything whose uses we happened to drop", which is not a kind.

### 3.3 The case against pure (i)

Without a use-shape check, the drop is an **unproven assertion**. Everything in
§1.3 is an observation about Julia 1.12.3's codegen at `optimize=false`. If a
future Julia (or a different `-O` level, or a different call site) produced

```llvm
%exc = load ptr, ptr @jl_diverror_exception
%pi  = ptrtoint ptr %exc to i64          ; a LIVE read
```

pure (i) would drop the load and let the `ptrtoint` fail with the generic
*"unsupported LLVM opcode"* / *"unknown operand ref"*, several instructions away
from the cause. Probe 4 fixtures B and C are exactly this shape; today they fail
loud (at the load), and after a pure-(i) fix they would fail *later and worse*.

The assertion is 10 lines and turns that into a named, at-site reject.

### 3.4 Verdict

**(iii) hybrid.** Census for recognition; use-shape for soundness; near-miss for
drift. The cost over pure (i) is ~12 LOC; the cost over pure (ii) is ~12 LOC and
a census that must track `julia.h` — which the near-miss arm reduces to a
one-line, fully-diagnosed edit.

**A note on the road not taken.** A regex recogniser
(`^jl_[a-z_]+_exception$`) *would* be sound given the use-shape assertion, and
it eliminates the drift bead entirely. I am not proposing it because the drop's
justification ("this is a runtime object the closed world does not model") is a
per-name semantic claim I verified for six names and cannot verify for names
that do not exist yet. If drift becomes annoying in practice, relaxing the census
to the regex is a **one-line, reversible** follow-up — and the assertion that
makes it safe will already be in place. That is the right order to do it in.

---

## 4. The mechanism — exact insertion points

### 4.1 `src/extract/constexpr.jl` — recognisers, **insert after line 159**

Immediately after `_is_singleton_data_global_name` (158-159) and before
`_canonical_type_path` (161+), so the three recognisers read as a group:

```julia
# ---- Bennett-3vf2 / CW-D3 Lever 3: jl_*_exception singleton globals ---------
#
# Julia's runtime pre-allocates six exception objects and exports their
# addresses as `external constant ptr` module globals (julia.h:1055-1060,
# Julia 1.12.3):
#
#     jl_stackovf_exception   jl_memory_exception   jl_readonlymemory_exception
#     jl_diverror_exception   jl_undefref_exception jl_interrupt_exception
#
# Codegen HOISTS `load ptr, ptr @jl_<x>_exception` into the LIVE predecessor of
# a guard diamond whose throwing arm is `unreachable`-terminated (verified: all
# 4 sites in the `_growend!` closure, docs/design/3vf2/proposal_A.md §1.3), so
# the load survives the Bennett-utzc dead-block pruner even though its only
# consumer does not.
#
# Unlike a type-tag (an IDENTITY fed to an ignored gc_alloc_obj arg) or a
# `jl_global#N` singleton (a DATA pointer whose header is read), this value is
# NEVER OBSERVED: its sole consumer is `ijl_throw`, dropped twice over (utzc
# body pruning; `benign_prefixes` in instructions.jl §U15). It is also a Julia
# RUNTIME heap object with no closed-world counterpart — there is no arena cell
# that is it. So the load is DROPPED outright: no IRInst, no SSA binding, no
# `.globals` entry. See instructions.jl for the arm and its use-shape guard.
#
# The census is a LITERAL SET, not a pattern: the "not modelled, never read"
# claim is per-name semantics checked against julia.h, not a naming convention.
# `_looks_like_...` below turns a Julia-version addition into a NAMED reject
# with a one-line fix instead of the generic unrecognized-global message.
const _JL_EXCEPTION_SINGLETON_GLOBALS = Set{String}((
    "jl_diverror_exception",
    "jl_stackovf_exception",
    "jl_memory_exception",
    "jl_readonlymemory_exception",
    "jl_undefref_exception",
    "jl_interrupt_exception",
))

_is_exception_singleton_global_name(s::AbstractString)::Bool =
    s in _JL_EXCEPTION_SINGLETON_GLOBALS

# Near-miss: the julia.h naming convention, for the drift diagnostic ONLY.
# NEVER used to admit a load (see proposal_A.md §3.4).
_looks_like_exception_singleton_global_name(s::AbstractString)::Bool =
    occursin(r"^jl_[a-z_]+_exception$", s)
```

### 4.2 `src/extract/constexpr.jl` — the use-shape guard, immediately after

```julia
# Bennett-3vf2 soundness guard (CLAUDE.md §1). DROPPING the load is licensed by
# one fact only: NOTHING OBSERVES THE VALUE. Assert it rather than assume it —
# every use of the load result must be a call to a throw-family callee (the
# same classifier the utzc pruner's surprise guard uses, so the two agree by
# construction). A use we cannot prove discardable — a ptrtoint, a store, a φ,
# a call to anything else — means Julia changed the idiom and the value now
# MATTERS; fail loud AT THE LOAD, not at whatever consumes it three
# instructions later. Zero uses is also a reject: that shape has never been
# observed and would mean codegen emitted a load for nothing.
function _assert_exception_global_load_is_throw_only(inst::LLVM.Instruction,
                                                     gname::AbstractString)
    n = 0
    for u in LLVM.uses(inst)
        n += 1
        usr = LLVM.user(u)
        ok = false
        if usr isa LLVM.Instruction && LLVM.opcode(usr) == LLVM.API.LLVMCall
            cf = LLVM.called_operand(usr)
            ok = cf isa LLVM.Function && _vec_vm_is_dead_throw_callee(LLVM.name(cf))
        end
        ok || _ir_error(inst,
            "load of the Julia pre-allocated exception singleton " *
            "`@\"" * gname * "\"` has a use that is NOT a throw-family call: " *
            "`" * strip(string(usr)) * "`. The closed world does not model the " *
            "runtime exception OBJECT (there is no arena cell that is it), so " *
            "the load is only droppable while nothing observes its value — the " *
            "sole observed use is `ijl_throw`, which Bennett discards. A " *
            "non-throw use means the value now MATTERS and dropping it would " *
            "silently feed a dangling / fictional pointer downstream. Fail loud " *
            "at the load site (Bennett-3vf2 / CLAUDE.md §1).")
    end
    n == 0 && _ir_error(inst,
        "load of `@\"" * gname * "\"` has ZERO uses — an unobserved exception-" *
        "singleton load has never been emitted by Julia codegen and is not a " *
        "shape Bennett-3vf2 verified. Refusing to drop it silently (CLAUDE.md §1).")
    return nothing
end
```

### 4.3 `src/extract/instructions.jl` — the arm, **insert between lines 3798 and 3799**

i.e. as the third arm inside the existing `if ptr_cells && ptr isa LLVM.GlobalVariable`
block (opened at 3768), after the `_is_singleton_data_global_name` arm (3795-3798)
and before that block's closing `end` (3799):

```julia
            # Bennett-3vf2 / CW-D3 Lever 3: `load ptr, ptr @jl_<x>_exception`
            # — the address of a Julia RUNTIME pre-allocated exception object,
            # hoisted by codegen into the LIVE predecessor of a div/bounds guard
            # diamond whose throwing arm is `unreachable`-terminated. The
            # Bennett-utzc pruner discards the throwing arm's BODY (the sole
            # consumer, `ijl_throw`), but the hoisted load itself lives in a KEPT
            # block and reaches us here. Third recognized kind, alongside the
            # type-tag (identity) and `jl_global#N` (data-header) arms above —
            # but unlike both, this value is NEVER OBSERVED, so we emit NOTHING
            # and bind NOTHING: no IRInst, no `names[]` alias, no `.globals`
            # entry. The unbound SSA name is the tripwire — any future live
            # consumer fails loud in `_operand` ("unknown operand ref"); the
            # assertion below makes that failure land HERE, named, instead.
            # (docs/design/3vf2/proposal_A.md §2, §4.)
            if _is_exception_singleton_global_name(pname)
                # Reading the singleton's ADDRESS BITS AS DATA is a different
                # (unmodelled) thing from taking the pointer — refuse it rather
                # than drop it (proposal_A.md §6, failure mode F3).
                LLVM.value_type(inst) isa LLVM.PointerType || _ir_error(inst,
                    "non-pointer load of the exception singleton `@\"" * pname *
                    "\"` (result type $(string(LLVM.value_type(inst)))) — this " *
                    "reads the runtime object's ADDRESS BITS AS DATA, which the " *
                    "closed world cannot reproduce (the address is a JIT/runtime " *
                    "value, non-deterministic across replays). Bennett-3vf2 " *
                    "models only the pointer-valued load, and only as a drop " *
                    "(CLAUDE.md §1).")
                _assert_exception_global_load_is_throw_only(inst, pname)
                return nothing
            end
            # Drift diagnostic (Bennett-3vf2): a NEW `jl_<x>_exception` global —
            # i.e. a Julia version added one to julia.h:1055-1060. Reject with the
            # census named and the one-line fix spelled out, rather than letting
            # it fall into the generic unrecognized-global message below.
            if _looks_like_exception_singleton_global_name(pname)
                _ir_error(inst,
                    "load of `@\"" * pname * "\"` matches Julia's pre-allocated " *
                    "exception-singleton NAMING convention but is NOT in the " *
                    "census `_JL_EXCEPTION_SINGLETON_GLOBALS` (" *
                    join(sort(collect(_JL_EXCEPTION_SINGLETON_GLOBALS)), ", ") *
                    "), transcribed from julia.h:1055-1060 (Julia 1.12.3). Your " *
                    "Julia version has added an exception singleton. FIX: verify " *
                    "in `\$JULIA/include/julia/julia.h` that `" * pname * "` is a " *
                    "`JL_GLOBALLY_ROOTED jl_value_t *` exception object, then add " *
                    "it to the census in src/extract/constexpr.jl. Failing loud " *
                    "rather than pattern-matching it in: the drop is licensed by " *
                    "per-name semantics, not by the name shape (Bennett-3vf2 / " *
                    "CLAUDE.md §1).")
            end
```

### 4.4 What does *not* change

* `module_walk.jl` — nothing. `_extract_const_globals` already skips this global
  via the `init === nothing` arm's name gate (§1.2, verified).
* `vector_vm_walk.jl` — `_vec_vm_is_dead_throw_callee` is **reused verbatim**,
  not extended (CLAUDE.md §12). `ijl_throw` is already in it (line 282).
* The generic reject at 3829-3881 — **unchanged**, but its enumeration comment
  ("The recognized runtime-global kinds are: (1) … (2) …") should gain
  *"(3) `jl_<x>_exception` pre-allocated exception singletons (dropped: never
  observed)"* so the message stays truthful. That is a message edit, and
  `test_416r13_jlglobal_singleton.jl` testset (3) asserts only `occursin("UNRECOGNIZED")`
  and the global name, so it does not flip (§6.3).
* BennettVM — **nothing** (§7).

---

## 5. `ptr_cells` gating verdict

**Gate it, inside the existing block — no new gate, no ungated arm.**

| | Today | After |
| --- | --- | --- |
| `ptr_cells=true` | reject at 3829 | drop (asserted) |
| `ptr_cells=false` | silent skip at 3882 (`return nothing`, name unbound) | **identical** — the arm is inside the `ptr_cells &&` block and is not reached |

The `ptr_cells=false` path already produces exactly the drop semantics by
accident (§1.6 fixture A: `OK blocks=3 insts=4`), so an ungated arm would change
nothing observable while widening the blast radius. Keep the gate; the arm's
comment should say *why* the circuit path needs no arm (the consumer is
benign-dropped there too), so a future reader does not "helpfully" ungate it.

**Gate-count baselines:** untouched. The circuit path never enters the modified
region; `reversible_compile` never sets `ptr_cells=true`. Verification is
`test/test_gate_count_regression.jl` **39/39** unchanged — a cheap, direct check
the implementer must run rather than argue.

**Where the reject it replaces fires at `ptr_cells=false`: nowhere.** Probed
directly (§1.6): the whole reject arm is `ptr_cells`-gated, and on the real
corpus the `ptr_cells=false` set path dies two callees earlier at the
Bennett-dq8l/U81 `VoidType` wall in `throw_boundserror`. There is no
`ptr_cells=false` behaviour to preserve here beyond "keep skipping".

---

## 6. Failure modes

**F1 — A whitelisted global's load is used by something live (future Julia
hoists differently, or an `-O` level changes the idiom).**
→ `_assert_exception_global_load_is_throw_only` fires at the load, naming the
offending user's full instruction text. Loud, at-site, one line to diagnose.
Fixture B/C in the test plan pin this. *Second line of defence:* even if the
assertion were removed, the unbound SSA name makes `_operand` fail loud
(`helpers.jl:203-207`). There is no silent path.

**F2 — A whitelisted global's load is used by BOTH a throw and a live read.**
→ Same assertion; the quantifier is **all** uses, not **any**. This is precisely
the loose-classifier trap a use-shape-*recogniser* would have to get right by
hand; here it falls out of the guard. Fixture C.

**F3 — The singleton's address is read as DATA (`load i64, ptr @jl_..._exception`).**
→ The pointer-type check inside the arm rejects it with a message that names the
determinism problem (a JIT address is not replayable). Without that check the
load would fall through to `haskey(names, ...)` = false and then to the generic
reject (which is pointer-gated) → `return nothing` → a vaguer downstream
`_operand` error. Cheap to check, so check it.

**F4 — Julia adds a seventh exception singleton.**
→ Near-miss arm: named reject, census printed, `julia.h` path and the exact
one-line fix in the message. This is the (i)-arm risk the bead flagged, reduced
from "new investigation" to "add a string after reading one header line".

**F5 — Julia *renames* an existing singleton (e.g. drops the `_exception`
suffix).**
→ Falls through to the generic unrecognized-global reject at 3829. Still loud,
still named, just without the tailored advice. Acceptable; this has not happened
in Julia's C ABI in the header's lifetime.

**F6 — A non-exception global acquires throw-only uses.**
→ Still rejected (it is not in the census). This is the tripwire pure (ii) would
have surrendered; fixture D pins that it stays.

**F7 — `LLVM.uses` on a load in a large function is slow.**
→ Not a concern: 4 loads × 1 use each in the real corpus; the walk is per-use,
not per-block. No `_vec_vm_dead_blocks` recomputation is needed (the guard is
purely use-based, deliberately — it does not need the CFG).

---

## 7. Test plan (RED-GREEN)

### 7.1 New file `test/test_3vf2_exception_singleton.jl` — the unit fixtures

Hand-written `.ll`, deliberately **decoupled from `_growend!`** so Julia codegen
drift cannot silently rot the test (the `mktempdir` + `extract_parsed_ir_from_ll`
convention of `test_416r13_jlglobal_singleton.jl` testset (3)). All four
fixtures were run against `HEAD` and their **current** behaviour is recorded
below, so "RED" is a measured claim.

**(A) the load-bearing shape — RED today, GREEN after.**

```llvm
@jl_diverror_exception = external constant ptr
declare void @ijl_throw(ptr)
define i64 @julia_f3vf2(i64 signext %n) {
top:
  %c0 = icmp ne i64 4, 0
  %c1 = or i1 true, %c0
  %divisor_valid = and i1 true, %c1
  %exc = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
fail:
  call void @ijl_throw(ptr %exc)
  unreachable
pass:
  %q = sdiv i64 %n, 4
  ret i64 %q
}
```

* RED (measured): `WALL: … UNRECOGNIZED Julia JIT global @"jl_diverror_exception"`.
* GREEN target (measured on the patched module, §1.7c) — assert the **exact**
  ParsedIR, not just "no throw":
  * 3 blocks `[:top, :fail, :pass]`;
  * `%top` has exactly 3 insts (`IRICmp`, two `IRBinOp` on width 1) — i.e. the
    load contributed **zero** instructions;
  * `%fail` has 0 insts and terminator `IRBranch(nothing, :__unreachable__, nothing)`;
  * `%pass` has the `sdiv` and `IRRet(SSA(:q), 64)`;
  * `isempty(pir.globals)` — no `.globals` entry was minted;
  * **no SSA operand anywhere is named `:exc`** (reuse `_ssa_names` from
    `test_416r13_jlglobal_singleton.jl:37`) — the "no dangling alias" invariant;
  * `ptr_cells=false` yields a **structurally identical** ParsedIR (measured:
    byte-identical) — the gating invariant, asserted rather than asserted-about.

**(B) live escape — must STAY red, with the NEW message.** Same global, sole use
`ptrtoint` in a live block. Today: generic UNRECOGNIZED. After: the assertion
message. Assert `occursin("NOT a throw-family call", msg)` and
`occursin("Bennett-3vf2", msg)` and that the offending `ptrtoint` text appears.

**(C) mixed use — throw AND live read.** Today: generic UNRECOGNIZED (measured).
After: same assertion. This is the F2 pin and the single most important
regression guard on the arm.

**(D) a non-census `external constant ptr` with throw-only uses**
(`@jl_some_future_global`). Today: `WALL: … UNRECOGNIZED … @"jl_some_future_global"`
(measured). After: **unchanged**. This is the pin that the arm did not quietly
become use-shape-only.

**(E) near-miss drift.** `@jl_futureoops_exception`, throw-only use. Must reject
with `occursin("census", msg)`, `occursin("julia.h", msg)`, and the six census
names present in the message.

**(F) non-pointer load** — `%v = load i64, ptr @jl_diverror_exception`. Must
reject with the F3 message.

**(G) census ↔ `julia.h` observational pin.** If `Sys.BINDIR/../include/julia/julia.h`
exists, `grep` it for `jl_\w+_exception JL_GLOBALLY_ROOTED` and assert the
extracted set **equals** `_JL_EXCEPTION_SINGLETON_GLOBALS`; `@test_skip` when the
header is absent (source builds / stripped installs). This is the drift alarm:
it goes RED on the Julia upgrade that adds a singleton, *before* a user hits it.

### 7.2 Integration pin — advance `test_40ys_instanceless_callees.jl` gate (I)

Gate (I) (`test/test_40ys_instanceless_callees.jl:434-457`) is the standing
"version-observational landing pin". Per its own header convention, it goes RED
when the named wall lands and must be **advanced, not deleted**:

* keep `@test !(e isa UndefRefError)`, `occursin("_growend!", e.msg)`;
* keep the `!occursin("Bennett-dv1z")` negative from 7wsz;
* **add** `@test !occursin("jl_diverror_exception", e.msg)` and
  `@test !occursin("UNRECOGNIZED Julia JIT global", e.msg)` — the 3vf2 wall is
  gone;
* **rewrite the landing disjunction to name memmove**, measured in §1.7a:
  ```julia
  @test occursin("memmove", e.msg) || occursin("Bennett-8bys", e.msg) ||
        occursin("Bennett-37mt", e.msg) ||
        occursin("Bennett-5oyt", e.msg) || occursin("U15", e.msg)
  ```
  (The `5oyt`/`U15` disjunct is retained per the file's own note that *which*
  set member fails first is registration order, not a contract.)

### 7.3 Existing-test flips — expected set

* `test_416r13_jlglobal_singleton.jl` testset (3): **no flip.** Its fixture is
  `@"weird_global#5"`, not a census name, and it asserts only
  `occursin("UNRECOGNIZED")` + the global name. The generic message's
  kinds-enumeration edit (§4.4) does not touch either assertion. *Verify, do not
  assume.*
* `test_utzc_dead_block_pruner.jl`: **no flip** — no pruner behaviour changes.
* `test_7wsz_ptr_sret_fields.jl`, `test_40ys_…` (A)-(H2), (J), (K): no flip; only
  gate (I) is a landing pin.
* `test_gate_count_regression.jl`: **39/39**, no flip (§5).

### 7.4 The u2kk lesson — mandatory re-run set

Per `worklog/091_2026-06-26_jfw6_recon_lock.md:65` ("any change to a callee's
`ptr_cells` extraction MUST re-run `test_lf14`"), and because this arm sits in
the shared load handler that every `ptr_cells` consumer traverses, the
implementer must run the **whole `ptr_cells` family** and report counts:

```
test_lf14_ptr_return_cells.jl        ← the standing rule (27/27 at last pin)
test_416r13_jlglobal_singleton.jl    ← nearest sibling (the arm it extends)
test_iwo9_typetag.jl                 ← arm 1
test_utzc_dead_block_pruner.jl       ← the pruner this arm partners with
test_40ys_instanceless_callees.jl    ← gate (I)
test_7wsz_ptr_sret_fields.jl         ← the wall immediately before this one
test_u2kk_param_memcpy.jl  test_8g7m_ptr_icmp_cells.jl  test_beaw_null_ptr.jl
test_583s_memdata_bounds.jl  test_9n3y_memheader_gep.jl  test_haiy_ptr_cells_store_load_gep.jl
test_qmv7_gc_loaded_memcpy.jl  test_vbv9_arena_memcpy.jl  test_d1b_julia_set.jl
test_klgz_determinism_guard.jl  test_yd4f_undef_phi_cells.jl  test_nd45_ptr_cells_call_emission_multifn.jl
test_xrd6_sret_consumed_call.jl  test_416r1{2,6,7}_*.jl  test_6bu3_struct_aggregate.jl
test_ares_atomic_vm_relax.jl  test_3ptu_fence_drop.jl  test_qal5_multi_index_gep.jl
test_tu6i_struct_extractvalue.jl  test_r92o_gc_alloc_obj.jl  test_zf5v_gc_preserve.jl
test_lbot_overflow_intrinsic.jl  test_a70z_overflow_const_bit.jl  test_59zi_sret_call_memcpy.jl
test_8bys_variable_memset.jl  test_gate_count_regression.jl
```

then full `Pkg.test()` (green claim requires `--check-bounds=yes` parity per
CLAUDE.md §8 / Bennett-2mj3).

### 7.5 Cross-repo (BennettVM)

**Argument that existing coverage suffices — with the measurement to back it.**

The arm's entire VM-facing effect is *"one fewer `IRInst`"*. Probe 5 measured the
post-fix ParsedIR for fixture A and it is **identical under `ptr_cells=true` and
`ptr_cells=false`**, and identical to what the same source produces with the load
absent: three blocks, a kept conditional branch, and
`IRBranch(nothing, :__unreachable__, nothing)` in `%fail`. Every one of those
constructs is Bennett-utzc's, and BVM already pins the sink in
`BennettVM.jl/test/test_utzc_unreachable_sink.jl`. 3vf2 introduces **no new
opcode, no new global, no new operand kind** — there is nothing for BVM to learn.

**However**, one cheap belt is worth taking, because it is the first time a
*kept, structurally-constant* guard (`and(true, or(true, X))`) is fed to the VM
from this path: port fixture A into a BVM fixture and assert it (a) runs, taking
`%pass` for every input, (b) never reaches the `:__unreachable__` sink, and
(c) reverses to the initial state (L1-injective). That is a ~20-line BVM test
with no BVM *source* change. If the orchestrator prefers to hold the line on
"no cross-repo work in this bead", the honest fallback is: BVM sees no new
construct, so `test_utzc_unreachable_sink.jl` is the coverage, and the guard
evaluation is ordinary `and`/`or` already covered by BVM's binop tests.

---

## 8. Exit criterion for 3vf2 vs what remains for `bennettvm-xkl`

**3vf2 is DONE when:**

1. `test_3vf2_exception_singleton.jl` fixtures A-G green (A structural-exact, B/C/D/E/F
   loud-and-named, G observational).
2. `extract_parsed_ir_set_from_julia(_push40ys, Tuple{Int64}; ptr_cells=true)`
   no longer mentions `jl_diverror_exception` or `UNRECOGNIZED Julia JIT global`,
   and instead reports **`llvm.memmove.p0.p0.i64` at `%L79`** (measured, §1.7a).
3. `test_40ys` gate (I) advanced to the memmove disjunction and green.
4. `test_gate_count_regression.jl` 39/39; the §7.4 `ptr_cells` family green; full
   `Pkg.test()` green.
5. Worklog entry prepended to the top chunk (`worklog/097_2026-08-03_40ys_instanceless_callees.md`
   — check `ls worklog/ | sort -r | head -1` at commit time, it may have rolled)
   recording: the hoisted-load idiom, the `and(true, or(true, X))` double-dead
   guard, the "pruner does not save us — the load is in a KEPT block" ordering
   gotcha, and the six-name census with its `julia.h` provenance.

**Explicitly NOT 3vf2 (remains for `bennettvm-xkl` P0):**

* **`llvm.memmove.p0.p0.i64`** — the very next wall, in the same closure at
  `%L79`. Tracked in **Bennett-8bys** (Phase 3: byte-granularity / variable-size
  / overlap / memmove), deferred there by **Bennett-37mt** Phase 1. Needs static
  disjointness, which needs alias analysis Bennett does not have. *This is the
  single biggest remaining item on the `push!` chain and it is a much larger
  bead than 3vf2.*
* `llvm.memcpy` dst-not-alloca-backed in the `BoundsError` constructor, and the
  `PointerType` width query in the `ConcurrencyViolationError` constructor
  (probe 3 part B) — currently **masked** by `drop_throw_leaves=true`, so not on
  the critical path, but they will surface if that default ever changes.
* `jl_alloc_genericmemory_unchecked` — **not a wall**; probe 2 confirms it takes
  a type-tag identity operand and extracts as an opaque `IRCall` under
  `mem=:auto, ptr_cells=true` (LOAD #13 in §1.3's function dump feeds it cleanly).
* `iwo9` ptrtoint / **Bennett-kvdv** — unchanged by this bead.

---

## 9. Risk register

| # | Risk | Severity | Mitigation / residual |
| --- | --- | --- | --- |
| R1 | **Julia-version drift of the census.** A new `jl_<x>_exception` in a future julia.h. | Low·Loud | Near-miss arm (§4.3) gives a named reject with the exact fix; fixture G goes RED on upgrade *before* a user hits it. Residual: one string edit per Julia major. |
| R2 | **Drift of the hoisted-load idiom.** Julia stops hoisting, or hoists *more* (e.g. sinks the throw into the live block). | Med·Loud | If the load moves *into* the dead block, utzc prunes it and the arm goes unused (harmless — fixtures still exercise it). If a live consumer appears, the use-shape assertion fires by name. Residual: none silent. |
| R3 | **`_vec_vm_is_dead_throw_callee` drifts** (someone adds a prefix for another reason). | Low | The classifier is shared with the utzc surprise guard, so a change there is already a reviewed, tested edit; widening it widens *what we prove discardable*, and the assertion's job is only to prove that. Note the coupling in the arm's comment. |
| R4 | **Reversible-throw modelling arrives** and `ijl_throw` stops being droppable. | Low·Deferred | Then the assertion's premise is false and it must be revisited — but the assertion *names* the premise in its message, so the revisit is discoverable by grep. This is precisely the coupling that a use-shape-*recogniser* would have buried. |
| R5 | **The drop hides a real dependency we did not think of** (e.g. a GC-root or `julia.gc_preserve` token referencing the load). | Low | Probed: all 4 loads have exactly **one** use each (§1.3), so there is no second edge to miss; and the assertion re-checks this at every extraction, not just today. |
| R6 | **Scope creep into memmove.** The bead is 3 lines from a much bigger one. | Med | Exit criterion §8 names memmove as the expected *new* wall and pins it in gate (I). Landing on memmove is **success**, not incompleteness. |
| R7 | **The census-vs-regex argument gets re-litigated** by a later agent annoyed by R1. | Low | §3.4 pre-commits: relaxing to `^jl_[a-z_]+_exception$` is sound *given the assertion* and is a one-line follow-up. Documented, so it is a decision rather than a rediscovery. |
| R8 | **`ptr_cells` family regression** (the u2kk class: a shared-handler change moves an unrelated callee's wall). | Med | §7.4 mandates the full family re-run with reported counts; gate counts pinned at 39/39. Residual: a *frontier advance* in another test is a legitimate update, not a weakening — report it explicitly (the lbot/u2kk convention). |

---

## 10. Probe artefacts

| Path | Contents |
| --- | --- |
| `scratchpad/d3A_probe1.jl` | wall repro at both gates; module global census + per-global use census |
| `scratchpad/d3A_probe2.jl` | per-function dead-block set; every `GlobalVariable` load with full use list + throw-family classification; guards into dead blocks |
| `scratchpad/d3A_probe3.jl` | textual fix simulation; next-wall determination for the closure and for all 6 closed-world callees |
| `scratchpad/d3A_probe4.jl` | the 4 hand-written `.ll` fixtures (A/B/C/D) × both gates — the measured RED baseline |
| `scratchpad/d3A_probe5.jl` | the measured GREEN ParsedIR target for fixture A at both gates |
| `scratchpad/d3A_growend.ll` | the raw 28 KB `_growend!` closure module (50 blocks) |
| `scratchpad/d3A_growend_fixed.ll` | the same module with the 4 loads removed |
