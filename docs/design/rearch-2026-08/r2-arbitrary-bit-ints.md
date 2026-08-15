# Native Arbitrary-Bit-Width Integers in Julia — State of the Art, August 2026

## Bottom line up front

The maintainer heard right, but the timeline needs a correction: **native
non-byte-multiple ("odd-bit") primitive integer types have landed on
`master`, but landed *after* Julia 1.13 branched, so they are NOT in
1.13.0 (currently at rc3) — they will first ship in 1.14.** And even on
`master` today, the feature is explicitly flagged upstream as
"preliminary" and "not quite safe to use yet," with a second PR still open
and unmerged as of this writing (2026-08-14) fixing a real memory-safety
bug (uninitialized/garbage high bits) in the very feature being described.

The core PR is **JuliaLang/julia#61359**, "core: support odd-bit primitive
integers, add `Core.bitsizeof`," authored by Max Horn (`fingolfin`) with
Codex/GPT assistance, merged into `master` **2026-07-21**. It:

- removes the `(nb & 7) != 0` restriction in `jl_f__primitivetype` (the C
  function backing the `primitive type «name» «bits» end` syntax) — you
  can now write `primitive type UInt2 2 end` and `primitive type Int63
  <: Signed 63 end` without an error;
- adds `Core.bitsizeof(T)` as the public API for querying the *logical*
  bit width, distinct from `sizeof(T)` (byte-rounded storage size);
- changes `bitstype_to_llvm` (`src/cgutils.cpp`) to emit a genuine LLVM
  `iN` type for `N` = the *logical* width, not the byte-rounded storage
  width — confirmed in the PR's own test suite by grepping compiled LLVM
  IR for `\bi63\b` after `code_llvm` on a `UInt63`-typed identity
  function;
- keeps in-memory storage byte-rounded (`jl_datatype_size` rounds up to
  whole bytes) and adds bit-level masking/zero-extension logic throughout
  egality, hashing, `show`, `bitstring`, `reinterpret`, and the C-ABI
  integer intrinsics dispatch tables so the byte-rounded storage and the
  logical LLVM register width don't silently disagree.

This resolves the multi-year-old tracking request in
**JuliaLang/julia#45486** ("Support arbitrary bitwidth integers," opened
2022-05-27, still open — #61359 is explicitly filed as "partial
progress" on it, not closure) and the more recent focused discussion in
**Discourse "N-bit Integers in Julia"** (2026), where `mkitti` proposed
exactly the mechanism that shipped: stealing 3 bits from
`jl_datatype_layout_t`'s padding field to record `unused_bits`.

A second, still-open PR, **JuliaLang/julia#62492** ("codegen: Apply
odd-bit storage widths consistently," opened 2026-07-23, last updated
2026-08-14, unmerged), fixes a bug where `load i17` from memory does not
mask the unused high bits, so values written by C or left uninitialized
carry garbage above the logical bit boundary. Its author list —
`Codex`, `Claude Fable 5`, and `Claude Opus 5` — indicates this is
itself AI-assisted, ongoing work, not a finished feature. This PR
addresses item (1) of the tracking issue below.

The umbrella tracking issue is **JuliaLang/julia#62441** ("Tracking
issue for non-byte-multiple integer support," opened 2026-07-21,
immediately after #61359 merged), which lists explicitly what is *not*
yet done:

1. Consistent codegen policy for storage-size vs. allocation-size vs.
   register-size (addressed, not yet merged, by #62492).
2. Atomics — "many assertions ... are broken for odd-bit integers,"
   blocked on a companion issue (#61361, below) about whether allocation
   size should equal storage size.
3. **Arithmetic and bit-manipulation intrinsics need test coverage and
   probably implementation changes, if/when we move beyond
   "storage-only" support.** This is the big one for a reversible-circuit
   compiler: #61359's own test suite exercises `trunc_int`, `zext_int`,
   `sext_int`, `bitcast`, float conversions, equality, hashing, `Ref`,
   and struct-field storage of odd-bit types — but **not** `add_int`,
   `sub_int`, `mul_int`, `icmp`-family comparisons, or bitwise
   AND/OR/XOR/shift on a genuinely odd bit width. The one arithmetic-ish
   test added (`compiled_conv` / `compiled_addi`) only covers
   sign/zero-extending *conversions*, not native odd-width arithmetic.
4. A pre-existing, related unsoundness in how `Bool` is declared
   (`primitive type Bool 8 end` in source, but always codegen'd as LLVM
   `i1`) causes crashes today (`Unreachable reached` / illegal
   instruction) when the two representations are round-tripped through
   `trunc_int` — flagged in #62441 as still-open cleanup work, and a
   direct illustration of exactly the "storage width vs. value width"
   conflation problem this whole effort is trying to solve generally.

A closely related, currently-**unresolved** design question is
**JuliaLang/julia#61361** ("Consider making size of non-power-of-two
primitive types always aligned," opened 2026-03-18). It proposes making
`Core.sizeof(T) == Base.aligned_sizeof(T)` always (i.e., collapsing the
"storage size" and "allocation size" notions the way C23 does), which
would change padding/alignment behavior for every non-power-of-two
primitive, including the already-merged odd-bit ones. Julia core dev
JeffBezanson's triage comment (2026-06-18): *"Triage is ... aligned with
this. Good to do whatever C does."* — so this is a stated future
direction, not yet implemented, and its resolution could still change
low-level details of how odd-bit ints are stored (though not the
already-shipped `iN` register-width behavior).

## The "multiple of 8" restriction — before and after

Before #61359, `jl_f__primitivetype` in `src/builtins.c` enforced:

```c
if (nb < 1 || nb >= (1 << 23) || (nb & 7) != 0)
    jl_errorf("invalid number of bits in primitive type %s", ...);
```

`primitive type UInt2 2 end` raised `invalid number of bits`. Packages
like BitIntegers.jl (below) could define arbitrarily *wide* multiples of
8 (`Int256`, `UInt512`, ...) but had no path around the sub-byte wall,
because the restriction lived in the runtime's `primitive type`
constructor itself, not in any library-level check.

After #61359, the check is just `nb < 1 || nb >= (1 << 23)` — any bit
count from 1 to ~8 million is accepted. `src/julia.h`'s
`jl_datatype_layout_t` gained a 3-bit `unused_bits` field (carved out of
what used to be an unconditional 8-bit `padding` field) recording how
many of the trailing storage bits are unused:

```c
uint16_t unused_bits : 3;
uint16_t padding : 5;
```

and two new accessors:

```c
STATIC_INLINE uint32_t jl_datatype_unusedbits(jl_datatype_t *t);
STATIC_INLINE uint32_t jl_datatype_nbits(jl_datatype_t *t) {
    return layout->size * 8 - layout->flags.unused_bits;
}
```

`jl_datatype_nbits` used to be a macro equal to `sizeof(t)*8` (i.e., pure
storage width); it is now the *logical* width, and it is what
`bitstype_to_llvm` feeds into `Type::getIntNTy(ctxt, nb)`. This is the
single line that makes register values genuinely native `iN` LLVM types
rather than byte-rounded `i8`/`i16`/... containers with manual masking.

## Storage width vs. value width — the precise contract

This is the exact question the task asked to pin down, and #61361's
issue body states it as cleanly as the upstream project has stated it
anywhere, borrowing LLVM's own three-way vocabulary:

| Notion | Julia API | LLVM equivalent | For `primitive type X 17 end` |
|---|---|---|---|
| storage size | `Core.sizeof(X)` | `getTypeStoreSize()` | 3 bytes (24 bits) |
| allocation size | `Base.aligned_sizeof(X)` | `getTypeAllocSize()` | 4 bytes (32 bits, alignment-rounded) |
| packed/logical bit size | `Core.bitsizeof(X)` | `getTypeSizeInBits()` | 17 bits |

- **In memory** (struct fields, `Array`/`Memory` elements, `Ref`,
  `unsafe_load`/`unsafe_store!`): byte-rounded storage, currently to
  `Core.sizeof`, i.e. `ceil(bits/8)` bytes, *not* further rounded to a
  power of two or to `aligned_sizeof` — #61361 is an open proposal to
  change this, unresolved as of this report.
- **In an LLVM register / SSA value** (arguments, return values,
  intermediate computation results as extracted via `code_llvm`):
  genuinely `iN` with `N` = the declared logical width. Confirmed
  directly: the PR's test does
  `ir = sprint(code_llvm, id_u63, Tuple{UInt63})` and asserts
  `occursin(r"\bi63\b", ir)`.
- **Sign/zero extension at the storage↔register boundary**: `trunc_int`,
  `zext_int`, `sext_int` all operate correctly against the logical
  width today (well-tested in #61359). Loading a register value *from*
  memory and getting the unused high bits correctly masked is the bug
  #62492 is still fixing as of 2026-08-14.
- **Arithmetic** (`add_int`, `mul_int`, `icmp`, bitwise ops, shifts) on a
  genuinely odd-bit-width register: *not yet covered by tests*, and the
  runtime (interpreter-path) C intrinsics in `src/runtime_intrinsics.c`
  were changed to explicitly special-case this — `select_intrinsic_1`
  and friends now check `runtime_nbits == sz * host_char_bit` and, if
  the width isn't one of the standard power-of-two byte sizes, fall back
  to `list[0]`, a generic/slow path, rather than a size-specialized fast
  path. Whether the *compiled* (non-interpreted) codegen path
  (`emit_intrinsic` in `intrinsics.cpp`) emits genuinely native
  `add i17 %a, %b` LLVM instructions for arithmetic the way it does for
  `code_llvm` on a bare identity/bitcast function is not directly tested
  in the merged PR and should be treated as unverified, not merely
  "probably fine."

## Is any of this in Julia 1.13?

No. Confirmed by direct git ancestry check against the real
`JuliaLang/julia` repository:

- `release-1.13`'s `VERSION` file reads `1.13.0-rc3` (tag `v1.13.0-rc3`
  exists; `v1.13.0-rc1/rc2/rc3` and betas/alphas precede it).
- `master`'s `VERSION` file reads `1.14.0-DEV` — i.e., 1.13 has already
  branched off and master has moved on to the next cycle.
- `git compare release-1.13...<merge-commit-of-#61359>` reports
  `"status": "diverged"` (not `"ahead"`), meaning the odd-bit-primitive
  commits are **not** an ancestor of `release-1.13` — they were never
  backported.
- No backport-labeled PR or issue reference to #61359 targeting
  `release-1.13` was found via GitHub search.

So: this machine's installed Julia 1.12.5 obviously doesn't have it
(pre-dates it by a full cycle); the imminent Julia 1.13 release (rc3 as
of this report, so GA is likely weeks away) also will not have it; the
earliest a stable release could ship it is **Julia 1.14**, and even then
only if the outstanding correctness work (#62492, plus arithmetic
coverage and the atomics/#61361 alignment question from #62441) lands
and is judged production-ready by the 1.14 feature freeze. Nothing found
in this research gives a committed 1.14 date.

## JuliaCon 2026 talk

JuliaCon Global 2026 ran in Mainz, Germany, with talks 12–14 August 2026
— i.e., in the days immediately before this report. This lines up
exactly with the maintainer's "I heard at JuliaCon 2026 that this is
coming" recollection, and #61359 (merged 2026-07-21, three weeks before
the conference) is almost certainly the concrete work being referenced —
its author, Max Horn, is an active core-team-adjacent contributor and a
plausible speaker/hallway-track source for that claim. However, this
report was **not able to locate a specific talk title, recording, or
abstract** confirming a JuliaCon 2026 session on this topic via web
search or the pretalx schedule page (which did not return indexed
session content). Treat "presented as a talk at JuliaCon 2026" as
plausible-but-unconfirmed; treat "the underlying work exists, is real,
and is merged to master" as fully confirmed via the primary-source PR
above.

## BitIntegers.jl — not the same problem, still separately alive

`BitIntegers.jl` (rfourquet) is the established fallback for
*wide* fixed-width integers beyond `Int128`/`UInt128` — it ships
`Int256`/`UInt256`/`Int512`/`UInt512`/`Int1024`/`UInt1024` plus a
`@define_integers` macro for custom *byte-multiple* widths. It has
never needed the `(nb & 7) != 0` relaxation because it only ever
declares byte-multiple primitives; that restriction only ever blocked
the *narrow*, sub-byte end of the spectrum, which BitIntegers.jl doesn't
address at all. It remains actively maintained (repository not
archived, most recent commits January 2026, including a 2026-01-07 fix
and Julia-1.13 compatibility fixes from December 2025 removing a
`Base.GMP.ispos` call that 1.13 deleted) — but it is orthogonal, not a
competing or overlapping solution for `Int2`/`UInt6`-style narrow types.
No sub-byte-width fallback package equivalent to BitIntegers.jl was
found; the sub-byte gap has, until #61359, only been worked around
inside individual projects like Bennett.jl itself.

## What `src/narrow.jl` does today, precisely

Read directly from the repository
(`/home/tobias/Projects/Bennett.jl/src/narrow.jl`, Bennett-19g6):
`_narrow_ir(parsed::ParsedIR, W::Int)` is a post-extraction
**ParsedIR-rewriting pass**. It does not touch Julia's type system or
LLVM codegen at all — it runs *after* `extract_parsed_ir` has already
produced a `ParsedIR` for a function written against, e.g., `Int8`
arguments, and mechanically substitutes `W` for every occurrence of a
bit-width field across every `IRInst` subtype (`IRBinOp`, `IRICmp`,
`IRSelect`, `IRCast`, `IRRet`, `IRPhi`, `IRInsertValue`,
`IRExtractValue`, `IRStore`, `IRAlloca`, plus deliberate no-ops for
`IRCall`, `IRBranch`, `IRPtrOffset`). It is invoked from
`reversible_compile(f, T; bit_width=W)` in `src/Bennett.jl` (line ~379):
when `bit_width > 0`, the extracted `Int8`-shaped `ParsedIR` is narrowed
to `W` bits (validated to `1 <= W <= 64`) *before* being handed to
`lower()`. In other words: **Bennett.jl today has no way to make Julia
itself emit native `i2`/`i4`/`i17`-typed LLVM IR, so it fakes narrow
widths by extracting ordinary `i8` (or whatever) IR and then relabeling
every width field in the parsed representation, trusting that the
lowering/simulation stages only ever consult the declared width field
and never re-derive it from LLVM's actual type.** This is a real,
load-bearing but fragile assumption: every new `IRInst` subtype added to
`ir_types.jl` needs a matching `_narrow_inst` method or the fail-loud
fallback (`Bennett-2unc`) crashes with a clear error rather than
silently miscompiling — which is exactly the CLAUDE.md rule-1 "fail
fast" discipline applied to this specific gap. The file's comments also
show Bennett has *already* independently rediscovered the "logical vs.
numeric width" distinction that Julia core is wrestling with for `Bool`
(#62441 item 4): every narrowing method explicitly guards
`inst.width > 1 ? W : 1` so that `i1` boolean/comparison results are
never widened to `W` bits, because their width is logical (a truth
value) rather than a numeric magnitude.

## Relevance to Bennett.jl

**If/when odd-bit primitives are both (a) shipped in a stable Julia the
project targets, and (b) hardened past the current "preliminary, not
safe" state** (arithmetic-intrinsic test coverage, #62492 merged, the
#61361 alignment question settled), a from-scratch Bennett built on that
Julia could, in principle, let a user write:

```julia
primitive type UInt2 <: Unsigned 2 end
f(x::UInt2) = ...
```

and get *genuinely* `i2`-typed LLVM IR straight out of
`extract_parsed_ir`, eliminating `src/narrow.jl` and the `bit_width`
kwarg entirely — narrowing would be something Julia's own compiler does
for you as part of ordinary code generation, rather than a
post-extraction IR-rewriting pass Bennett maintains and must keep in
sync with every new `IRInst` variant. This is a real simplification, and
it is exactly the shape of "code generation is free" the maintainer is
evaluating. Some concrete design consequences worth weighing explicitly,
based on what's actually shipped vs. still open:

1. **Arithmetic correctness on odd widths is the load-bearing unknown.**
   Bennett's entire value proposition is lowering *arithmetic and
   bitwise* instructions to gates. The upstream PR has tested storage,
   conversion, and bit-extraction primitives on odd widths thoroughly,
   but explicitly has not yet tested (and flags as "probably needs
   implementation changes") `add_int`/`sub_int`/`mul_int`/`icmp`/shift
   intrinsics at odd bit widths. Before betting a rewrite on this,
   Bennett would need to independently verify — with the same
   fail-fast, exhaustive-verification discipline CLAUDE.md already
   mandates for soft-float — that e.g. `add_int(x::UInt6, y::UInt6)`
   produces correct wraparound LLVM IR (`add i6`, masked/truncated
   correctly) across all 2^6 × 2^6 inputs, not just that it compiles.
2. **`_narrow_ir` doesn't disappear immediately even if native narrow
   ints ship — it becomes optional.** Existing Bennett call sites that
   compile *ordinary* `Int8`/`Int16`/... functions "as if" narrower
   (the documented `bit_width` use case: reusing an `Int8`-typed
   function body at `UInt4` semantics without rewriting the source) are
   a genuinely different feature from "the user wrote `UInt4` in their
   type annotation." Native odd-bit primitives serve the latter, not
   automatically the former — `_narrow_ir`-style reinterpretation of an
   existing function's width might still be wanted as a distinct,
   smaller utility even in a from-scratch design.
3. **Storage-vs-register split is Bennett's problem too, not just
   Julia's.** Bennett's simulator/gate-lowering operates on *logical*
   bit widths (wires), matching `Core.bitsizeof`'s notion, not
   `sizeof`'s. That's good alignment. But anywhere Bennett's extraction
   pipeline touches memory-shaped IR (`IRAlloca`, `IRStore`, `IRLoad`,
   the `src/extract/heap.jl` / `memssa.jl` / `softmem.jl` machinery)
   would need to track Julia's *storage* rounding explicitly to avoid
   silently reading/writing padding bits that native odd-bit primitives
   leave uninitialized garbage in — precisely the bug class #62492 is
   still chasing upstream. A from-scratch reimplementation gets to
   *inherit* that bug class from upstream rather than invent its own
   version of it, which is a real but double-edged simplification: fixed
   for free once Julia fixes it, broken for free until Julia fixes it.
4. **Bool's `i1`-vs-`primitive type Bool 8` inconsistency (#62441 item
   4) is a preview of a class of bug Bennett must not import
   uncritically.** Bennett's `narrow.jl` already encodes exactly this
   distinction correctly (logical `i1` widths guarded separately from
   numeric widths) — a useful design precedent to carry forward
   independent of what upstream Julia eventually does with `Bool`.
5. **Timeline for the from-scratch bet.** Given (a) not in 1.13, (b)
   `master`/1.14-dev only, (c) explicitly "preliminary... not safe to
   use yet" per the feature's own tracking issue, and (d) a
   still-unmerged correctness PR as of 2026-08-14 — betting the
   from-scratch rewrite's core representation on native odd-bit
   primitives today would mean building against a moving, admittedly
   unstable target with no committed ship date, on a Julia version
   (1.14) this project isn't yet running. A defensible middle path: keep
   `src/narrow.jl`'s IR-rewriting approach (it works, it's Bennett-owned,
   it fails loud on gaps) as the width-narrowing mechanism for the
   near-to-mid term, while tracking #62441/#62492/#61361 for the point
   at which arithmetic-on-odd-widths is both merged and covered by
   upstream tests — that is the concrete, checkable signal to revisit
   this decision, rather than "1.14 ships" alone.

## Sources

- Issue: [JuliaLang/julia#45486 — Support arbitrary bitwidth integers](https://github.com/JuliaLang/julia/issues/45486) (opened 2022-05-27, open)
- PR (**MERGED to `master`/1.14-dev, 2026-07-21**): [JuliaLang/julia#61359 — core: support odd-bit primitive integers, add Core.bitsizeof](https://github.com/JuliaLang/julia/pull/61359)
- Tracking issue (**open**, lists unfinished work): [JuliaLang/julia#62441 — Tracking issue for non-byte-multiple integer support](https://github.com/JuliaLang/julia/issues/62441)
- PR (**open, unmerged as of 2026-08-14**, fixes a memory-safety bug in the merged feature): [JuliaLang/julia#62492 — codegen: Apply odd-bit storage widths consistently](https://github.com/JuliaLang/julia/pull/62492)
- Issue (**open**, unresolved design question, triage-agreed direction but not implemented): [JuliaLang/julia#61361 — Consider making size of non-power-of-two primitive types always aligned](https://github.com/JuliaLang/julia/issues/61361)
- Discourse: [N-bit Integers in Julia](https://discourse.julialang.org/t/n-bit-integers-in-julia/94861)
- Discourse (older): [Arbitrary Bit Width Integers](https://discourse.julialang.org/t/arbitrary-bit-width-integers/22499)
- Discourse (older): [Not possible to define primitive types with 8 bits or less?](https://discourse.julialang.org/t/not-possible-to-define-primitive-types-with-8-bits-or-less/16378)
- Discourse (older): [Primitive type with 2 bits](https://discourse.julialang.org/t/primitive-type-with-2-bits/85095)
- Related issue: [JuliaLang/julia#26026 — Something is wrong with arrays of weird-length primitives](https://github.com/JuliaLang/julia/issues/26026)
- Related issue: [JuliaLang/julia#49318 — Inconsistent claims about padding in structs](https://github.com/JuliaLang/julia/issues/49318)
- Package: [rfourquet/BitIntegers.jl](https://github.com/rfourquet/BitIntegers.jl) — active, wide (>128-bit, byte-multiple) fixed-width integers; not a narrow/sub-byte solution
- Package (related, not a sub-byte solution): [rfourquet/BitIntegers2.jl](https://github.com/rfourquet/BitIntegers2.jl)
- `docs.julialang.org` manual: [Integers and Floating-Point Numbers](https://docs.julialang.org/en/v1/manual/integers-and-floating-point-numbers/), [Types](https://docs.julialang.org/en/v1/manual/types/) (current manual text; PR #61359 changes the `primitive type` section's wording once released)
- JuliaCon 2026 conference (Mainz, Germany, 12–14 Aug 2026): [juliacon.org/2026](https://juliacon.org/2026/), [schedule](https://juliacon.org/2026/schedule/) — no specific talk on this topic was located via search
- Local verification: `git ls-remote`/`gh api compare` against `JuliaLang/julia` `release-1.13` (VERSION `1.13.0-rc3`) vs. `master` (VERSION `1.14.0-DEV`) and the #61359 merge commit, confirming divergence (not ancestry) — i.e., **not present in 1.13**
- Local file read: `/home/tobias/Projects/Bennett.jl/src/narrow.jl` (Bennett-19g6, `_narrow_ir`/`_narrow_inst`)
