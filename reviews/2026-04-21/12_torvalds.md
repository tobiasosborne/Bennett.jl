# Linus Reviews Bennett.jl — 2026-04-21

Reviewer voice: Linus Torvalds. Second pass on this codebase. The last
one was 2026-04-11 (`reviews/05_torvalds_review.md`); ten days later the
tree has grown from ~5.6k LOC to **23k**. Most of the complaints from
the last review are still true, except now the files are bigger.

---

## Alright, so I looked at this thing...

Look, I want to be clear. Compiling pure Julia down to a NOT/CNOT/Toffoli
network via Bennett's 1973 construction is a genuinely hard problem, and
the core idea — extract LLVM IR, walk it with the C API, lower each
instruction to reversible gates, then sandwich it between forward /
copy / reverse — is correct and mostly clean at its heart. `bennett()`
in `src/bennett_transform.jl` is 49 lines and does exactly what it says
on the tin. `gates.jl` is 40 lines of dumb value types. `simulator.jl`
is 68 lines. If everything in this repo looked like those three files,
I would have nothing to complain about.

The problem is the stuff on either side of that core. `ir_extract.jl`
is **2394 lines**. `lower.jl` is **2662 lines**. A single function —
`_convert_instruction` — is **648 lines** of straight-line
`if opc == LLVM.API.LLVMWhatever ... elseif ... elseif ...`. That's
not a "compiler" function. That's a symptom of nobody ever having been
told "no" when they opened a PR. And the WORKLOG.md is **8193 lines**,
which is its own kind of cry for help — if your institutional memory
lives in an 8k-line append-only journal, your code isn't documenting
itself.

What I see is classic AI-agent incremental growth. Every feature got
its own "M1 Bennett-cc0 parametric MUX EXCH" tag and a paragraph of
comments in the source. Nobody ever goes back and deletes. Dead
functions stay. Legacy algorithms live next to their replacements,
marked `# ---- legacy ----`, and just sit there. Backward-compat
constructors pile up. The `LoweringCtx` struct has THREE constructor
overloads, and the main one takes **14 positional arguments**. That's
not API design; that's fossil record.

Let me get into specifics.

---

## THE GOOD

### 1. `src/bennett_transform.jl` — this is what I want to see
49 lines. Exactly two public entry points. The forward-copy-reverse
construction is transparent:

```julia
append!(all_gates, lr.gates)
for (i, w) in enumerate(lr.output_wires)
    push!(all_gates, CNOTGate(w, copy_wires[i]))
end
for i in length(lr.gates):-1:1
    push!(all_gates, lr.gates[i])
end
```

I can audit this by eye. The `self_reversing` shortcut (line 27) is a
legitimate optimization with an obvious invariant ("sequence already
cleans up"). No ceremony, no abstraction tax. This is what the rest of
the codebase should aspire to.

### 2. `gates.jl` / `simulator.jl` — data structures done right
Three concrete gate types: `NOTGate(target)`, `CNOTGate(control, target)`,
`ToffoliGate(control1, control2, target)`. No abstract method hierarchy.
No visitor pattern. The simulator is three `@inline apply!` methods and
a loop. Ancilla-not-zero is an **error**, not a warning. Somebody
understood the data before they wrote the code.

### 3. Branchless soft-float is architecturally right
`src/softfloat/fadd.jl` and friends commit to `ifelse` all the way
down, because branches would create phi nodes, and phi nodes are the
project's biggest landmine. The comment at `fadd.jl:6-11` actually
explains WHY, citing "false-path sensitization" — you learned something
from the VLSI verification literature, and you propagated that design
choice through the library. Credit where due.

### 4. Exhaustive input testing on small functions
`test_increment.jl` tests all 256 inputs for an i8 function. Not a
sampled 20. Not "representative cases". All 256. `verify_reversibility`
actually runs the circuit and checks ancillae are zero. For a project
that prints gate counts like marketing figures, the fact that the
fundamental correctness invariant is *actually tested* on every
circuit puts you ahead of most compiler projects I've ever
touched.

### 5. The gate-count regression baselines
CLAUDE.md rule 6: "Gate counts are regression baselines." Verified
counts (`i8 add = 86`, `i16 = 174`, `i32 = 350`, `i64 = 702` — exactly
2× per width doubling) act as canaries. This is the right instinct —
any optimization that "improves" those numbers without the PR author
explaining why is suspect. More projects should think this way.

---

## THE BAD

### B1. `_convert_instruction` is 648 lines of elseif

**File:** `src/ir_extract.jl:1086-1733`

Let me count. `_convert_instruction` starts at line 1086 and ends at
line 1734. That's **648 contiguous lines** of:

```julia
if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, ...) ... end
if opc == LLVM.API.LLVMICmp ... end
if opc == LLVM.API.LLVMSelect ... end
...
if opc == LLVM.API.LLVMCall
    ...
    if startswith(cname, "llvm.umax") ...
    if startswith(cname, "llvm.umin") ...
    if startswith(cname, "llvm.smax") ...
    if startswith(cname, "llvm.smin") ...
    if startswith(cname, "llvm.abs") ...
    if startswith(cname, "llvm.ctpop") ...  # 20-line expansion
    if startswith(cname, "llvm.ctlz") ...   # 20-line expansion
    if startswith(cname, "llvm.cttz") ...   # 20-line expansion
    if startswith(cname, "llvm.bitreverse") ...  # 16-line expansion
    if startswith(cname, "llvm.bswap") ...       # 18-line expansion
    if startswith(cname, "llvm.fshl") ... if startswith(cname, "llvm.fshr") ...
    ... (18 more intrinsics)
```

WHY THE HELL IS THIS LIKE THIS? This is a dispatch table pretending
to be control flow. There's a `const _OPCODE_MAP` already at line
2378 — you know about tables, you've used them elsewhere. Each
intrinsic should be a tiny named function; the call-site dispatcher
should be ~20 lines of lookup-then-call. Right now, to add a new
intrinsic you have to open a 2400-line file and search for the right
place in a 648-line `if`-chain. Good luck bisecting a regression
across three such additions — `git blame` tells you "it was in that
function", thanks.

And the per-intrinsic expansions are copy-pasted. `ctpop`, `ctlz`,
`cttz`, `bitreverse`, `bswap`, `fshl`, `fshr` all share the same
"unpack to wires, build a chain of IRBinOp, return a vector" pattern,
and they all re-implement it slightly differently. Pull it apart.

### B2. `lower.jl` has grown to 2662 lines — it's a compiler in a mason jar

**File:** `src/lower.jl`

Ten days ago this file was 1420 lines. Now it's 2662. It still does
everything: operand resolution, SSA liveness, topological sort, loop
unrolling, path-predicate computation, **two** phi-resolution
algorithms (see B3), all binary ops, icmp, shifts, casts, selects,
aggregate ops, pointer provenance, four memory strategies, call
inlining, constant folding, and division via soft-integer calls.

The file is what happens when `git log --follow` on a single path
shows 40+ distinct features. The proper answer is to split:
`lower_core.jl` (dispatch + CFG), `lower_arith.jl`, `lower_memory.jl`,
`lower_phi.jl`, `lower_call.jl`. You already have `adder.jl`,
`multiplier.jl`, `qcla.jl` as separate files; apply that discipline
here.

### B3. Dead code you are afraid to delete

**File:** `src/lower.jl:972-1060`

Four functions — `has_ancestor`, `on_branch_side`, `_is_on_side`,
`resolve_phi_muxes!` — are the LEGACY reachability-based phi
resolver. They're marked `# ---- phi resolution (legacy
reachability-based) ----` at line 926. They are **not called from
anywhere** except their own recursion. `lower_phi!` (line 928)
dispatches exclusively to `resolve_phi_predicated!` (line 905).

So there's ~90 lines of dead code in the most bug-prone region of the
codebase, sitting next to the live code, with the same function-name
prefix (`resolve_phi_*`) so grep-based navigation is ambiguous. The
previous Torvalds review (2026-04-11, `reviews/05_torvalds_review.md`
line 255) specifically called for removing it. It is still there. If
the reason is "we might need it again": you have git. Delete it.

### B4. `LoweringCtx` — 14 positional args, 3 constructors, 1 sentinel

**File:** `src/lower.jl:50-119`

```julia
struct LoweringCtx
    gates::Vector{ReversibleGate}
    wa::WireAllocator
    vw::Dict{Symbol,Vector{Int}}
    preds::Any            # typed Any because "any dict shape"
    branch_info::Any
    block_order::Any
    block_pred::Dict{Symbol,Vector{Int}}
    ssa_liveness::Dict{Symbol,Int}
    inst_counter::Ref{Int}
    use_karatsuba::Bool
    compact_calls::Bool
    alloca_info::Dict{Symbol, Tuple{Int,Int}}
    ptr_provenance::Dict{Symbol, Vector{PtrOrigin}}
    mux_counter::Ref{Int}
    globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}
    add::Symbol
    mul::Symbol
    entry_label::Symbol   # sentinel Symbol("") means "treat all as entry"
end
```

Three fields typed `Any` "because any dict shape from caller".
**That's not typing, that's giving up.** You have the exact types:
write them. `entry_label` uses the sentinel `Symbol("")` to mean "no
gating". That sentinel exists for one reason: you didn't want to
break the older `lower_block_insts!` callers. Classic deprecation
debt. Use `Union{Symbol, Nothing}` and force the callers to update,
or — better — split the struct into `LoweringCtx` and `MemCtx` so
that code paths that don't need memory state don't have to carry it.

The three constructors (7-arg, 12-arg, 13-arg, 14-arg overloads
via default args at lines 86-119) are a fossil of how features were
bolted on: T3b.3 added `alloca_info`/`ptr_provenance`, T1c.2 added
`globals`, D1 added `add`, P2 added `mul`, M2c added `entry_label`.
Every one of those commits added a backward-compat overload
instead of updating call sites. Now when a new contributor asks
"which constructor do I use?" the answer is "read the git log for
the last two months." Not OK.

### B5. `resolve!` silently ignores the `width` argument when the operand is SSA

**File:** `src/lower.jl:168-186`

```julia
function resolve!(..., op::IROperand, width::Int; ...)
    if op.kind == :ssa
        haskey(var_wires, op.name) || error("Undefined SSA variable: %$(op.name)")
        return var_wires[op.name]     # width parameter not used
    else
        wires = allocate!(wa, width)
        ...
    end
end
```

The caller passes `width`. If the operand is SSA, that width is
thrown away — you return whatever is in `var_wires[op.name]`,
whatever width that is. If the caller believed the wire vector
should be of length `width` and it isn't, that's a silent bug
waiting. For a project whose CLAUDE.md commandment #1 is "fail fast,
fail loud", a function with a parameter that's discarded on one of
two branches is the opposite. Either assert `length(var_wires[name]) == width`,
or don't take the parameter.

### B6. `LoweringResult` has two constructors because someone added a field

**File:** `src/lower.jl:36-47`

```julia
LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, constant_wires) =
    LoweringResult(..., constant_wires, GateGroup[], false)

LoweringResult(gates, n_wires, input_wires, output_wires,
               input_widths, output_elem_widths, constant_wires,
               gate_groups::Vector{GateGroup}) =
    LoweringResult(..., gate_groups, false)
```

The 7-arg form exists because old call sites didn't know about
`gate_groups`. The 8-arg form exists because old call sites didn't
know about `self_reversing`. **Update the call sites.** You have the
whole source tree. `grep -l LoweringResult\(` is 20 files max. Fix
them and delete the overloads.

### B7. `_lower_store_via_mux_*x*!` is code-generated **and** hand-written

**File:** `src/lower.jl:2453-2606`

Look at this. `_lower_store_via_mux_4x8!` is a hand-written 34-line
function at line 2453. `_lower_store_via_mux_8x8!` is a
hand-written 34-line function at line 2488. And then at line 2530
there is a metaprogramming block that `@eval`-generates
`_lower_load_via_mux_NxW!` and `_lower_store_via_mux_NxW!` for
`(N, W) ∈ [(2,8), (2,16), (4,16), (2,32)]`. The 4x8 and 8x8 cases
are **not** in that generator loop — they're hand-written twins.

So two shapes are manual. Five shapes are generated. And the two
bodies diverge in subtle ways (the generated version's error strings
differ from the hand-written ones). If you're going to metaprogram
this, put **all** shapes in the loop; if you're not, don't have the
loop at all. Right now a contributor adding `(8, 16)` has to decide
whether to follow pattern A or pattern B, and there is no signal to
pick right.

### B8. `ParsedIR.instructions` — the backward-compat ghost

**File:** `src/ir_types.jl:167-221`

`ParsedIR` has six real fields — `ret_width`, `args`, `blocks`,
`ret_elem_widths`, `globals`, `memssa` — and a SEVENTH field named
`_instructions_cache` that is *computed from `blocks`*, cached at
construction time, and exposed via a custom `Base.getproperty`
override so `parsed.instructions` continues to "work" for callers
who pre-date the basic-block model:

```julia
function Base.getproperty(p::ParsedIR, name::Symbol)
    if name === :instructions
        return getfield(p, :_instructions_cache)
    else
        return getfield(p, name)
    end
end
```

This is cargo-cult backward compatibility. The callers of
`parsed.instructions` either need the flat list (in which case they
should take it as a function: `all_insts(parsed)`) or they don't.
Caching the flat list inside the immutable struct, and then papering
over field access, means every `ParsedIR` pays memory for a redundant
denormalized view. And no, "it's an array of pointers, who cares" —
the real cost is that a reader has to understand that `.blocks` and
`.instructions` are *the same data two ways*, and if you ever
accidentally mutate one (Julia is permissive), the other is stale.
Kill it.

### B9. `_narrow_inst` is a case statement hiding as multiple dispatch

**File:** `src/Bennett.jl:139-160`

```julia
_narrow_inst(inst::IRBinOp, W::Int) = IRBinOp(inst.dest, inst.op, ...)
_narrow_inst(inst::IRICmp, W::Int) = IRICmp(inst.dest, ...)
_narrow_inst(inst::IRSelect, W::Int) = inst.width == 0 ? inst : ...
_narrow_inst(inst::IRCast, W::Int) = IRCast(inst.dest, ...)
...
_narrow_inst(inst::IRInst, W::Int) = inst   # fallback: pass through
```

And the logic is: "if width > 1, replace with W; otherwise keep i1".
Every single method. The same rule duplicated twelve times.

If this were a proper field-rewrite, you'd pattern-match over struct
fields: for each `::Int` field named `width`, `from_width`, `to_width`,
`elem_width`, apply the narrowing rule. Julia has `fieldnames`,
`getfield`, and a `reconstruct` pattern in Setfield.jl. What's here
instead is one line per IR type, in the TOP-LEVEL MODULE FILE, that
has to be touched every time you add a new IR instruction type. And
it's in `Bennett.jl` — the entry point everyone opens — not somewhere
with the rest of the IR code.

### B10. `_fold_constants` is a second-pass peephole optimizer written by someone who felt like writing one

**File:** `src/lower.jl:473-566`

93 lines of "if both CNOT controls are known constants, fold to NOT
or no-op; if one control of a Toffoli is known false, skip it;
otherwise propagate". The function exists. It has a kwarg to enable
it (`fold_constants=false` by default). It is **off by default**. No
test in `runtests.jl` depends on its output beyond `test_constant_fold.jl`
which just checks it doesn't crash.

The value proposition isn't documented. There is no benchmark showing
"with folding, circuit X is 20% smaller." The branch dropped in a
future-proofing gesture. If it's not on, it's not tested where it
matters, and if it's not worth a benchmark table, it's dead weight.
Either make it default, document the benefit, and test the counts —
or delete it.

### B11. Phi resolution is STILL the known-bug-prone region, and the review notes say it

**File:** `src/lower.jl:860-1060`, plus `CLAUDE.md:47-61`

CLAUDE.md has a section titled "**Phi Resolution and Control Flow —
CORRECTNESS RISK**". It describes a failure mode called "false-path
sensitization" that hit the v0.5 soft-float overflow bug. The file
fix (switch from reachability to path-predicates) is in — and yet
the reachability implementation is **still in the file**, 90 lines
of it, near-identically named. If a future contributor picks the
wrong function to extend, you're back to the bug.

WHY THE HELL IS THIS LIKE THIS? The data structure fix already
happened (`block_pred::Dict{Symbol,Vector{Int}}`). Complete the
migration. Delete `has_ancestor`, `on_branch_side`, `_is_on_side`,
`resolve_phi_muxes!`. File a beads issue to chase any external
caller (there are none in the repo) and close it.

### B12. Commit hygiene — "bd: sync dolt cache" is half your commits

**File:** `git log --oneline -60`

```
b17dd5c bd: sync dolt cache (post-push drift)
c655689 bd: sync dolt cache after Bennett-lmkb + Bennett-f2p9 close
fd02022 bd: sync dolt cache (post-push drift)
2f56969 bd: sync dolt cache after Bennett-cc0.6 close
b17b9a7 bd: sync dolt cache (post-push drift)
45799f4 bd: sync dolt cache after Bennett-cc0.4 close
b69926c bd: sync dolt cache (post-push drift, WORKLOG handoff)
```

About half of the last 60 commits are the beads issue tracker
committing its own database back into the tree. This is noise. It
pollutes `git log`, it makes `git blame` useless on any file that
co-exists with those commits' metadata, and it means the actual
substantive commits are drowning in bd bookkeeping. Put the dolt
cache in a separate repo, or `.gitignore` it, or at minimum squash
them into the Bennett-* commit they relate to. "bd: sync dolt cache
(post-push drift)" is not a commit message; it's a merge-hook
confession.

The substantive commit messages, on the other hand, are **fine** —
`Bennett-uyf9: auto-SROA canonicalises memcpy-form sret under
optimize=false` is exactly what I want: a task tag, a one-line
summary, and a condition. Keep those.

### B13. API stability — `reversible_compile` has accumulated 6 kwargs

**File:** `src/Bennett.jl:58-62`

```julia
function reversible_compile(f, arg_types::Type{<:Tuple};
                            optimize::Bool=true, max_loop_iterations::Int=0,
                            compact_calls::Bool=false, bit_width::Int=0,
                            add::Symbol=:auto, mul::Symbol=:auto,
                            strategy::Symbol=:auto)
```

Seven kwargs. The overload below for parsed IR takes four. The
Float64 one takes three. Each one exists because somebody needed to
turn on a feature in a specific test, and rather than expose the
knob at the test site (e.g. via a `LowerConfig` struct passed in),
it got promoted to a top-level kwarg. Now every caller sees a
shotgun blast of options and no guidance on which combinations are
tested together. Three years from now you'll hit a ticket of the
form "`add=:qcla, mul=:karatsuba, strategy=:tabulate` produces wrong
output" and nobody's ever run that combo. Define a `LowerConfig`
struct. Test known-good profiles. Stop the kwarg sprawl.

---

## THE UGLY

### U1. `src/persistent/hamt.jl` — the "branchless" HAMT that isn't

**File:** `src/persistent/hamt.jl:118-300`

Look at `hamt_pmap_set`. It is **one function of hundreds of lines**
that manually unrolls 8 slots, and for every slot j ∈ {0..7}
expresses the update-or-insert logic as:

```julia
# Slot 3
nk3_upd = ifelse(idx == UInt32(3), k_u, k3)
nk3_ins = ifelse(idx == UInt32(3), k_u, ifelse(idx < UInt32(3), k2, k3))
new_k3  = is_occupied * nk3_upd + is_new * nk3_ins

nv3_upd = ifelse(idx == UInt32(3), v_u, v3)
nv3_ins = ifelse(idx == UInt32(3), v_u, ifelse(idx < UInt32(3), v2, v3))
new_v3  = is_occupied * nv3_upd + is_new * nv3_ins
```

...times 8, by hand. For keys. Then again for values. With the same
pattern. And the reason is "we need it to be branchless so Bennett
can lower it, and `@inline` won't unroll a loop". Fine — but at
that point write a `@generated` function, or a macro, or use
`Base.Cartesian.@nexprs`. Don't copy-paste the same five lines 16
times with a single integer substitution and pretend it's
maintainable.

The README celebrates this module as proof that "linear_scan beats
CF at all scales" — great finding. But the *implementation* of the
losing contender is the kind of code you'd get if you asked a
contestant to write the fastest possible loop-unrolled version of a
hash table in a weekend. The winner (linear_scan) was 110 lines.
This file is 309 lines. That's not a benchmark fair to the data
structure — that's a benchmark fair to the amount of effort spent
on each.

### U2. The soft-float library is doing 128-bit arithmetic because you won't use UInt128

**File:** `src/softfloat/softfloat_common.jl:156-375`

200+ lines of `_sf_widemul_u64_to_128`, `_add128`, `_sub128`,
`_neg128`, `_shl128_by1`, `_shr128jam_by1`, `_shiftRightJam128`,
`_sf_clz128_to_hi_bit61`, all operating on `(hi::UInt64, lo::UInt64)`
pairs. Why? Because the comment (line 159-161) says:

> No UInt128 (emits `__udivti3` / `__umodti3` non-callee intrinsics).

So you can't use Julia's native `UInt128` because LLVM emits calls
to `compiler-rt` helpers your extractor doesn't know about. Fine.
But then **register `__udivti3` and `__umodti3` as callees**, or
write one soft function that handles them, and free yourself from a
hand-coded 128-bit library. The current approach puts you on the
hook for every 128-bit operation you ever need — including the
`_shiftRightJam128` that has a **branchless** case-A/case-B/case-C
dispatch because Julia's shift-count truncation at 64 is UB. That's
three layers of workaround for a problem whose real fix is "teach
the extractor about two new callees."

### U3. `_reset_names!()` is an empty function
**File:** `src/ir_extract.jl:255`

```julia
function _reset_names!() end
```

It does nothing. It exists. It's still exported-ish (file-scoped but
callable). The previous Torvalds review talked about global mutable
state for name generation. Somebody partially migrated away but left
the shell of the old API as a no-op so nothing breaks. That's worse
than leaving the old code — at least the old code would fail loudly
if state drift mattered. A no-op `_reset_names!()` is a landmine: if
somebody, somewhere, is still calling it expecting it to reset
state, they get silent success and silent bugs.

Either remove the function, or re-implement what the name suggests
if it's supposed to do something. A 0-line function definition is
not a solution.

---

## WHAT I'D RIP OUT

1. **`has_ancestor`, `on_branch_side`, `_is_on_side`, `resolve_phi_muxes!`** (`lower.jl:972-1060`) — dead legacy phi resolution, 90 lines, same filename as live code.

2. **`_fold_constants`** (`lower.jl:473-566`) — off-by-default peephole that isn't tested where it matters. Delete or promote.

3. **`ParsedIR._instructions_cache` + the custom `getproperty`** (`ir_types.jl:181-221`) — denormalized cache paying memory for API compat. Replace with a function.

4. **`_reset_names!() end`** (`ir_extract.jl:255`) — a no-op function.

5. **The seven backward-compat constructor overloads for `LoweringCtx` and `LoweringResult`** (`lower.jl:36-119`) — fossil record. Migrate call sites.

---

## WHAT I'D KEEP

1. **`bennett_transform.jl`** — short, obvious, correct. The `self_reversing` shortcut is a real optimization with a real invariant.

2. **The Cuccaro adder + `_pick_add_strategy`** (`adder.jl:30-80`, `lower.jl:1072-1078`) — cheap in-place variant gated on SSA liveness so it *only* fires when safe. This is how you do optional optimization right: no ceremony, explicit predicate, easy to audit.

3. **Branchless soft-float as a deliberate choice** (`softfloat/fadd.jl:6-15` header comment) — the author understood why `ifelse` matters for this pipeline and documented it at the top of the file. That's engineering discipline.

---

## Verdict

Would I merge this? **Not in its current shape as a single PR.** As
a snapshot of a research compiler that's actually producing correct
reversible circuits and meeting its published gate-count baselines,
it works, and the tests back it up. But I would require, before next
feature work:

1. Delete the dead phi-resolution path and its three helpers. This
   is ten minutes of work and immediately reduces cognitive load in
   the most bug-prone region (**B3, B11**).

2. Split `_convert_instruction` in `ir_extract.jl` into a dispatch
   table over opcode + a registry of per-intrinsic expanders. The
   648-line function is a dam waiting to break (**B1**).

3. Split `lower.jl` into at minimum three files along the lines
   already indicated by the `# ---- section ----` headers. The file
   is big enough that a 32-core LSP server is probably re-checking
   it on every keystroke (**B2**).

4. Kill the backward-compat constructor overloads. Migrate the call
   sites. One commit per type (**B4, B6**).

5. Stop committing the beads dolt cache in noise commits. Squash
   or separate repo (**B12**).

The core is good. The core is *provably* good — you test that. Now
prune the accumulated bark. A codebase this size, with two people
watching (let alone the N AI agents actually committing), will
collapse under its own backward-compat debt if you don't.

And get rid of that 8193-line WORKLOG.md. Knowledge that doesn't
live in code or tests isn't institutional memory — it's an archive
nobody reads.

