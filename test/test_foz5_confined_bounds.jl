# Bennett-foz5 / CW-D (xkl frontier wall 7) — the CONFINED-VALUE contract.
#
# ADR 0017 §4a (BennettVM.jl `docs/adr/0017-closed-world-execution.md`).
#
# WHAT THIS BEAD ADMITS. Julia's `@boundscheck` cluster under
# `--check-bounds=yes` for a CLOSURE-CAPTURED `MemoryRef` computes a pointer
# difference across the two halves of a SPLIT ref: the `.ptr_or_offset` half is
# read from the closure environment struct (`gep i8 %env, 56`), the `.mem` half
# from the GC-roots array (`gep i8 %roots, 16`). The two halves arrive through
# DIFFERENT function arguments with no SSA edge between them, so Bennett-583s's
# base-cancellation proof (which IS syntactic root equality) cannot apply and
# never will: the only in-body pairing witness is a DEAD `insertvalue` that
# survives solely because extraction runs at `optimize=false` (Rule 5).
#
# THE SECOND PROOF. `_foz5_confined_dead_bounds` proves the strictly weaker
# statement that the coerced value's ENTIRE influence on the program is a
# dead-throw branch condition:
#
#     ptrtoint --(every use)--> sub(ptrtoint, ptrtoint)
#              --(every use)--> icmp
#              --(i1 closure)--> and/or/xor
#              --(only)-------> conditional `br` with >= 1 successor in the
#                               Bennett-utzc pruned dead-block set
#
# so the value influences execution ONLY through a successor choice at a branch
# one of whose edges is the `:__unreachable__` halt sink. GUARANTEE: for every
# input on which NATIVE RETURNS A VALUE, the extracted program returns the same
# value or HALTS LOUDLY. Both unproven directions (a missed throw, a spurious
# halt) are stated in ADR 0017 §4a rather than hidden — see the (Q) banner.
#
# 583s KEEPS FIRST REFUSAL: the confinement disjunct is consulted only after
# `_verify_memdata_bounds_cluster` declines (`||` short-circuit), so every
# cluster 583s already proves is byte-identical. Gate (I) is that pin.
#
# Gate map:
#   (A)  GREEN  — the S1 corpus shape (split captured MemoryRef) extracts;
#                 BOTH ptrtoints lower to the `:or` cell identity.
#   (B)  RED    — no dead-throw sink (the false edge `ret`s). The premise pin:
#                 this is the gate that proves the confinement does the work.
#   (B2) GREEN  — INVERTED branch polarity (dead block is the TRUE edge). Pins
#                 that this contract is POLARITY-AGNOSTIC and does NOT depend
#                 on the `LLVM.successors(br)[2] == false-target` convention.
#   (C)  RED    — the coerced value ESCAPES (an extra `add` use).
#   (D)  RED    — the `sub` RESULT escapes (returned on the live edge).
#   (E)  RED    — the i1 feeds a `select` (a value leak, not a branch).
#   (F)  RED    — the i1 is `zext`ed to a value.
#   (G)  RED    — genuine cross-object difference that ESCAPES.
#   (H)  RED    — fixture (A) at `ptr_cells=false` still fails loud (gate off).
#   (N)  RED    — the source is a PointerType `phi` (the Bennett-cc0 M2b
#                 WIDTH-0 SENTINEL): NOT a certified materialised cell.
#   (HR1) RED   — HOSTILE D1 [reviewer C1/C2]: a `jl_global#N` SINGLETON-DATA
#   (HR2)         alias load, whose name is registered but which emits NO
#                 IRInst (external and defined spellings both).
#   (HR3) RED   — HOSTILE D2(a) [reviewer B1/C6]: the (N) refusal reached
#   (HR4)         through an interposed GEP, over a `phi` base and over a
#                 `select` base. ONE instruction bypassed it pre-fix.
#   (HR5) KNOWN — HOSTILE D2(b) [reviewer B2]: a LOAD through a sentinel-valued
#      ADMITTED   ADDRESS is still admitted. DELIBERATE scope boundary — the
#                 address question is the LOAD ARM's, not this predicate's.
#   (HR6) RED   — HOSTILE D3: a truncated i32 `sub` in the confined chain.
#   (Q)  GREEN  — CROSS_MEM_CONFINED: a genuinely cross-object difference that
#                 IS confined is ADMITTED BY DESIGN. A deliberate scope choice,
#                 gated rather than hidden.
#   (I)  INERT  — 583s's own `CLUSTER_OK` is unchanged (first refusal), and
#                 foz5 provably did NOT admit it (its false edge is a `ret`).
#   (O2) STEAL  — a source that is S1-shaped AND jbko-use-shaped stays jbko's.
#   (O3) STEAL  — the real corpus path never mentions the jbko `%L84` witness.
#   (O4) PIN    — the jbko `_memdata_root(src) === nothing` guard is still
#                 present and still redundant (foz5 introduced NO fall-through).
#   (W8) CORPUS — the real gated `push!` path clears wall 7 and advances to
#                 wall 8 (Bennett-bvmd).
#
# Rule 5: every fixture is hand-built and hermetic, and carries an explicit
# `target datalayout` (the test_7wsz / test_59zi / test_416r16 idiom) because
# the corpus shape is byte-offset-GEP based. Nothing is pinned by SSA NUMBER —
# those drift between processes (measured this session: `%94` vs `%98`).
#
# SUITE MODE: every per-file green claim must be under
# `julia --project --check-bounds=yes test/test_foz5_confined_bounds.jl`.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, ParsedIR, IRBinOp, IRICmp, IRLoad,
               ConstOperand, SSAOperand

const _FOZ5_DL = "target datalayout = \"e-p:64:64:64-i64:64-n8:16:32:64-S128\"\n"

# Every dead block needs a throw-family call: `_assert_dead_block_is_throw_skeleton`
# (`module_walk.jl:109`) REFUSES to prune an `unreachable` block that has a
# predecessor but no throw-family / `llvm.trap` call ("a SURPRISING unreachable
# block whose halt reason is unmodelled"). A bare `unreachable` fixture fails
# loud for the WRONG reason — cost one probe cycle to find.
const _FOZ5_DECL = "\ndeclare void @ijl_bounds_error_int(ptr, i64)\n"

# ---------------------------------------------------------------------------
# (A) The S1 corpus shape, distilled from `_growend!` `%idxend41`.
#
#   %mem   <- load (gep i8 %roots, 16)   ; the GC-roots-array half (.mem)
#   %d     <- load (gep i8 %env,   56)   ; the closure-env half (.ptr_or_offset)
#   %mdata <- load (gep {i64,ptr} %mem, 0, 1)   ; _memdata_root == %mem
#   %e     <- gep i8 %d, %bo                     ; _memdata_root == nothing
#   %s     = sub(ptrtoint %e, ptrtoint %mdata)   ; roots are DISJOINT
#   %c     = icmp ult %s, %bl ; %v = and %nov, %c ; br %v, %ok, %oob(unreachable)
#
# `%nov` mirrors the corpus's `xor i1 %memoryref_ovflw, true` sibling: an
# in-model i1 `and`ed with the confined one. The contract permits it (the
# confined value's influence is still only the successor choice).
# ---------------------------------------------------------------------------
const _FOZ5_A = _FOZ5_DL * """
define i64 @f(ptr %env, ptr %roots, i64 %off) {
top:
  %rg = getelementptr i8, ptr %roots, i32 16
  %mem = load ptr, ptr %rg
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %d = load ptr, ptr %eg
  %bo = mul i64 %off, 8
  %e = getelementptr i8, ptr %d, i64 %bo
  %mg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %mdata = load ptr, ptr %mg
  %b = ptrtoint ptr %mdata to i64
  %x = ptrtoint ptr %e to i64
  %s = sub i64 %x, %b
  %lg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 0
  %len = load i64, ptr %lg
  %bl = mul i64 %len, 8
  %c = icmp ult i64 %s, %bl
  %nov = icmp ult i64 %off, 1000
  %v = and i1 %nov, %c
  br i1 %v, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %mem, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# (B) RED — the false edge RETURNS instead of being an `unreachable` throw
# skeleton. Premise (iv) fails ⇒ the confined contract does not apply ⇒ the
# pre-existing 583s reject fires. THIS IS THE GATE THAT PROVES THE CONFINEMENT
# IS DOING THE WORK: without it, (A) would prove nothing.
const _FOZ5_B = replace(_FOZ5_A,
    "oob:\n  call void @ijl_bounds_error_int(ptr %mem, i64 %off)\n  unreachable" =>
    "oob:\n  ret i64 0")

# (B2) GREEN — INVERTED polarity: the dead block is the TRUE successor.
# Premise (iv) says "at least one successor in the dead set" — it does NOT read
# `successors(br)[2]`, so this is admitted. The gate is the permanent record
# that this contract carries no branch-successor-ordering dependency.
const _FOZ5_B2 = replace(_FOZ5_A,
    "br i1 %v, label %ok, label %oob" => "br i1 %v, label %oob, label %ok")

# (C) RED — the coerced value ESCAPES: `%x` additionally feeds an `add`.
# Premise (ii) fails for `%x`.
const _FOZ5_C = replace(_FOZ5_A,
    "  %s = sub i64 %x, %b\n" => "  %s = sub i64 %x, %b\n  %esc = add i64 %x, 7\n",
    "ok:\n  ret i64 %off" => "ok:\n  ret i64 %esc")

# (D) RED — the `sub` RESULT escapes (returned on the live edge). Premise (iii)
# fails. THIS IS THE PREDICATE LINE THAT KEEPS `test_583s` (5) CROSS_MEM RED:
# CROSS_MEM's `sub` is `ret`urned, so it fails premise (iii) exactly here.
const _FOZ5_D = replace(_FOZ5_A, "ok:\n  ret i64 %off" => "ok:\n  ret i64 %s")

# (E) RED — the i1 feeds a `select`: a VALUE leak, not a branch. `select` is
# outside the i1-algebra whitelist of premise (iv).
const _FOZ5_E = replace(_FOZ5_A,
    "  %v = and i1 %nov, %c\n" =>
    "  %v = and i1 %nov, %c\n  %sel = select i1 %c, i64 1, i64 2\n",
    "ok:\n  ret i64 %off" => "ok:\n  ret i64 %sel")

# (F) RED — the i1 is `zext`ed to an i64 value. Same leak, different spelling.
const _FOZ5_F = replace(_FOZ5_A,
    "  %v = and i1 %nov, %c\n" =>
    "  %v = and i1 %nov, %c\n  %z = zext i1 %c to i64\n",
    "ok:\n  ret i64 %off" => "ok:\n  ret i64 %z")

# (G) RED — a genuine cross-object difference (two DIFFERENT env pointers) that
# ESCAPES. Neither proof applies: roots differ (583s) and the value leaves the
# confined chain (foz5).
const _FOZ5_G = _FOZ5_DL * """
define i64 @g(ptr %envA, ptr %envB, i64 %off, i64 %len) {
top:
  %ga = getelementptr inbounds i8, ptr %envA, i32 56
  %da = load ptr, ptr %ga
  %gb = getelementptr inbounds i8, ptr %envB, i32 56
  %db_base = load ptr, ptr %gb
  %db = getelementptr i8, ptr %db_base, i64 %off
  %b = ptrtoint ptr %da to i64
  %x = ptrtoint ptr %db to i64
  %s = sub i64 %x, %b
  %c = icmp ult i64 %s, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %s
oob:
  call void @ijl_bounds_error_int(ptr %envA, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# (N) RED — the ptrtoint SOURCE is a PointerType `phi`. A pointer-typed
# `phi`/`select` carries the Bennett-cc0 M2b WIDTH-0 SENTINEL: its routing is
# recorded in `ptr_provenance` at LOWERING time rather than as a VALUE, so
# coercing one reads a cell that was NEVER MATERIALISED. Premise (i) — the
# certified-materialised-cell whitelist — is what refuses it. The confinement
# theorem caps the damage at a halt, but Rule 1 prefers a conservative loud
# reject to an unverified admission, and the sentinel is a SILENT miscompile
# class, so the whitelist is a POSITIVE test and never an "is a pointer" test.
const _FOZ5_N = _FOZ5_DL * """
define i64 @n(ptr %env, ptr %roots, i64 %off, i1 %p) {
top:
  %rg = getelementptr i8, ptr %roots, i32 16
  %mem = load ptr, ptr %rg
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %d = load ptr, ptr %eg
  %mg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %mdata = load ptr, ptr %mg
  br i1 %p, label %L1, label %L2
L1:
  br label %J
L2:
  br label %J
J:
  %ph = phi ptr [ %d, %L1 ], [ %mdata, %L2 ]
  %b = ptrtoint ptr %mdata to i64
  %x = ptrtoint ptr %ph to i64
  %s = sub i64 %x, %b
  %lg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 0
  %len = load i64, ptr %lg
  %c = icmp ult i64 %s, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %mem, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# ---------------------------------------------------------------------------
# HOSTILE-REVIEW FIXTURES (Bennett-foz5 review, defects D1 / D2 / D3). Each was
# ADMITTED before the fix; the reject / known-admit is now permanent.
# ---------------------------------------------------------------------------

# (HR1)/(HR2) RED [reviewer fixtures C1/C2] — `load ptr, ptr @"jl_global#N"`: the bennettvm-416r.13 /
# CW-D3 Lever 2 SINGLETON-DATA alias arm intercepts this shape, emits NO
# IRInst, and ALIASES the result name to the global symbol. It is registered in
# `names` but never materialised as a cell, and `_p06b_suppressed_refs` holds
# only sret boxes, so neither of (C0)'s registration checks catches it.
# MEASURED pre-fix: `IRBinOp(:b, :or, SSAOperand(Symbol("jl_global#77")),
# ConstOperand(0), 64)` — an `:or` cell identity over a GLOBAL BASE SYMBOL.
# Both the `external` and the defined spelling, because the two take different
# paths through `_extract_const_globals`.
const _FOZ5_HR1 = _FOZ5_DL * """
@"jl_global#77" = external constant ptr

define i64 @s(ptr %env, i64 %off, i64 %len) {
top:
  %g = load ptr, ptr @"jl_global#77"
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %dbase = load ptr, ptr %eg
  %d = getelementptr i8, ptr %dbase, i64 %off
  %b = ptrtoint ptr %g to i64
  %x = ptrtoint ptr %d to i64
  %s = sub i64 %x, %b
  %c = icmp ult i64 %s, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %env, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

const _FOZ5_HR2 = replace(_FOZ5_HR1,
    "@\"jl_global#77\" = external constant ptr" =>
    "@\"jl_global#77\" = constant ptr null")

# (HR3) RED [reviewer fixture B1] — a GEP interposed between a PointerType `phi` and the `ptrtoint`.
# ONE instruction bypassed the depth-0 sentinel refusal of gate (N) pre-fix.
# The GEP-base recursion in `_foz5_cert_src_kind` is what closes it.
const _FOZ5_HR3 = _FOZ5_DL * """
define i64 @n(ptr %env, ptr %roots, i64 %off, i1 %p) {
top:
  %rg = getelementptr i8, ptr %roots, i32 16
  %mem = load ptr, ptr %rg
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %d = load ptr, ptr %eg
  %mg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %mdata = load ptr, ptr %mg
  br i1 %p, label %L1, label %L2
L1:
  br label %J
L2:
  br label %J
J:
  %ph = phi ptr [ %d, %L1 ], [ %mdata, %L2 ]
  %pg = getelementptr i8, ptr %ph, i64 %off
  %b = ptrtoint ptr %mdata to i64
  %x = ptrtoint ptr %pg to i64
  %s = sub i64 %x, %b
  %lg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 0
  %len = load i64, ptr %lg
  %c = icmp ult i64 %s, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %mem, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# (HR4) RED [reviewer fixture C6] — the same bypass through the OTHER width-0 sentinel, `select`.
const _FOZ5_HR4 = replace(
    replace(_FOZ5_HR3,
        "  br i1 %p, label %L1, label %L2\nL1:\n  br label %J\nL2:\n  br label %J\nJ:\n" *
        "  %ph = phi ptr [ %d, %L1 ], [ %mdata, %L2 ]\n" =>
        "  %ph = select i1 %p, ptr %d, ptr %mdata\n"),
    "define i64 @n(" => "define i64 @sel(")

# (HR5) KNOWN-ADMITTED [reviewer fixture B2] — a LOAD through a sentinel-valued address.
#
#     ┌───────────────────────────────────────────────────────────────────┐
#     │ THIS GATE ASSERTS WHAT THE CODE DOES TODAY, DELIBERATELY.         │
#     │ `_foz5_cert_src_kind`'s `:load` arm is DEPTH-0 BY DESIGN: the     │
#     │ VALUE a load produces is a fresh materialised cell no matter      │
#     │ where its ADDRESS came from. foz5 adds NOTHING to the hazard      │
#     │ here — the `IRLoad` that reads the never-materialised address     │
#     │ cell (`%ph`, a cc0 M2b WIDTH-0 SENTINEL) is emitted by the LOAD   │
#     │ ARM whether or not any `ptrtoint` follows it. THE ADDRESS-        │
#     │ SENTINEL QUESTION BELONGS TO THE LOAD ARM, NOT TO THIS PREDICATE. │
#     │ foz5's theorem caps the consequence for the COERCED value at a    │
#     │ wrong branch choice, i.e. at a LOUD HALT (ADR 0017 §4a).          │
#     │ Flipping this to a reject is a LOAD-ARM change, not a foz5 one.   │
#     └───────────────────────────────────────────────────────────────────┘
const _FOZ5_HR5 = replace(_FOZ5_HR3,
    "  %pg = getelementptr i8, ptr %ph, i64 %off\n" =>
    "  %pg = load ptr, ptr %ph\n")

# (HR6) [hostile defect D3] — a NON-64-bit `sub` in the confined chain.
#
# MEASURED WRINKLE, worth recording. A `trunc`-then-`sub i32` fixture does NOT
# exercise the width check: the ptrtoint's use is then the `trunc`, which (C1)
# already refuses as "not a `sub`". Since `sub` operands and result share a
# type, an i32 `sub` requires the COERCIONS THEMSELVES to be i32 — so this
# fixture uses `ptrtoint ptr %e to i32` directly.
#
# THE EXTRACTION OUTCOME IS UNCHANGED BY THE FIX (`:err` before and after): the
# arm's own width guard rejects a non-64-bit ptrtoint, and it runs after the
# entry condition. The DIFFERENCE IS IN THE PREDICATE, which pre-fix returned
# `true` for a shape its own docstring called "a 2-operand i64 `sub`". That
# matters for two reasons: the prose-vs-predicate rule (a stated guarantee no
# line of code checks is worse than silence), and the Bennett-sku0 reuse, which
# will call `_foz5_confined_dead_bounds` on shapes this corpus never produces
# and without this arm's width guard in front of it. Hence the gate asserts the
# PREDICATE, not the message.
#
# The chain must be i32 END TO END — coercions, `sub` AND the `icmp`. A `zext`
# back to i64 before the compare makes the `sub`'s use a `zext`, which (C2)
# already refuses, and the gate then passes for the wrong reason (measured:
# it did, on the first two drafts). Written out in full rather than as a
# `replace` chain so the invariant is visible.
const _FOZ5_HR6 = _FOZ5_DL * """
define i64 @f(ptr %env, ptr %roots, i64 %off) {
top:
  %rg = getelementptr i8, ptr %roots, i32 16
  %mem = load ptr, ptr %rg
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %d = load ptr, ptr %eg
  %bo = mul i64 %off, 8
  %e = getelementptr i8, ptr %d, i64 %bo
  %mg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %mdata = load ptr, ptr %mg
  %b = ptrtoint ptr %mdata to i32
  %x = ptrtoint ptr %e to i32
  %s = sub i32 %x, %b
  %lg = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 0
  %len = load i64, ptr %lg
  %bl = trunc i64 %len to i32
  %c = icmp ult i32 %s, %bl
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %mem, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# (Q) GREEN BY DESIGN — CROSS_MEM_CONFINED. `test_583s` gate (5) CROSS_MEM
# stays RED because its `sub` result is RETURNED (premise (iii)). Its confined
# twin — the SAME two-disjoint-Memory-roots difference, but with the result
# confined to a dead-throw bounds check — IS ADMITTED under ADR 0017 §4a.
#
#     ┌───────────────────────────────────────────────────────────────────┐
#     │ THIS GATE RECORDS A DELIBERATE SCOPE CHOICE, NOT AN ACCIDENT.     │
#     │ Flipping it to a reject means REJECTING THE ROUTE (ADR 0017 §4a), │
#     │ not fixing an implementation defect. Do not "tighten" it without  │
#     │ amending the ADR. Validation debt: no runtime evidence about the  │
#     │ unproven directions exists until wall 8 clears — Bennett-bvmd.    │
#     └───────────────────────────────────────────────────────────────────┘
const _FOZ5_Q = _FOZ5_DL * """
define i64 @q(ptr %memA, ptr %memB, i64 %off, i64 %len) {
top:
  %ga = getelementptr {i64, ptr}, ptr %memA, i32 0, i32 1
  %dataA = load ptr, ptr %ga
  %gb = getelementptr {i64, ptr}, ptr %memB, i32 0, i32 1
  %dataB_base = load ptr, ptr %gb
  %dataB = getelementptr i8, ptr %dataB_base, i64 %off
  %b = ptrtoint ptr %dataA to i64
  %e = ptrtoint ptr %dataB to i64
  %d = sub i64 %e, %b
  %c = icmp ult i64 %d, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %off
oob:
  call void @ijl_bounds_error_int(ptr %memA, i64 %off)
  unreachable
}
""" * _FOZ5_DECL

# (I) INERT — 583s's own `CLUSTER_OK`, verbatim in shape: ONE `.data` root,
# base-cancelling, and its false edge is a `ret` (NOT a dead throw block). So
# 583s's proof admits it and foz5's premise (iv) is FALSE for it — the pin that
# proves first refusal, not foz5, is what admits 583s's corpus.
const _FOZ5_I = """
define i64 @f(ptr %mem, i64 %off, i64 %len) {
top:
  %pbase_gep = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %pbase = load ptr, ptr %pbase_gep
  %pelem_gep = getelementptr {i64, ptr}, ptr %mem, i32 0, i32 1
  %pelem_base = load ptr, ptr %pelem_gep
  %pelem = getelementptr i8, ptr %pelem_base, i64 %off
  %b = ptrtoint ptr %pbase to i64
  %e = ptrtoint ptr %pelem to i64
  %d = sub i64 %e, %b
  %c = icmp ult i64 %d, %len
  br i1 %c, label %ok, label %oob
ok:
  ret i64 %d
oob:
  ret i64 0
}
"""

# (O2) THE STEAL PIN. A source that is SIMULTANEOUSLY S1-shaped (a `load ptr`
# of a constant-offset i8 byte-GEP off an argument) and jbko-USE-shaped (sole
# use an `icmp eq` against an i64 argument).
#
# STRUCTURAL DISJOINTNESS THEOREM — arm ORDER is not load-bearing here:
#   foz5 premise (ii)                 requires EVERY use to be a `sub`;
#   `_jbko_identity_use_violation`    requires EVERY use to be an `icmp eq/ne`.
# `sub` is not `icmp`, so no NON-EMPTY use set satisfies both, and premise (ii)
# rejects the empty use set outright. This is STRICTLY STRONGER than the
# property jbko documents today ("disjoint OVER THE SHAPES `_memdata_root`
# RECOGNISES", `instructions.jl:~3870`), and it is why the bead's own phrasing
# of the widening — a `_memdata_root` ROOT extension, which probe `p07_steal.jl`
# measured STEALING this very witness and regressing the chain to an EARLIER
# wall — was abandoned in favour of a USE-shaped gate.
const _FOZ5_O2 = _FOZ5_DL * """
define i1 @o2(ptr %env, i64 %cap) {
top:
  %eg = getelementptr inbounds i8, ptr %env, i32 56
  %d = load ptr, ptr %eg
  %c = ptrtoint ptr %d to i64
  %eq = icmp eq i64 %cap, %c
  ret i1 %eq
}
""" * _FOZ5_DECL

# ---------------------------------------------------------------------------
# Helpers. foz5-prefixed: `runtests.jl`'s `runfile` uses
# `Base.include(@__MODULE__, path)`, so every test file shares ONE module
# namespace — an unprefixed `_extract_ll` would silently OVERWRITE
# `test_583s_memdata_bounds.jl`'s method of the same signature.
# ---------------------------------------------------------------------------
function _foz5_extract(name, ir, entry; cells=true)
    mktempdir() do dir
        path = joinpath(dir, "$(name).ll")
        write(path, ir)
        try
            pir = extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=cells)
            return (:ok, pir)
        catch e
            e isa InterruptException && rethrow()
            return (:err, sprint(showerror, e))
        end
    end
end

function _foz5_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# The `IRBinOp(dest, :or, <SSAOperand>, ConstOperand(0), 64)` cell identity —
# the SAME node Bennett-583s emits. Rule 4: no-throw is not a pass; the gate
# must see the node.
function _foz5_or(pir, dest::Symbol)
    for ins in _foz5_all_insts(pir)
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or && ins.width == 64 &&
           ins.op1 isa SSAOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins
        end
    end
    return nothing
end

_foz5_icmp(pir, dest::Symbol) =
    findfirst(i -> i isa IRICmp && i.dest === dest, _foz5_all_insts(pir))

# DIRECT predicate probe: evaluates `_foz5_confined_dead_bounds` on every
# `ptrtoint` in `ir`, returning `name => verdict`. Lets gates (I) and (O2)
# assert what the PREDICATE decided rather than inferring it from a message —
# a message can coincide for the wrong reason. Kept in the test file rather
# than `src/`: no production caller needs it.
function _foz5_predicate_probe(ir::AbstractString, entry::AbstractString)
    out = Dict{Symbol, Bool}()
    Bennett.LLVM.Context() do _ctx
        mod = parse(Bennett.LLVM.Module, String(ir))
        try
            f = Bennett.LLVM.functions(mod)[entry]
            dead = Bennett._vec_vm_dead_blocks(f)
            names = Dict{Bennett._LLVMRef, Symbol}()
            for bb in Bennett.LLVM.blocks(f), i in Bennett.LLVM.instructions(bb)
                n = Bennett.LLVM.name(i)
                isempty(n) || (names[i.ref] = Symbol(n))
            end
            supp = Set{Bennett._LLVMRef}()
            for bb in Bennett.LLVM.blocks(f), i in Bennett.LLVM.instructions(bb)
                Bennett.LLVM.opcode(i) == Bennett.LLVM.API.LLVMPtrToInt || continue
                out[Symbol(Bennett.LLVM.name(i))] =
                    Bennett._foz5_confined_dead_bounds(i, names, supp, dead)
            end
        finally
            Bennett.LLVM.dispose(mod)
        end
    end
    return out
end

@testset "Bennett-foz5 CW-D: CONFINED-VALUE contract (dead-throw bounds cluster)" begin

    # =======================================================================
    # (A) GREEN — the S1 corpus shape extracts; BOTH ptrtoints lower to the
    # `:or` cell identity, and the sub / icmp / branch survive VERBATIM.
    # =======================================================================
    @testset "(A) GREEN — split captured MemoryRef bounds cluster" begin
        (st, pir) = _foz5_extract("foz5_a", _FOZ5_A, "f")
        @test st === :ok
        if st === :ok
            # BOTH halves: the memdata-rooted `.data` base AND the
            # closure-env-rooted element pointer.
            @test _foz5_or(pir, :b) !== nothing
            @test _foz5_or(pir, :x) !== nothing
            insts = _foz5_all_insts(pir)
            # The guard itself is emitted UNCHANGED — foz5 admits an operand,
            # it never rewrites or elides the compare or the branch.
            @test any(i -> i isa IRBinOp && i.dest === :s && i.op === :sub, insts)
            @test _foz5_icmp(pir, :c) !== nothing
            # The dead throw arm is the utzc `:__unreachable__` halt sink.
            oob = pir.blocks[findfirst(b -> b.label === :oob, pir.blocks)]
            @test isempty(oob.instructions)
            @test oob.terminator.true_label === :__unreachable__
        else
            @info "(A) message" pir
        end
    end

    # =======================================================================
    # (B) RED — no dead-throw sink. The premise-(iv) pin.
    # =======================================================================
    @testset "(B) RED — false edge returns, no `:__unreachable__` sink" begin
        (st, msg) = _foz5_extract("foz5_b", _FOZ5_B, "f")
        @test st === :err
        if st === :err
            @test occursin("Bennett-583s", msg)
            @test occursin("base-cancelling", msg)
            # The message must name BOTH refusals and BOTH enforcing predicates
            # (the Bennett-p06b arc's prose-vs-predicate rule).
            @test occursin("Bennett-foz5", msg)
            @test occursin("_foz5_confined_dead_bounds", msg)
        end
    end

    # =======================================================================
    # (B2) GREEN — INVERTED branch polarity. POLARITY-AGNOSTICISM PIN.
    # =======================================================================
    @testset "(B2) GREEN — dead block on the TRUE edge is equally admitted" begin
        (st, pir) = _foz5_extract("foz5_b2", _FOZ5_B2, "f")
        @test st === :ok
        if st === :ok
            @test _foz5_or(pir, :b) !== nothing
            @test _foz5_or(pir, :x) !== nothing
        end
    end

    # =======================================================================
    # (C) RED — the coerced value escapes into arithmetic.
    # =======================================================================
    @testset "(C) RED — ptrtoint result escapes into an `add`" begin
        (st, msg) = _foz5_extract("foz5_c", _FOZ5_C, "f")
        @test st === :err
        # ATTRIBUTION NOTE (disclosed, not papered over): `%b` is LEGITIMATELY
        # confined here (its own sub→icmp→br chain is clean) and IS admitted, so
        # the FIRST failing instruction moves to `%x`, which enters neither the
        # 583s arm (`_memdata_root` is nothing and premise (ii) is false) nor the
        # jbko arm (its uses are not all `icmp eq/ne`) and lands on the GENERIC
        # Bennett-iwo9 reject. This is a reporting-ORDER effect, not a contract
        # change — the program still rejects loudly. Do NOT "fix" it by widening
        # the entry surface for a diagnostic-only gain.
        st === :err && @test (occursin("Bennett-iwo9", msg) ||
                              occursin("Bennett-583s", msg))
    end

    # =======================================================================
    # (D) RED — the `sub` result escapes. THE CROSS_MEM-PRESERVING LINE.
    # =======================================================================
    @testset "(D) RED — sub result returned on the live edge" begin
        (st, msg) = _foz5_extract("foz5_d", _FOZ5_D, "f")
        @test st === :err
        st === :err && @test (occursin("Bennett-583s", msg) ||
                              occursin("Bennett-iwo9", msg))
    end

    # =======================================================================
    # (E)/(F) RED — the i1 leaks as a VALUE rather than steering a branch.
    # =======================================================================
    @testset "(E) RED — i1 feeds a `select`" begin
        (st, msg) = _foz5_extract("foz5_e", _FOZ5_E, "f")
        @test st === :err
        st === :err && @test (occursin("Bennett-583s", msg) ||
                              occursin("Bennett-iwo9", msg))
    end

    @testset "(F) RED — i1 `zext`ed to a value" begin
        (st, msg) = _foz5_extract("foz5_f", _FOZ5_F, "f")
        @test st === :err
        st === :err && @test (occursin("Bennett-583s", msg) ||
                              occursin("Bennett-iwo9", msg))
    end

    # =======================================================================
    # (G) RED — genuine cross-object difference that ESCAPES.
    # =======================================================================
    @testset "(G) RED — cross-object difference escapes" begin
        (st, msg) = _foz5_extract("foz5_g", _FOZ5_G, "g")
        @test st === :err
        # ATTRIBUTION (measured in the RED run, both before and after the arm):
        # NEITHER source here is memdata-rooted, so the 583s arm is not entered
        # at all; `%da`/`%db_base` are `load ptr` values, which ARE certified by
        # `_jbko_cell_ptr_src_kind`, so the jbko arm's entry disjunction fires
        # and its USE gate is what rejects (the uses are `sub`s, not
        # `icmp eq/ne`). The reject is jbko-named. Kept as a disjunction rather
        # than pinned to jbko alone: which arm owns a NEAR-MISS is a diagnostic,
        # not a contract — the contract is that it is loudly refused.
        st === :err && @test (occursin("Bennett-jbko", msg) ||
                              occursin("Bennett-583s", msg) ||
                              occursin("Bennett-iwo9", msg))
    end

    # =======================================================================
    # (H) BYTE-IDENTITY — gate off. The whole arm lives inside the
    # `&& ptr_cells` block, so at `ptr_cells=false` there is NO arm and the
    # ptrtoint opcode hits the pre-existing "unsupported LLVM opcode" wall.
    # This is what keeps `verify_reversibility` / gate counts untouched.
    # =======================================================================
    @testset "(H) BYTE-IDENTITY — ptr_cells=false still fails loud" begin
        (st, msg) = _foz5_extract("foz5_h", _FOZ5_A, "f"; cells=false)
        @test st === :err
        st === :err && @test !occursin("Bennett-foz5", msg)
    end

    # =======================================================================
    # (N) RED — uncertified source: a PointerType `phi` (cc0 M2b WIDTH-0
    # SENTINEL). Premise (i).
    # =======================================================================
    @testset "(N) RED — PointerType `phi` source is not a certified cell" begin
        (st, msg) = _foz5_extract("foz5_n", _FOZ5_N, "n")
        @test st === :err
        # `%x`'s source is the ptr phi: premise (i) refuses it, so the 583s arm
        # is not entered via the confinement disjunct and the value falls to the
        # jbko / iwo9 rejects below. Loud either way — the pin is that it is NOT
        # admitted.
        st === :err && @test (occursin("Bennett-iwo9", msg) ||
                              occursin("Bennett-jbko", msg) ||
                              occursin("Bennett-583s", msg))
        # DIRECT: the predicate itself declines. Gate (N) is the DEPTH-0 case;
        # gates (B1)/(C6) below are the same refusal reached through an
        # interposed GEP, which is what the base recursion in
        # `_foz5_cert_src_kind` exists for. Keep all three: the depth-0 form
        # would stay green even if the recursion were deleted.
        @test _foz5_predicate_probe(_FOZ5_N, "n")[:x] === false
    end

    # =======================================================================
    # (HR1)/(HR2) RED — a `jl_global#N` SINGLETON-DATA alias load is not a
    # materialised cell. Hostile review D1.
    # =======================================================================
    @testset "(HR1) RED — singleton-data global alias load (external form)" begin
        (st, msg) = _foz5_extract("foz5_c1", _FOZ5_HR1, "s")
        @test st === :err
        # PRE-FIX this ADMITTED and emitted
        #   IRBinOp(:b, :or, SSAOperand(Symbol("jl_global#77")), ConstOperand(0), 64)
        # — an `:or` cell identity over a GLOBAL BASE SYMBOL, because the
        # 416r.13 alias arm registers the name while emitting NO IRInst.
        @test _foz5_predicate_probe(_FOZ5_HR1, "s")[:b] === false
    end

    @testset "(HR2) RED — singleton-data global alias load (defined form)" begin
        (st, msg) = _foz5_extract("foz5_c2", _FOZ5_HR2, "s")
        @test st === :err
        # The defined and `external` spellings take different paths through
        # `_extract_const_globals`; both must refuse.
        @test _foz5_predicate_probe(_FOZ5_HR2, "s")[:b] === false
    end

    # =======================================================================
    # (HR3)/(HR4) RED — the sentinel refusal must survive an interposed GEP.
    # Hostile review D2(a). ONE instruction bypassed it pre-fix.
    # =======================================================================
    @testset "(HR3) RED — GEP over a PointerType `phi` base" begin
        (st, msg) = _foz5_extract("foz5_b1", _FOZ5_HR3, "n")
        @test st === :err
        @test _foz5_predicate_probe(_FOZ5_HR3, "n")[:x] === false
    end

    @testset "(HR4) RED — GEP over a PointerType `select` base" begin
        (st, msg) = _foz5_extract("foz5_c6", _FOZ5_HR4, "sel")
        @test st === :err
        @test _foz5_predicate_probe(_FOZ5_HR4, "sel")[:x] === false
    end

    # =======================================================================
    # (HR5) KNOWN-ADMITTED — load through a sentinel address. See the banner on
    # `_FOZ5_HR5`. Hostile review D2(b): a DELIBERATE scope boundary, not a gap
    # in this predicate.
    # =======================================================================
    @testset "(HR5) KNOWN-ADMITTED — load through a sentinel-valued address" begin
        (st, pir) = _foz5_extract("foz5_hr5", _FOZ5_HR5, "n")
        @test st === :ok
        st === :ok && @test _foz5_or(pir, :x) !== nothing
        # Stated as a positive so that a future LOAD-ARM tightening flips this
        # RED and announces itself, rather than passing silently.
        @test _foz5_predicate_probe(_FOZ5_HR5, "n")[:x] === true
    end

    # =======================================================================
    # (HR6) RED — a NON-64-bit `sub` in the confined chain. Hostile review D3.
    # =======================================================================
    @testset "(HR6) RED — non-64-bit `sub` in the confined chain" begin
        (st, msg) = _foz5_extract("foz5_hr6", _FOZ5_HR6, "f")
        # The EXTRACTION outcome is unchanged by the D3 fix — the arm's width
        # guard already rejects. Asserted anyway so the gate notices if that
        # guard is ever relaxed.
        @test st === :err
        st === :err && @test occursin("NON-64-bit", msg)
        # THE ACTUAL D3 PIN: the PREDICATE must decline a non-i64 `sub`, so
        # that its docstring is literally true and the Bennett-sku0 reuse
        # (which has no width guard in front of it) is safe. Pre-fix: `true`.
        @test _foz5_predicate_probe(_FOZ5_HR6, "f")[:x] === false
    end

    # =======================================================================
    # (Q) GREEN BY DESIGN — CROSS_MEM_CONFINED. See the banner on `_FOZ5_Q`.
    # =======================================================================
    @testset "(Q) ADMITTED BY DESIGN — confined cross-object difference" begin
        (st, pir) = _foz5_extract("foz5_q", _FOZ5_Q, "q")
        @test st === :ok
        if st === :ok
            @test _foz5_or(pir, :b) !== nothing
            @test _foz5_or(pir, :e) !== nothing
        end
    end

    # =======================================================================
    # (I) INERT — 583s keeps FIRST REFUSAL over its own corpus.
    # =======================================================================
    @testset "(I) INERT — 583s's own cluster is admitted by 583s, not foz5" begin
        (st, pir) = _foz5_extract("foz5_i", _FOZ5_I, "f")
        @test st === :ok
        if st === :ok
            @test _foz5_or(pir, :b) !== nothing
            @test _foz5_or(pir, :e) !== nothing
        end
        # And foz5 could NOT have admitted it: its false edge is a `ret`, so
        # premise (iv) is false. Proven directly against the predicate.
        f = _foz5_predicate_probe(_FOZ5_I, "f")
        @test f == Dict(:b => false, :e => false)
    end

    # =======================================================================
    # (O2) THE STEAL PIN — arm order is not load-bearing. See `_FOZ5_O2`.
    # =======================================================================
    @testset "(O2) STEAL PIN — S1-shaped + jbko-use-shaped stays jbko's" begin
        (st, pir) = _foz5_extract("foz5_o2", _FOZ5_O2, "o2")
        @test st === :ok
        if st === :ok
            @test _foz5_or(pir, :c) !== nothing
        end
        # The foz5 predicate must DECLINE it (its use is an `icmp eq`, not a
        # `sub`) — the executable form of the disjointness theorem.
        f = _foz5_predicate_probe(_FOZ5_O2, "o2")
        @test f[:c] === false
    end

    # =======================================================================
    # (O4) PIN — the jbko `_memdata_root(src) === nothing` guard is STILL
    # PRESENT and STILL REDUNDANT. Bennett-foz5 landed WITHOUT the root
    # extension the a8nw note anticipated, so that note is still literally
    # true (redundant today, load-bearing the moment 583s grows a
    # fall-through) rather than INVERTED. A source grep, because the property
    # being pinned is a property of the SOURCE, not of any extraction.
    # =======================================================================
    @testset "(O4) PIN — jbko's `_memdata_root === nothing` guard survives" begin
        src = read(joinpath(dirname(@__DIR__), "src", "extract", "instructions.jl"),
                   String)
        @test occursin("_memdata_root(src) === nothing", src)
        # foz5 introduced NO fall-through: the 583s arm still always returns or
        # errors, because entry-via-confinement implies admission-via-confinement
        # (the same pure predicate on the same `inst`).
        @test occursin("_foz5_confined_dead_bounds", src)
    end

    # =======================================================================
    # (W8)+(O3) CORPUS — the real gated `push!` path. Wall 7 is CLEARED and the
    # chain advances. ADVANCED by Bennett-bvmd (2026-08-06): wall 8 (the ROOT
    # body's `gc_alloc_obj` BYTE-granular aggregate-store refusal) is now
    # CLEARED TOO — that tier is admitted at `elem_width = 8` — so the positive
    # moves to wall 9, the Bennett-37mt arena-src memcpy.
    #
    # (O3) rides along as the corpus anti-steal: the jbko `%L84`
    # ConcurrencyViolation witness must NOT have been poached.
    # =======================================================================
    @testset "(W8) CORPUS — wall 7 cleared, chain advances to wall 12" begin
        _pushfoz5(n::Int64) = begin
            v = Int64[]; push!(v, n); @inbounds v[1]
        end
        msg = try
            Bennett.extract_parsed_ir_set_from_julia(_pushfoz5, Tuple{Int64};
                                                     ptr_cells=true)
            ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test msg != ""            # still walled — at wall 10 now, not 7/8/9
        # NARROWED to BODY SCOPE by Bennett-sy29 (xkl wall 9). Wall 10 IS a 583s
        # reject in the ROOT body, so the blanket negatives cannot survive — but
        # their intent (wall 7, the CLOSURE's `%idxend41` cluster, is CLEARED by
        # this very bead's contract) is preserved by scoping them to the closure.
        # NOTE what wall 10 shows about §4a's reach: (C0) and (C1) both PASS on
        # that cluster — it is ONE OPCODE from the contract — and the opcode is
        # the whole difficulty, because `udiv exact` turns the difference into a
        # live ELEMENT INDEX that escapes into two closure-env stores rather than
        # merely steering a halting branch. Clause (iii) is right to decline it.
        @test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
        # (O3) the jbko witness was not poached.
        @test !occursin("Bennett-jbko", msg)
        @test !occursin("ConcurrencyViolation", msg)
        # LOAD-BEARING NEGATIVE, ADDED by Bennett-bvmd: wall 8 is CLEARED, so a
        # p06b reject naming `gc_alloc_obj` is now a REGRESSION.
        @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
        # ===================== WALL 10 CLEARED — Bennett-57hd =====================
        # ADVANCED by Bennett-57hd (ADR 0017 §4b, the VALUE-IDENTITY contract): wall
        # 10 — the ROOT body's `%12 = ptrtoint ptr %memory_data3 to i64`, whose
        # base-cancelling difference escaped through `udiv exact` — is CLEARED, so a
        # 583s / foz5 / 57hd reject in the ROOT body is now a REGRESSION rather than
        # the expected wall. (Replaces the sy29-era positive, which asserted exactly
        # that reject.) Non-numeral anchors only (Bennett-0ncn).
        @test !occursin("base-cancelling", msg)
        @test !occursin("_foz5_confined_dead_bounds", msg)
        @test !occursin("_57hd_value_identity_cluster", msg)
        # ===================== WALL 11 CLEARED — Bennett-5viz =====================
        # ADVANCED by Bennett-5viz (xkl wall 11): the loaded-`ptr` (`.mem`) memcpy SRC —
        # corpus site #4 of the sy29 census, `Bennett-8bys` territory — is now certified
        # by `_5viz_global_src_root`, which strips the `extractvalue` with the shipped
        # `_57hd_insertvalue_field` and canonicalises the result with `_57hd_canon`
        # (ZERO ADR 0017 §4b change) down to the EMPTY-`GenericMemory` SINGLETON's
        # `.globals` root; root/capacity/scale then come from `parsed.globals` via
        # doih G8's own formula. WALL 12 is `Bennett-p06b`'s OWN reject: the
        # `alloca { ptr, ptr }` whose allocated type the alloca arm SILENTLY SKIPS, so
        # nothing ever reserved the cells that aggregate store would write.
        @test occursin("Bennett-p06b", msg)
        @test occursin("_p06b_cell_ptr_target_kind", msg)   # names the predicate
        @test occursin("SILENTLY SKIPS", msg)
        # ┌────────── THE `.mem` SUFFIX TRAP — MEASURED, DO NOT SHORTEN ───────────┐
        # │ The wall-11 discriminator INVERTS here: a `Bennett-37mt` / `-8bys` src  │
        # │ reject at the corpus is now a REGRESSION. This negative is STRONGER     │
        # │ than the operand-name pair it replaces — it does not depend on which    │
        # │ operand the `_ir_error` prefix happens to quote.                        │
        # │ BUT: wall 12's message DOES contain the substring `new::Array.ref` (it  │
        # │ quotes `store { ptr, ptr } %"new::Array.ref", …`) and does NOT contain  │
        # │ `new::Array.ref.mem`. KEEP THE `.mem` SUFFIX — dropping it turns the    │
        # │ line RED. Check discriminators against the MESSAGE TEXT, never against  │
        # │ the IR: the Bennett-sy29 lesson, applied to its own successor.          │
        # └────────────────────────────────────────────────────────────────────────┘
        @test !occursin("Bennett-37mt", msg)
        @test !occursin("new::Array.ref.mem", msg)
        @test !occursin("Bennett-5viz", msg)       # 5viz must not be the new wall
        # NOTE FOR WHOEVER CLEARS WALL 12 — all four points MEASURED on the wall-12
        # text itself, not forecast:
        #   * wall 12's own message contains NEITHER `Bennett-1zow` NOR
        #     `_p06b_granularity_violation`, so a marker written against either tag
        #     would never fire. Pin what IS there.
        #   * wall 13 is a SECOND 37mt/8bys memcpy reject (`memcpy operand alloca has
        #     non-integer element type` — corpus site #5's `alloca { ptr, ptr }` src,
        #     still `Bennett-8bys` territory), so `!occursin("Bennett-37mt")` will have
        #     to FLIP BACK to a positive one wall later; the discriminator against wall
        #     11 at that point is the operand pair (`%0` / `env+56`, NO `.mem`).
        #   * wall 14 is the bvmd `SCALE-COHERENCE` reject on the 9×i64 closure alloca.
        #     It PRE-EXISTS 5viz — raised by the already-shipped site-#3 memcpy's word
        #     stamp setting `all_byte[env] = false`, not by anything 5viz emits — and
        #     the 5viz scout's probe `p10` measured that byte-stamping ALL THREE
        #     env-rooted memcpys makes the ROOT extract with NO WALL AT ALL. That tier
        #     decision is deferred to the `Bennett-bvmd` family arc (5viz scout §3);
        #     5viz deliberately keeps the sy29 dst-stamp rule unchanged.
        #   * the `%L21` / `%L43` clusters are NOT future walls — already admitted
        #     under ADR 0017 §4a (gate (S) of test_57hd_value_identity.jl).
    end
end
