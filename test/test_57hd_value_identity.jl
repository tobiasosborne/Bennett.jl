# test/test_57hd_value_identity.jl — bead Bennett-57hd (xkl frontier wall 10):
# the VALUE-IDENTITY contract, ADR 0017 §4b (BennettVM.jl
# `docs/adr/0017-closed-world-execution.md`).
#
# # What this bead admits
#
# Julia's `push!` closed-world ROOT computes `memoryrefoffset` —
# `array.ref.ptr_or_offset − array.ref.mem.data` — and converts it to an element
# index with `udiv exact 8`. Unlike Bennett-foz5's cluster the difference is NOT
# confined: it steers a live grow-or-not branch and is stored into two
# closure-environment slots that `_growend!` reads as
# `jl_alloc_genericmemory_unchecked`'s ALLOCATION SIZE and `llvm.memmove`'s
# LENGTH. There is no dead-throw sink to confine it into, and under the arena
# model (`bennettvm-pdqx`: no region table, three monotone cursors; ADR 0018 §E:
# an unstored load reads 0) a wrong allocation size is an UNDETECTABLE
# adjacent-allocation clobber. So no confinement-class contract is available for
# this shape and §4a must not be widened to reach it (its clause (iii) declines
# correctly — the `sub`'s sole use is the `udiv`, not an `icmp`).
#
# Bennett-583s also declines, but for a reason that is an artefact of its proof
# technique: `_memdata_root` establishes base cancellation by SYNTACTIC SSA
# EQUALITY of the two `.data` loads. Here the two operands are the two halves of
# ONE `MemoryRef`, both read out of one freshly `julia.gc_alloc_obj`-ed `Array`
# header, and — in this program — they are literally THE SAME POINTER, related
# through one aggregate store and one same-slot reload rather than one SSA name.
#
# # The contract
#
#     ptrtoint %S --(every use)--> i64 sub(ptrtoint %S, ptrtoint %T)
#     with canon(%S) === canon(%T)  ==>  the difference is IDENTICALLY 0
#
# `canon` is a straight-line, SINGLE-BASIC-BLOCK copy analysis: aggregate-store
# field forwarding through an `insertvalue` chain, same-slot reload, and a
# no-clobber scan. GUARANTEE: each admitted `sub` evaluates to 0 in native and
# to 0 in BennettVM, on every input, UNDER ANY map φ from addresses to cell
# values — `φ(p) − φ(p) = 0 = p − p` needs no property of φ whatsoever.
#
# This is an ORACLE-MATCH contract, and it is the STRONGEST of the three: 583s
# needs φ translation-cancelling within a region, Bennett-jbko needs φ
# injective, §4b needs NOTHING of φ. Consequently §4a's conditioning clause
# ("everything outside `τ` is computed by the pre-existing, already-sound
# model") is SATISFIED, not voided, and jbko's trajectory correspondence is
# preserved by construction. BOTH columns of the failure matrix are bounded.
#
# # The corpus partition (measured — gate (S) is the executable form)
#
#   | body       | cluster   | 583s | foz5 §4a | 57hd §4b |
#   |------------|-----------|------|----------|----------|
#   | root       | `%top`    | —    | —        | **owns** |
#   | root       | `%L21`    | —    | **owns** | —        |
#   | root       | `%L43`    | —    | **owns** | —        |
#   | `_growend!`| `%L46`    | owns | (also)   | —        |
#   | `_growend!`| `%L58`    | owns | (also)   | —        |
#   | `_growend!`| `%idxend41`| —   | **owns** | —        |
#
# THE ADJUDICATION FINDING THIS TABLE ENCODES (and the reason gate (S) exists):
# `%L21` / `%L43` were believed to need a third contract. They do not — the
# SHIPPED §4a predicate already admits them. Nobody had evaluated
# `_foz5_confined_dead_bounds` on them; the scout compared two PROTOTYPES
# against `_memdata_root` only. A table-shaped gate catches that class of error
# and a prose claim does not. §4b therefore covers 1 of 1 clusters that actually
# need it, and route δ′ (a same-`MemoryRef` provenance-pair predicate resting on
# a DECLARED Julia language invariant) was REJECTED: it covers nothing extra,
# its failure mode is a silently wrong heap rather than a halt, and it amplifies
# `bennettvm-jb6w`.
#
# # Gate map
#
#   (A)   GREEN  — the corpus shape, distilled. BOTH ptrtoints lower to the
#                  `:or` cell identity; the `sub` and `udiv exact` survive.
#   (A2)  GREEN  — the same with the `sub` operands SWAPPED (symmetry).
#   (P)   PIN    — THE PAIR. The predicate is TRUE on BOTH coercions. Measured
#                  counterexample: admitting only one walls on the other in the
#                  JBKO arm ("found a use that is a `sub`, not an icmp").
#   (B)   RED    — cross-allocation: two independent boxes.
#   (C)   RED    — a clobbering store to the tracked slot inside the window.
#   (C2)  RED    — a VARIABLE-INDEX GEP write into the tracked object. Found in
#                  REVIEW, not in the corpus: `_p06b_slot_key` makes such a GEP
#                  its OWN root, and the non-escape rule would then call a write
#                  straight into the tracked `alloca` "disjoint" from it.
#   (C3)  RED    — HOSTILE D1 (P0): `store ptr %a, ptr %a`. The non-escape scan
#                  checked only the ADDRESS operand, so the alloca aliased its
#                  own reloaded copy and a clobber was skipped. THE ONLY
#                  EXECUTED COUNTEREXAMPLE: the admitted `sub` ran to 64 on the
#                  VM against a guarantee of 0 in both worlds.
#   (D4)  RED    — HOSTILE D2: a truthful `memory(none)` call carrying an
#                  operand BUNDLE. LLVM ORs in `writeOnly()` for a clobbering
#                  bundle; the raw attribute does not say so.
#   (D5)  RED    — HOSTILE D3a: `poison` / `undef` canonical results. LLVM
#                  UNIQUES them, so two independent chains compared EQUAL.
#   (D6)  RED    — HOSTILE D3b: a NEGATIVE mem-intrinsic length inverts the
#                  written range, emptying it under the non-overlap test.
#   (T)   GREEN  — HOSTILE D5: the cluster inside a LOOP BODY is admitted, and
#   (T2)  RED      a loop-carried pointer `phi` source is refused. Together:
#                  why NO back-edge veto is needed. Do not add one.
#   (D)   RED    — an intervening call with NO `memory` attribute.
#   (D2)  RED    — an intervening call with `memory(argmem: readwrite)`.
#                  THE O-1 NEGATIVE DECODE CANARY.
#   (D3)  GREEN  — an intervening call with `memory(none)`.
#                  THE O-1 POSITIVE DECODE CANARY.
#   (E)   RED    — the allocator call carries no `noalias` return attribute.
#   (F2)  RED    — an `alloca` in the clobber window is CAPTURED by a call
#                  carrying `nocapture` at neither the call site nor the callee
#                  declaration, so it can no longer be proved non-escaping.
#   (F3)  GREEN  — the same with `nocapture` on the CALLEE DECLARATION only.
#                  THE CORPUS SPELLING: a call-site-only check fails here, and
#                  therefore fails the corpus. Measured by both proposers.
#   (F4)  GREEN  — the same with `nocapture` at the CALL SITE only.
#   (G)   RED    — a same-root non-overlap judgement over a NON-byte-tier root.
#   (G2)  GREEN  — the word tier with no same-root judgement required. §4b has
#                  no byte-tier gate on the THEOREM, only on that judgement.
#   (H)   RED    — C tier, `struct { void *a; void *b; }` holding two DIFFERENT
#                  pointers. The `bennettvm-jb6w` hostile fixture.
#   (H2)  GREEN  — the same C shape holding ONE pointer twice. §4b is
#                  language-agnostic and CORRECT here: the difference really is 0.
#   (I)   RED    — cross-block reload. SCOPE BOUNDARY, not a bug.
#   (J)   RED    — an opaque call between the header write and the reload: the
#                  `_growend!` shape, i.e. the exact `%L21`/`%L43` blockage.
#                  SCOPE BOUNDARY, not a bug.
#   (K)   RED    — the coerced value escapes into an `add`.
#   (L)   RED    — a non-64-bit (`i32`) coercion/`sub` pair. PREDICATE-level.
#   (M)   RED    — a PointerType `phi` source (the cc0 M2b WIDTH-0 SENTINEL).
#   (N)   RED    — the forwarded store's target is not a p06b-certified cell
#                  pointer. CLAUSE (iv). PREDICATE-level.
#   (O)   RED    — the stored aggregate is a `load`, not an `insertvalue` chain.
#   (Z)   BYTE-IDENTITY — `ptr_cells=false` on (A) is unchanged, and the circuit
#                  tier is untouched.
#   (S)   STEAL  — the 6x4 partition table above, asserted cell-for-cell over
#                  BOTH corpus bodies. The gate class that found the finding.
#   (W)   CORPUS — the real gated `push!` path clears wall 10 and advances to
#                  wall 11 (`Bennett-37mt` / `Bennett-8bys` src memcpy), with
#                  the identical-text discriminator.
#
# Rule 5: every fixture is hand-built and hermetic and carries an explicit
# `target datalayout` (the test_foz5 / test_7wsz idiom). Nothing is pinned by
# SSA NUMBER — those drift between processes.
#
# SUITE MODE: every per-file green claim must be under
# `julia --project --check-bounds=yes test/test_57hd_value_identity.jl`.

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, ParsedIR, IRBinOp,
               ConstOperand, SSAOperand

const _VI_DL = "target datalayout = \"e-p:64:64:64-i64:64-n8:16:32:64-S128\"\n"

# The allocator declaration carries the two attributes Julia's own codegen
# emits and this contract READS rather than assumes (measured on the corpus,
# probe `b18_attrs.jl`):
#   * `noalias` on the RETURN  — freshness (A3 of the ledger);
#   * `memory(argmem: read, inaccessiblemem: readwrite)` — writes no
#     IR-visible object memory (A1). Encoded value 0b001101; inaccessiblemem is
#     by definition invisible to this analysis.
# `llvm.memcpy` carries `nocapture` on the DECLARATION and NOT at the call site
# — measured independently by both proposers, and load-bearing: a call-site-only
# check REJECTS THE CORPUS.
const _VI_DECL = """
declare noalias ptr @julia.gc_alloc_obj(ptr, i64, ptr) memory(argmem: read, inaccessiblemem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
"""

# ---------------------------------------------------------------------------
# (A) THE CORPUS SHAPE, distilled from the `push!` root's `%top` block.
#
#   %md   <- load (gep {i64,ptr} %mem, 0, 1)     ; the Memory's .data
#   %ref  =  insertvalue {ptr,ptr} { %md, %mem } ; the MemoryRef, built in-body
#   %obj  =  gc_alloc_obj(24)                    ; the fresh Array header
#   store {ptr,ptr} %ref, ptr %obj               ; the aggregate store
#   %f0   <- load (gep {ptr,ptr} %obj, 0, 0)     ; ref.ptr_or_offset  == %md
#   %f1   <- load (gep {ptr,ptr} %obj, 0, 1)     ; ref.mem            == %mem
#   %md2  <- load (gep {i64,ptr} %f1, 0, 1)      ; ref.mem.data       == %md
#   %d    =  sub(ptrtoint %f0, ptrtoint %md2)    ; IDENTICALLY ZERO
#   %idx  =  udiv exact %d, 8
#
# The `store ptr null` at +8 and the `memcpy` at +16 are the corpus's own
# intervening writes: they are what forces the clobber scan to make a SAME-ROOT
# non-overlap judgement (hence the byte-tier gate) and to prove an `alloca`
# non-escaping through a DECLARATION-spelled `nocapture`.
# ---------------------------------------------------------------------------
const _VI_A = _VI_DL * """
define i64 @vi(ptr %task, ptr %tag, ptr %mem) {
top:
  %sz = alloca i64, align 8
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %b8 = getelementptr inbounds i8, ptr %obj, i32 8
  store ptr null, ptr %b8, align 8
  store { ptr, ptr } %ref, ptr %obj, align 8
  %szp = getelementptr inbounds i8, ptr %obj, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sz, ptr align 8 %szp, i64 8, i1 false)
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  %idx = udiv exact i64 %d, 8
  ret i64 %idx
}
""" * _VI_DECL

# (A2) the `sub` with its operands SWAPPED. The predicate is symmetric: it walks
# from each `ptrtoint` to its sibling, so neither operand position is special.
const _VI_A2 = replace(_VI_A, "  %d = sub i64 %a, %b\n" => "  %d = sub i64 %b, %a\n")

# (B) RED — CROSS-ALLOCATION. `%f1`'s `.data` is reloaded out of a SECOND box
# that never received the aggregate store, so the two canonical forms differ.
const _VI_B = _VI_DL * """
define i64 @vi_cross(ptr %task, ptr %tag, ptr %memA, ptr %memB) {
top:
  %mdpA = getelementptr inbounds { i64, ptr }, ptr %memA, i32 0, i32 1
  %mdA = load ptr, ptr %mdpA, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %mdA, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %memA, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %mdpB = getelementptr inbounds { i64, ptr }, ptr %memB, i32 0, i32 1
  %mdB = load ptr, ptr %mdpB, align 8
  %b = ptrtoint ptr %mdB to i64
  %a = ptrtoint ptr %f0 to i64
  %d = sub i64 %a, %b
  %idx = udiv exact i64 %d, 8
  ret i64 %idx
}
""" * _VI_DECL

# (C) RED — a CLOBBERING store, overlapping the tracked slot `[0,8)` of `%obj`,
# lands between the aggregate store and the `%f0` reload. Without the clobber
# scan the walk would forward through a stale writer.
const _VI_C = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  store ptr %tag, ptr %obj, align 8\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n")

# (C2) RED — THE VARIABLE-GEP ALIAS, found in REVIEW rather than in the corpus.
#
# `_p06b_slot_key` stops at a VARIABLE index and makes that GEP its own root —
# sound for the KEY (two runtime-indexed addresses cannot be proven equal), but
# a disaster for DISJOINTNESS if taken literally: a
# `getelementptr i8, ptr %a, i64 %i` store into a NON-ESCAPING `alloca %a` would
# get the GEP as its root, and the `:alloca` + non-escape rule would then declare
# that write disjoint from `%a` — skipping a write STRAIGHT INTO THE TRACKED
# OBJECT. `_57hd_underlying` is what closes it: two roots with the same
# underlying object are never disjoint, whatever their spellings.
#
# Here the tracked slot is `[0,8)` of the `alloca %box`, the reload is at the
# same slot, and a variable-index byte GEP off `%box` is stored through in
# between. It MUST reject.
const _VI_C2 = _VI_DL * """
define i64 @vi_vgep(ptr %mem, ptr %other, i64 %i) {
top:
  %box = alloca [4 x i64], align 8
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  store { ptr, ptr } %ref, ptr %box, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %vg = getelementptr i8, ptr %box, i64 %i
  store ptr %other, ptr %vg, align 8
  %f0b = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0b to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL

# (D) RED — an intervening call with NO `memory` attribute at all. Its footprint
# is `:unknown` and the walk stops. This is the A1 premise-flip made permanent,
# and it is the fixture a future widener hits first.
const _VI_D = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_opaque(ptr %obj)\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_opaque(ptr)\n"

# (D2) RED — THE O-1 NEGATIVE DECODE CANARY. The callee DOES carry a `memory`
# attribute, and it says `argmem: readwrite`. If the MemoryEffects bit decode
# ever silently changes meaning this gate goes GREEN and the contract is unsound
# — that is exactly what it is here to catch. Without it, gate (D) alone would
# pass with a decoder that returns "writes nothing" for everything.
const _VI_D2 = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_writer(ptr %obj)\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_writer(ptr) memory(argmem: readwrite)\n"

# (D3) GREEN — THE O-1 POSITIVE DECODE CANARY. `memory(none)` must be READ and
# BELIEVED, not merely "not rejected". A decoder that fails closed on everything
# would pass (D) and (D2) and fail here.
const _VI_D3 = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_pure(ptr %obj)\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_pure(ptr) memory(none)\n"

# (E) RED — the allocator call carries NO `noalias` return attribute, so `%obj`
# is not a provably fresh object and the `store ptr null` at +8 (whose root is
# `%obj`) can no longer be shown disjoint from the tracked `%mem` root. (A3)
# is read from the IR, never from the callee's name.
const _VI_E = replace(_VI_A,
    "declare noalias ptr @julia.gc_alloc_obj(ptr, i64, ptr) memory(argmem: read, inaccessiblemem: readwrite)" =>
    "declare ptr @julia.gc_alloc_obj(ptr, i64, ptr) memory(argmem: read, inaccessiblemem: readwrite)")
const _VI_E2 = replace(_VI_E, "%obj = call noalias ptr @julia.gc_alloc_obj" =>
                              "%obj = call ptr @julia.gc_alloc_obj")

# (F2)/(F3)/(F4) — THE `nocapture` FALLBACK, pinned three ways.
#
# PROSE-VS-PREDICATE TRAP, MEASURED INDEPENDENTLY BY BOTH PROPOSERS: the corpus
# carries `nocapture` on the memcpy's CALLEE DECLARATION and NOT at the call
# site, so a CALL-SITE-ONLY CHECK REJECTS THE CORPUS. The predicate must consult
# both, and its docstring must say "call site OR callee declaration".
#
# MEASURED WRINKLE, worth recording so nobody repeats the probe cycle: the
# `llvm.*` MEM INTRINSICS CANNOT CARRY THIS GATE. LLVM auto-populates an
# intrinsic declaration's standard attributes when it parses the module, so
# deleting `nocapture` from `declare void @llvm.memcpy…` in the fixture text has
# NO EFFECT — the parsed declaration has it back. These three fixtures therefore
# put the capture question on an ORDINARY callee, which LLVM leaves alone.
#
# `%sz` is the destination of the intervening `memcpy`, and the tracked root
# across the reload window is `%mem` (an `Argument`, i.e. `:other`). Two
# `:other`/`:alloca` roots are disjoint ONLY via the non-escape scan, so the
# scan is exactly what decides these three.
const _VI_F2 = replace(_VI_A,                          # RED — captured
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_cap(ptr %sz)\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_cap(ptr) memory(none)\n"
const _VI_F3 = replace(_VI_F2,                         # GREEN — DECLARATION only
    "declare void @vi_cap(ptr) memory(none)" =>
    "declare void @vi_cap(ptr nocapture) memory(none)")
const _VI_F4 = replace(_VI_F2,                         # GREEN — CALL SITE only
    "  call void @vi_cap(ptr %sz)\n" =>
    "  call void @vi_cap(ptr nocapture %sz)\n")

# (G) RED — the WORD tier where a SAME-ROOT non-overlap judgement is required.
# `malloc` reserves 8 bytes per cell, so a native byte-range disjointness does
# NOT transport to VM cell disjointness (`bennettvm-jb6w`, pre-empted rather
# than amplified). The intervening `memcpy` writes `[16,24)` of the same root as
# the tracked `[0,8)`; at scale 8 that judgement is refused and the write
# clobbers.
const _VI_G = _VI_DL * """
define i64 @vi_word(ptr %mem) {
top:
  %sz = alloca i64, align 8
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @malloc(i64 24)
  store { ptr, ptr } %ref, ptr %obj, align 8
  %szp = getelementptr inbounds i8, ptr %obj, i32 16
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %szp, ptr align 8 %sz, i64 8, i1 false)
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL * "\ndeclare noalias ptr @malloc(i64) memory(argmem: read, inaccessiblemem: readwrite)\n"

# (G2) GREEN — the SAME word-tier root with the intervening same-root write
# REMOVED. No same-root non-overlap judgement is needed, so no byte-tier gate
# applies and the admission stands. §4b's THEOREM has no tier premise at all:
# `0 = 0` holds at every scale. A reader who expects a `_root_scale` gate on the
# contract itself must find this gate saying why there is none.
const _VI_G2 = replace(_VI_G,
    "  %szp = getelementptr inbounds i8, ptr %obj, i32 16\n" *
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %szp, ptr align 8 %sz, i64 8, i1 false)\n" => "")

# (H) RED — THE `bennettvm-jb6w` HOSTILE FIXTURE. A clang-shaped
# `struct { void *a; void *b; }` register-coercion spill, differencing the two
# fields, which hold TWO DIFFERENT pointers. Route δ′ — which would have had to
# ask "is this literal `{ptr,ptr}` a MemoryRef?" — gets this direction WRONG and
# admits it. §4b has NO type-shape recogniser at all: it asks only "are these
# the same value?", and that question has the same correct answer on every
# language tier.
const _VI_H = _VI_DL * """
%struct.Pair = type { ptr, ptr }
define i64 @vi_ctier(ptr %task, ptr %tag, ptr %p, ptr %q) {
top:
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %p, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %q, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 16, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %f1 to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL

# (H2) GREEN — the SAME C-tier shape with ONE pointer written into BOTH fields.
# §4b admits it, and that admission is CORRECT: the difference really is 0.
# The pair (H)/(H2) is the executable statement that this contract does not
# widen the jb6w recognition surface — it never recognises anything.
const _VI_H2 = replace(_VI_H, "insertvalue { ptr, ptr } %r0, ptr %q, 1" =>
                              "insertvalue { ptr, ptr } %r0, ptr %p, 1")

# (I) RED — SCOPE BOUNDARY, NOT A BUG. The reload sits in a SUCCESSOR block.
# The analysis is single-basic-block by design: a straight-line range within one
# block is the only range whose "no write happened in between" is a statement
# about EXECUTION rather than about layout. Generalising needs a dominator tree
# the extractor does not build; it is tracked as the ε successor bead
# (Bennett-v7gv) and buys nothing on the corpus.
const _VI_I = _VI_DL * """
define i64 @vi_xblock(ptr %task, ptr %tag, ptr %mem, i1 %c) {
top:
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8
  br label %next
next:
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL

# (J) RED — SCOPE BOUNDARY, NOT A BUG. An opaque call with unmodelled effects
# sits between the header write and the reload. THIS IS THE EXACT `%L21` /
# `%L43` BLOCKAGE: in the real corpus the call is `j_#_growend!##0`, which has
# no `memory` attribute and does rewrite the header. Those two clusters are NOT
# future walls — the shipped §4a contract already admits them (gate (S)) — so
# this boundary costs the frontier nothing. Do not "fix" it here; the
# interprocedural discharge is Bennett-v7gv.
const _VI_J = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_growend(ptr %obj, ptr %sz)\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_growend(ptr, ptr)\n"

# (K) RED — the coerced value ESCAPES as a magnitude: `%a` additionally feeds an
# `add`. Clause (ii) requires EVERY use to be a qualifying `sub`. The SUB's uses
# are unconstrained; the COERCION's are not.
const _VI_K = replace(_VI_A,
    "  %d = sub i64 %a, %b\n" => "  %d = sub i64 %a, %b\n  %esc = add i64 %a, 7\n",
    "  ret i64 %idx\n" => "  %r = add i64 %idx, %esc\n  ret i64 %r\n")

# (L) RED — a non-64-bit cluster. Since a `sub`'s operands and result share a
# type, an i32 `sub` requires the COERCIONS THEMSELVES to be i32. The arm's own
# width guard also rejects this, so — exactly as foz5 gate (HR6) — the gate
# asserts the PREDICATE, not the message: a stated guarantee no line of code
# checks is worse than silence.
const _VI_L = replace(_VI_A,
    "  %a = ptrtoint ptr %f0 to i64\n  %b = ptrtoint ptr %md2 to i64\n" *
    "  %d = sub i64 %a, %b\n  %idx = udiv exact i64 %d, 8\n  ret i64 %idx\n" =>
    "  %a = ptrtoint ptr %f0 to i32\n  %b = ptrtoint ptr %md2 to i32\n" *
    "  %d = sub i32 %a, %b\n  %idx = zext i32 %d to i64\n  ret i64 %idx\n")

# (M) RED — a PointerType `phi` source. Clause (i) refuses it, and the refusal
# is LOAD-BEARING FOR SOUNDNESS, not hygiene:
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ A ptr `phi`/`select` carries the Bennett-cc0 M2b WIDTH-0 SENTINEL —  │
#   │ its routing is recorded in `ptr_provenance` at LOWERING time rather  │
#   │ than as a value — so coercing one emits an `:or` identity over a     │
#   │ cell that was NEVER MATERIALISED, which ADR 0018 §E reads as 0.      │
#   │ The REACHABLE hazard is the ASYMMETRIC pair: if the walk can forward │
#   │ the OTHER side's load to that same phi, then canon agrees while one  │
#   │ cell holds φ(p) and the other holds 0. Native computes p − p = 0;    │
#   │ the VM computes 0 − φ(p) ≠ 0. A SILENT MISCOMPILE. Clause (i) is the │
#   │ only thing that closes it. DO NOT "simplify it away" as decorative:  │
#   │ `x − x = 0` is true of the THEOREM and says nothing about two cells. │
#   └──────────────────────────────────────────────────────────────────────┘
const _VI_M = _VI_DL * """
define i64 @vi_phi(ptr %task, ptr %tag, ptr %mem, i1 %c) {
top:
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  br i1 %c, label %L1, label %L2
L1:
  br label %J
L2:
  br label %J
J:
  %ph = phi ptr [ %md, %L1 ], [ %mem, %L2 ]
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %ph, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %ph to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL

# (N) RED — CLAUSE (iv). The forwarded store's target is a pointer function
# ARGUMENT, which `_p06b_cell_ptr_target_kind` does not certify as a cell
# pointer: nothing reserved the cells that store would write, so the "copy step"
# the walk reasons about is not one the extraction materialises. §4a clause
# (i)'s own disclosure — "does not provide sentinel-freedom for load-sourced
# values" — is this hole one hop up, and clause (iv) is what closes it.
# PREDICATE-level: the p06b store arm rejects this shape first, so the MESSAGE
# would name Bennett-p06b and prove nothing about §4b.
const _VI_N = _VI_DL * """
define i64 @vi_uncert(ptr %mem, ptr %box) {
top:
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  store { ptr, ptr } %ref, ptr %box, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %box, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  ret i64 %d
}
""" * _VI_DECL

# (O) RED — the stored aggregate is a `load` of a `{ptr,ptr}`, not an
# `insertvalue` chain, so the chain does not yield an operand for the field and
# the walk gives up. Fails CLOSED, to the pre-existing wall.
const _VI_O = replace(_VI_A,
    "  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0\n" *
    "  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1\n" =>
    "  %ref = load { ptr, ptr }, ptr %mem, align 8\n")

# (C3) RED — THE SELF-STORE FAIL-OPEN. HOSTILE REVIEW D1, P0, EXECUTED.
#
# `store ptr %a, ptr %a` writes the alloca's OWN ADDRESS into itself, so
# `%p = load ptr, ptr %a` IS `%a` under another name. The non-escape scan used
# to check only the store's ADDRESS operand, so `%a` was reported non-escaping;
# `%p` classifies `:other`; `_57hd_roots_disjoint(%a, %p)` returned TRUE; and
# the later `store ptr %junk, ptr %a` — a write straight through the alias —
# was SKIPPED by the clobber scan, forwarding `%f0` to `%md`.
#
#     MEASURED ON BennettVM BEFORE THE FIX (probe3_vm.jl): the admitted `sub`
#     evaluated to **64**, against an ADR 0017 §4b guarantee of 0 in BOTH
#     worlds, and it escaped into a `gc_alloc_obj` size operand. This is the
#     only executed counterexample this contract has ever had.
#
# The gate asserts BOTH halves — the helper AND the predicate — because the
# helper is the thing a future edit would "simplify".
const _VI_C3 = _VI_DL * """
define i64 @vi_selfstore(ptr %task, ptr %tag) {
entry:
  %a = alloca ptr, align 8
  store ptr %a, ptr %a, align 8
  br label %top
top:
  %mem  = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 16, ptr %tag)
  %data = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %junk = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 32, ptr %tag)
  %dg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  store ptr %data, ptr %dg, align 8
  %p = load ptr, ptr %a, align 8
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  store ptr %md, ptr %p, align 8
  store ptr %junk, ptr %a, align 8
  %f0 = load ptr, ptr %p, align 8
  %q = alloca ptr, align 8
  store ptr %md, ptr %q, align 8
  %g0 = load ptr, ptr %q, align 8
  %x = ptrtoint ptr %f0 to i64
  %y = ptrtoint ptr %g0 to i64
  %d = sub i64 %x, %y
  ret i64 %d
}
""" * _VI_DECL

# (D4) RED — OPERAND BUNDLES. HOSTILE REVIEW D2.
#
# `@vi_pure` is TRUTHFULLY declared `memory(none)`, but the call carries a
# `[ "jl_roots"(ptr %junk) ]` bundle. LLVM's own `CallBase::getMemoryEffects()`
# ORs in `writeOnly()` for a clobbering bundle; reading the RAW `memory`
# ATTRIBUTE alone believes the declaration about a call LLVM itself treats as a
# writer. Measured ADMITTED pre-fix (probe5.jl R1) — a direct contradiction of
# ADR 0017 §4b's "every unmodelled effect terminates the analysis
# unsuccessfully". Bundles also shift the operand→parameter index mapping the
# `nocapture` scan relies on, so the same guard sits in both places.
const _VI_D4 = replace(_VI_A,
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n" =>
    "  call void @vi_pure2(ptr %obj) [ \"jl_roots\"(ptr %task) ]\n" *
    "  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0\n") *
    "\ndeclare void @vi_pure2(ptr) memory(none)\n"

# (D5) RED — UNDEF / POISON CANONICAL RESULTS. HOSTILE REVIEW D3(a).
#
# LLVM UNIQUES `undef`/`poison` per type, so two INDEPENDENT chains that both
# bottom out in `ptr poison` canonicalise to the SAME ref and (V2)'s equality
# passes for two values that are not equal — they are not even values. Measured
# `pred = x=>true, y=>true` pre-fix (probe4.jl Q2). The extraction happened to
# fail downstream in the Bennett-bjdg arm, i.e. THIS ARM'S SOUNDNESS SURFACE WAS
# COVERED BY ANOTHER ARM'S GUARD — which is exactly what a contract may not do.
const _VI_D5 = _VI_DL * """
define i64 @vi_poison(ptr %task, ptr %tag) {
top:
  %o1 = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %o2 = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr poison, 0
  store { ptr, ptr } %r0, ptr %o1, align 8
  %s0 = insertvalue { ptr, ptr } zeroinitializer, ptr poison, 0
  store { ptr, ptr } %s0, ptr %o2, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %o1, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %g0p = getelementptr inbounds { ptr, ptr }, ptr %o2, i32 0, i32 0
  %g0 = load ptr, ptr %g0p, align 8
  %x = ptrtoint ptr %f0 to i64
  %y = ptrtoint ptr %g0 to i64
  %d = sub i64 %x, %y
  ret i64 %d
}
""" * _VI_DECL

# (D5b) the same with `undef` rather than `poison` — both are uniqued.
const _VI_D5b = replace(_VI_D5, "ptr poison" => "ptr undef")

# (D6) RED — NEGATIVE mem-intrinsic LENGTH. HOSTILE REVIEW D3(b).
#
# `[off, off+n)` with `n < 0` is an INVERTED range: it is empty under the
# `h <= lo || l >= hi` non-overlap test, so every real write it covers would be
# skipped. Today the Bennett-37mt arm rejects such a memcpy before extraction
# reaches here — the PREDICATE is what this gate pins, for the same reason as
# (D5): the arm must not rest its own soundness on another arm's guard.
# The DST must be the TRACKED root at offset 0, or the fixture proves nothing:
# a negative length only matters where the inverted range would otherwise have
# OVERLAPPED. `[0, -8)` satisfies `h <= lo`, so without the guard the write is
# SKIPPED and the store-forward sails through; with it the footprint is
# `:unknown` and the walk stops.
const _VI_D6 = replace(_VI_A,
    "call void @llvm.memcpy.p0.p0.i64(ptr align 8 %sz, ptr align 8 %szp, i64 8, i1 false)" =>
    "call void @llvm.memcpy.p0.p0.i64(ptr align 8 %obj, ptr align 8 %sz, i64 -8, i1 false)")

# (T)/(T2) GREEN — LOOP SAFETY. HOSTILE REVIEW D5.
#
# The cluster's block is a LOOP BODY. No back-edge veto exists and none is
# needed: a basic block executes AS A STRAIGHT LINE ON EVERY ENTRY, so every
# fact the walker establishes is per-iteration, and the load reads what the
# store wrote IN THAT SAME ITERATION. (V2) additionally forces `%S`/`%T` into
# this block, and a value carried across a back edge can only arrive through a
# `phi`, which (V0) refuses outright — so the two sources are always
# same-iteration. (T2) is the proof that the phi route really is closed.
const _VI_T = _VI_DL * """
define i64 @vi_loop(ptr %task, ptr %tag, ptr %mem, i64 %n) {
entry:
  br label %body
body:
  %i = phi i64 [ 0, %entry ], [ %i2, %body ]
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md = load ptr, ptr %mdp, align 8
  %r0 = insertvalue { ptr, ptr } zeroinitializer, ptr %md, 0
  %ref = insertvalue { ptr, ptr } %r0, ptr %mem, 1
  %obj = call noalias ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  store { ptr, ptr } %ref, ptr %obj, align 8
  %f0p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %f0 = load ptr, ptr %f0p, align 8
  %f1p = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %f1 = load ptr, ptr %f1p, align 8
  %md2p = getelementptr inbounds { i64, ptr }, ptr %f1, i32 0, i32 1
  %md2 = load ptr, ptr %md2p, align 8
  %a = ptrtoint ptr %f0 to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  %i2 = add i64 %i, 1
  %c = icmp slt i64 %i2, %n
  br i1 %c, label %body, label %done
done:
  ret i64 %d
}
""" * _VI_DECL

# (T2) RED — a LOOP-CARRIED pointer `phi` as a coercion source. The route by
# which a cross-iteration value could reach the cluster, closed by (V0).
const _VI_T2 = _VI_DL * """
define i64 @vi_loopphi(ptr %task, ptr %tag, ptr %mem, i64 %n) {
entry:
  %mdp0 = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md0 = load ptr, ptr %mdp0, align 8
  br label %body
body:
  %i = phi i64 [ 0, %entry ], [ %i2, %body ]
  %carry = phi ptr [ %md0, %entry ], [ %md2, %body ]
  %mdp = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %md2 = load ptr, ptr %mdp, align 8
  %a = ptrtoint ptr %carry to i64
  %b = ptrtoint ptr %md2 to i64
  %d = sub i64 %a, %b
  %i2 = add i64 %i, 1
  %c = icmp slt i64 %i2, %n
  br i1 %c, label %body, label %done
done:
  ret i64 %d
}
""" * _VI_DECL

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

function _vi_extract(name, ir, entry; cells=true)
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

function _vi_all_insts(pir)
    out = Any[]
    for b in pir.blocks
        append!(out, b.instructions)
        b.terminator === nothing || push!(out, b.terminator)
    end
    return out
end

# The `IRBinOp(dest, :or, <SSAOperand>, ConstOperand(0), 64)` cell identity —
# byte-identical to the node Bennett-583s and Bennett-foz5 emit. Rule 4: "did
# not throw" is not a pass; the gate must SEE the node.
function _vi_or(pir, dest::Symbol)
    for ins in _vi_all_insts(pir)
        if ins isa IRBinOp && ins.dest === dest && ins.op === :or && ins.width == 64 &&
           ins.op1 isa SSAOperand && ins.op2 isa ConstOperand && ins.op2.value == 0
            return ins
        end
    end
    return nothing
end

_vi_binop(pir, dest::Symbol, op::Symbol) =
    findfirst(i -> i isa IRBinOp && i.dest === dest && i.op === op, _vi_all_insts(pir))

# DIRECT predicate probe: evaluates `_57hd_value_identity_cluster` on every
# `ptrtoint` in `ir`, returning `name => verdict`. Lets the gates that the ARM
# would reject for an EARLIER reason (width, an uncertified store target) assert
# what the PREDICATE decided — a message can coincide for the wrong reason.
# EVERY instruction, named or not — the state the arm actually sees.
#
# MEASURED TRAP, cost one cycle: the corpus's `%13` coerces `%7`, an UNNAMED
# instruction, for which `LLVM.name` returns `""`. A probe that registers only
# non-empty names therefore makes `_57hd_certified`'s `haskey(names, …)` FALSE
# and reports `vi = false` for the very cluster the shipped pipeline admits.
# The emission walk registers every instruction (`_auto_name`), so a probe that
# filters is measuring a program the extractor never runs.
function _vi_names_of(f)
    names = Dict{Bennett._LLVMRef, Symbol}()
    for bb in Bennett.LLVM.blocks(f), i in Bennett.LLVM.instructions(bb)
        names[i.ref] = Symbol(Bennett.LLVM.name(i))
    end
    return names
end

function _vi_predicate_probe(ir::AbstractString, entry::AbstractString)
    out = Dict{Symbol, Bool}()
    Bennett.LLVM.Context() do _ctx
        mod = parse(Bennett.LLVM.Module, String(ir))
        try
            f = Bennett.LLVM.functions(mod)[entry]
            names = _vi_names_of(f)
            supp = Set{Bennett._LLVMRef}()
            for bb in Bennett.LLVM.blocks(f), i in Bennett.LLVM.instructions(bb)
                Bennett.LLVM.opcode(i) == Bennett.LLVM.API.LLVMPtrToInt || continue
                out[Symbol(Bennett.LLVM.name(i))] =
                    Bennett._57hd_value_identity_cluster(i, names, supp, true)
            end
        finally
            Bennett.LLVM.dispose(mod)
        end
    end
    return out
end

# The gated corpus path (the six advanced markers' own driver).
_push57hd(n::Int64) = begin
    v = Int64[]; push!(v, n); @inbounds v[1]
end

# The three shipped/new contracts evaluated on EVERY `sub(ptrtoint, ptrtoint)`
# in one LLVM body, keyed by BLOCK NAME (never by SSA number — those drift
# between processes). `names` is every named instruction and `suppressed` is
# empty, which is the state the arm sees for these clusters.
function _vi_partition_of(ir::AbstractString, entry::AbstractString)
    rows = Dict{Symbol, NamedTuple{(:s583, :foz5, :vi), Tuple{Bool, Bool, Bool}}}()
    Bennett.LLVM.Context() do _ctx
        mod = parse(Bennett.LLVM.Module, String(ir))
        try
            f = Bennett.LLVM.functions(mod)[entry]
            dead = Bennett._vec_vm_dead_blocks(f)
            names = _vi_names_of(f)
            supp = Set{Bennett._LLVMRef}()
            for bb in Bennett.LLVM.blocks(f), s in Bennett.LLVM.instructions(bb)
                Bennett.LLVM.opcode(s) == Bennett.LLVM.API.LLVMSub || continue
                ops = Bennett.LLVM.operands(s)
                length(ops) == 2 || continue
                all(o -> o isa Bennett.LLVM.Instruction &&
                         Bennett.LLVM.opcode(o) == Bennett.LLVM.API.LLVMPtrToInt,
                    ops) || continue
                # A cluster's verdict is the verdict on BOTH coercions: an arm
                # that admits one and not the other clears nothing (gate (P)).
                v583 = all(pt -> Bennett._verify_memdata_bounds_cluster(
                                     pt, Bennett.LLVM.operands(pt)[1]), ops)
                vfoz = all(pt -> Bennett._foz5_confined_dead_bounds(
                                     pt, names, supp, dead), ops)
                vvi  = all(pt -> Bennett._57hd_value_identity_cluster(
                                     pt, names, supp, true), ops)
                rows[Symbol(Bennett.LLVM.name(bb))] =
                    (s583 = v583, foz5 = vfoz, vi = vvi)
            end
        finally
            Bennett.LLVM.dispose(mod)
        end
    end
    return rows
end

# The ROOT body, as the extractor itself parses it (`optimize=false`,
# `dump_module=true` — the addrspaces are already stripped, so this is the same
# text `extract_parsed_ir_set_from_julia` walks).
function _vi_root_ir()
    s = Bennett._code_llvm_by_sig(Base.signature_type(_push57hd, Tuple{Int64});
                                  optimize = false, dump_module = true,
                                  debuginfo = :none)
    m = match(r"define [^\n]*@(julia__push57hd_\d+)\(", s)
    m === nothing && error("test_57hd: no `julia__push57hd_N` definition in the " *
                           "root module dump — the corpus driver changed shape")
    return (s, String(m.captures[1]))
end

# The `_growend!` CLOSURE body, reached through the SAME instance-less-callee
# route Bennett-40ys ships (`transitive_callees` + `_code_llvm_by_sig`), so this
# gate does not hardcode a `Base.var"#_growend!##0#..."` type name that Julia is
# free to rename. Version-OBSERVATIONAL by design: it asserts the contracts'
# verdicts on whatever body the closure key emits today.
function _vi_growend_ir()
    hits = [(k, at) for (k, at) in Bennett.transitive_callees(_push57hd, Tuple{Int64})
            if k isa Type && !(k <: Type) && !isdefined(k, :instance)]
    length(hits) == 1 || error("test_57hd: expected exactly one instance-less " *
                               "callee under `push!`, got $(length(hits)) — the " *
                               "corpus shape changed")
    k, at = hits[1]
    s = Bennett._code_llvm_by_sig(Bennett._spectypes_of(k, at);
                                  optimize = false, dump_module = true,
                                  debuginfo = :none)
    m = match(r"define [^\n]*@\"(julia_#_growend!##0_\d+)\"\(", s)
    m === nothing && error("test_57hd: no `_growend!` definition in the closure " *
                           "module dump — the corpus driver changed shape")
    return (s, String(m.captures[1]))
end

@testset "Bennett-57hd CW-D: VALUE-IDENTITY contract (ADR 0017 §4b)" begin

    # =======================================================================
    # (A) GREEN — the corpus shape. BOTH ptrtoints lower to the `:or` cell
    # identity; the `sub` and the `udiv exact` survive VERBATIM (nothing is
    # fabricated — Bennett-lbot, reaffirmed).
    # =======================================================================
    @testset "(A) GREEN — corpus-shaped value identity" begin
        st, pir = _vi_extract("vi_A", _VI_A, "vi")
        @test st === :ok
        if st === :ok
            @test _vi_or(pir, :a) !== nothing
            @test _vi_or(pir, :b) !== nothing
            @test _vi_binop(pir, :d, :sub) !== nothing
            @test _vi_binop(pir, :idx, :udiv) !== nothing
        end
    end

    @testset "(A2) GREEN — `sub` operands swapped (symmetry)" begin
        st, pir = _vi_extract("vi_A2", _VI_A2, "vi")
        @test st === :ok
        st === :ok && @test _vi_or(pir, :a) !== nothing
        st === :ok && @test _vi_or(pir, :b) !== nothing
    end

    # =======================================================================
    # (P) THE PAIR PIN. The predicate must hold for BOTH coercions, and the
    # new disjunct must be added to the arm's ENTRY as well as its ADMISSION.
    #
    # MEASURED COUNTEREXAMPLE (`.ll` surgery on the real corpus, admitting only
    # `%12` and leaving `%13`): the extraction walls on `%13` in the JBKO arm —
    # "found a use that is a `sub`, not an icmp" — because `%13`'s source has
    # `_memdata_root === nothing` and fails §4a clause (iii). Without the ENTRY
    # disjunct this bead clears NOTHING. Do not remove either half.
    # =======================================================================
    @testset "(P) PIN — the predicate holds for BOTH coercions of the pair" begin
        p = _vi_predicate_probe(_VI_A, "vi")
        @test get(p, :a, false) === true
        @test get(p, :b, false) === true
    end

    @testset "(B) RED — cross-allocation difference" begin
        st, msg = _vi_extract("vi_B", _VI_B, "vi_cross")
        @test st === :err
        st === :err && @test occursin("Bennett-57hd", msg)
        st === :err && @test occursin("_57hd_value_identity_cluster", msg)
        @test get(_vi_predicate_probe(_VI_B, "vi_cross"), :a, true) === false
    end

    @testset "(C) RED — clobbering store inside the window" begin
        st, msg = _vi_extract("vi_C", _VI_C, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_C, "vi"), :a, true) === false
    end

    @testset "(C2) RED — variable-index GEP write into the tracked object" begin
        # The reload of `%f0p` must NOT be forwarded across the variable-GEP
        # store: `%vg` is `%box + %i`, so it may hit `[0,8)`. Pre-fix the
        # `:alloca` non-escape rule declared it disjoint and the walk sailed
        # through — the one unsoundness this arc found by REVIEW, not by probe.
        @test get(_vi_predicate_probe(_VI_C2, "vi_vgep"), :a, true) === false
    end

    @testset "(D) RED — intervening call with NO `memory` attribute" begin
        st, msg = _vi_extract("vi_D", _VI_D, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_D, "vi"), :a, true) === false
    end

    # THE O-1 DECODE CANARIES. (D2) and (D3) must move in OPPOSITE directions.
    # A decoder that fails closed on everything passes (D)+(D2) and fails (D3);
    # a decoder that reads "writes nothing" for everything passes (D3) and fails
    # (D2). Only a correct decode passes both.
    @testset "(D2) RED — O-1 canary: `memory(argmem: readwrite)` is a WRITER" begin
        st, msg = _vi_extract("vi_D2", _VI_D2, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_D2, "vi"), :a, true) === false
    end

    @testset "(D3) GREEN — O-1 canary: `memory(none)` is READ and BELIEVED" begin
        st, pir = _vi_extract("vi_D3", _VI_D3, "vi")
        @test st === :ok
        @test get(_vi_predicate_probe(_VI_D3, "vi"), :a, false) === true
    end

    @testset "(E) RED — allocator without the `noalias` return attribute" begin
        st, msg = _vi_extract("vi_E", _VI_E2, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_E2, "vi"), :a, true) === false
    end

    @testset "(F2) RED — `nocapture` on neither call site nor declaration" begin
        st, msg = _vi_extract("vi_F2", _VI_F2, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_F2, "vi"), :a, true) === false
    end

    @testset "(F3) GREEN — `nocapture` on the CALLEE DECLARATION only" begin
        # THE CORPUS SPELLING. A call-site-only check fails here and therefore
        # fails the corpus.
        st, pir = _vi_extract("vi_F3", _VI_F3, "vi")
        @test st === :ok
        @test get(_vi_predicate_probe(_VI_F3, "vi"), :a, false) === true
    end

    @testset "(F4) GREEN — `nocapture` at the CALL SITE only" begin
        st, pir = _vi_extract("vi_F4", _VI_F4, "vi")
        @test st === :ok
        @test get(_vi_predicate_probe(_VI_F4, "vi"), :a, false) === true
    end

    @testset "(G) RED — same-root non-overlap judgement off the byte tier" begin
        st, msg = _vi_extract("vi_G", _VI_G, "vi_word")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_G, "vi_word"), :a, true) === false
    end

    @testset "(G2) GREEN — word tier, no same-root judgement required" begin
        st, pir = _vi_extract("vi_G2", _VI_G2, "vi_word")
        @test st === :ok
        @test get(_vi_predicate_probe(_VI_G2, "vi_word"), :a, false) === true
    end

    @testset "(H) RED — jb6w: C-tier pair holding two DIFFERENT pointers" begin
        st, msg = _vi_extract("vi_H", _VI_H, "vi_ctier")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_H, "vi_ctier"), :a, true) === false
    end

    @testset "(H2) GREEN — C-tier pair holding ONE pointer twice" begin
        st, pir = _vi_extract("vi_H2", _VI_H2, "vi_ctier")
        @test st === :ok
        @test get(_vi_predicate_probe(_VI_H2, "vi_ctier"), :a, false) === true
    end

    @testset "(I) RED — SCOPE BOUNDARY: cross-block reload" begin
        st, msg = _vi_extract("vi_I", _VI_I, "vi_xblock")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_I, "vi_xblock"), :a, true) === false
    end

    @testset "(J) RED — SCOPE BOUNDARY: opaque call between write and reload" begin
        st, msg = _vi_extract("vi_J", _VI_J, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_J, "vi"), :a, true) === false
    end

    @testset "(K) RED — the coerced value escapes into an `add`" begin
        st, msg = _vi_extract("vi_K", _VI_K, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_K, "vi"), :a, true) === false
    end

    @testset "(L) RED — non-64-bit coercion/`sub` pair (PREDICATE)" begin
        @test get(_vi_predicate_probe(_VI_L, "vi"), :a, true) === false
    end

    @testset "(M) RED — PointerType `phi` source (WIDTH-0 SENTINEL)" begin
        st, msg = _vi_extract("vi_M", _VI_M, "vi_phi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_M, "vi_phi"), :a, true) === false
        @test get(_vi_predicate_probe(_VI_M, "vi_phi"), :b, true) === false
    end

    @testset "(N) RED — CLAUSE (iv): store target is not a certified cell" begin
        @test get(_vi_predicate_probe(_VI_N, "vi_uncert"), :a, true) === false
    end

    @testset "(O) RED — stored aggregate is a `load`, not an insertvalue chain" begin
        st, msg = _vi_extract("vi_O", _VI_O, "vi")
        @test st === :err
        @test get(_vi_predicate_probe(_VI_O, "vi"), :a, true) === false
    end

    # =======================================================================
    # HOSTILE-REVIEW GATES. Every one of these is a fail-OPEN that the arm
    # closed only after the review; (C3) is the sole EXECUTED counterexample
    # this contract has ever had.
    # =======================================================================
    @testset "(C3) RED — D1: `store ptr %a, ptr %a` self-store fail-open" begin
        p = _vi_predicate_probe(_VI_C3, "vi_selfstore")
        @test get(p, :x, true) === false
        @test get(p, :y, true) === false
        # ... and the HELPER itself, because that is what a future edit touches.
        Bennett.LLVM.Context() do _c
            mod = parse(Bennett.LLVM.Module, String(_VI_C3))
            try
                f = Bennett.LLVM.functions(mod)["vi_selfstore"]
                byname = Dict{String, Any}()
                for bb in Bennett.LLVM.blocks(f), i in Bennett.LLVM.instructions(bb)
                    n = Bennett.LLVM.name(i); isempty(n) || (byname[n] = i)
                end
                @test Bennett._57hd_alloca_noescape(byname["a"]) === false
                @test Bennett._57hd_roots_disjoint(byname["a"].ref,
                                                   byname["p"].ref) === false
                # the sibling alloca `%q` is a CLEAN one — the gate is not
                # vacuously rejecting every alloca.
                @test Bennett._57hd_alloca_noescape(byname["q"]) === true
            finally
                Bennett.LLVM.dispose(mod)
            end
        end
    end

    @testset "(D4) RED — D2: a `memory(none)` call with an operand bundle" begin
        @test get(_vi_predicate_probe(_VI_D4, "vi"), :a, true) === false
        st, msg = _vi_extract("vi_D4", _VI_D4, "vi")
        @test st === :err
    end

    @testset "(D5) RED — D3a: `poison` / `undef` canonical results" begin
        @test get(_vi_predicate_probe(_VI_D5, "vi_poison"), :x, true) === false
        @test get(_vi_predicate_probe(_VI_D5, "vi_poison"), :y, true) === false
        @test get(_vi_predicate_probe(_VI_D5b, "vi_poison"), :x, true) === false
        @test get(_vi_predicate_probe(_VI_D5b, "vi_poison"), :y, true) === false
    end

    @testset "(D6) RED — D3b: a NEGATIVE mem-intrinsic length" begin
        @test get(_vi_predicate_probe(_VI_D6, "vi"), :a, true) === false
    end

    @testset "(T) GREEN — the cluster inside a LOOP BODY is still admitted" begin
        # No back-edge veto exists and none is needed: a basic block executes
        # as a straight line on every entry, so the walker's facts are
        # per-iteration. Adding a veto here would be a regression, not a fix.
        @test get(_vi_predicate_probe(_VI_T, "vi_loop"), :a, false) === true
        @test get(_vi_predicate_probe(_VI_T, "vi_loop"), :b, false) === true
    end

    @testset "(T2) RED — a LOOP-CARRIED pointer `phi` source is refused" begin
        # The only route by which a CROSS-ITERATION value could reach the
        # cluster. (V0) closes it, which is what makes (T) safe.
        @test get(_vi_predicate_probe(_VI_T2, "vi_loopphi"), :a, true) === false
    end

    # =======================================================================
    # (Z) BYTE IDENTITY — the admission lives inside the `ptr_cells` gate.
    # =======================================================================
    @testset "(Z) BYTE-IDENTITY — ptr_cells=false and the circuit tier" begin
        st, msg = _vi_extract("vi_Z", _VI_A, "vi"; cells=false)
        @test st === :err
        # The pre-existing gate-off wall, NOT a §4b message.
        st === :err && @test !occursin("Bennett-57hd", msg)
        # The circuit path never sees `ptr_cells`; gate counts are byte-identical.
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test gate_count(c).total == 58
        @test verify_reversibility(c)
    end

    # =======================================================================
    # (S) THE STEAL / PARTITION TABLE — obligation (c), over BOTH corpus
    # bodies, asserted cell-for-cell.
    #
    # THIS IS THE GATE CLASS THAT FOUND THE FINDING. The scout's coverage
    # framing ("α covers 1 of 3, δ′ covers 3 of 3") came from comparing two
    # PROTOTYPES against `_memdata_root`; nobody evaluated the SHIPPED
    # `_foz5_confined_dead_bounds` on `%L21` / `%L43`. It admits both. A
    # table-shaped gate catches that; a prose claim does not. Keep it a TABLE.
    #
    # NON-STEAL IS STRUCTURAL, not ordering-dependent: §4b admits only when the
    # two coerced pointers are the SAME VALUE, i.e. only when the difference is
    # IDENTICALLY ZERO. Every 583s and every §4a corpus cluster differences a
    # pointer against the same pointer PLUS A RUNTIME BYTE OFFSET, which the
    # canonicaliser cannot and does not collapse.
    #
    # THE GENERALISATION THAT WAS MEASURED AND REJECTED (`α_k`): strip
    # `getelementptr i8` chains, canonicalise the BASES, conclude
    # `sub ≡ Σ displacements`. Measured over both bodies: it claims `%L46` and
    # `%L58` — BOTH clusters Bennett-583s owns — and gains ZERO new clusters
    # (still false on `%L21`/`%L43`, because the barrier is the CALL, not the
    # displacement). It costs the theorem (it re-acquires 583s's byte-tier
    # dependence) and buys nothing. DISPLACEMENT ZERO IS THE DESIGN. See the
    # NON-GOAL paragraph in ADR 0017 §4b before "improving" this.
    # =======================================================================
    @testset "(S) STEAL — the three-way corpus partition, cell for cell" begin
        rir, rfn = _vi_root_ir()
        root = _vi_partition_of(rir, rfn)
        @test length(root) == 3
        @test root[:top] == (s583 = false, foz5 = false, vi = true)   # WALL 10 — ours
        @test root[:L21] == (s583 = false, foz5 = true,  vi = false)  # §4a already owns it
        @test root[:L43] == (s583 = false, foz5 = true,  vi = false)  # §4a already owns it

        gir, gfn = _vi_growend_ir()
        grow = _vi_partition_of(gir, gfn)
        @test length(grow) == 3
        @test grow[:L46]      == (s583 = true,  foz5 = true, vi = false)  # 583s owns it
        @test grow[:L58]      == (s583 = true,  foz5 = true, vi = false)  # 583s owns it
        @test grow[:idxend41] == (s583 = false, foz5 = true, vi = false)  # §4a owns it

        # THE NON-STEAL, stated as an invariant rather than as six cells: §4b
        # claims EXACTLY ONE cluster in the whole two-body corpus, and it is
        # the only cluster no shipped contract claims.
        allrows = collect(values(root)); append!(allrows, values(grow))
        @test count(r -> r.vi, allrows) == 1
        @test all(r -> !(r.vi && (r.s583 || r.foz5)), allrows)
    end

    # =======================================================================
    # (W) CORPUS — walls 10 AND 11 are CLEARED; the chain advances to wall 12.
    #
    # ┌──────────── §4b IS *USED* BY WALL 11'S FIX, NOT CHANGED ───────────────┐
    # │ Bennett-5viz (xkl wall 11) certifies the loaded-`ptr` (`.mem`) memcpy   │
    # │ SRC by composing THIS FILE'S machinery — `_57hd_insertvalue_field` to   │
    # │ strip the `extractvalue`, then `_57hd_canon` to reduce the result to    │
    # │ the empty-`GenericMemory` SINGLETON's `.globals` root — with ZERO       │
    # │ change to §4b itself. THAT IS THE TRIPWIRE: if any gate in this file    │
    # │ moves, the 5viz arc has drifted into §4b and its REDUCED verdict is     │
    # │ void. Every other gate here must stay green UNCHANGED; only this        │
    # │ corpus marker advances.                                                │
    # │                                                                        │
    # │ NOTE THE FLIP: the `!occursin("SILENTLY SKIPS")` line this gate used to │
    # │ carry (wall 12 "must not appear yet") is now a POSITIVE — wall 12 IS    │
    # │ that reject.                                                           │
    # └────────────────────────────────────────────────────────────────────────┘
    # =======================================================================
    @testset "(W) CORPUS — walls 10/11 cleared, chain advances to wall 12" begin
        msg = try
            Bennett.extract_parsed_ir_set_from_julia(_push57hd, Tuple{Int64};
                                                     ptr_cells=true)
            ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test msg != ""
        # Wall 10 is CLEARED: a 583s / foz5 / 57hd reject in the ROOT body is
        # now a REGRESSION, not the expected wall.
        @test !occursin("base-cancelling", msg)
        @test !occursin("_foz5_confined_dead_bounds", msg)
        @test !occursin("_57hd_value_identity_cluster", msg)
        # ===================== WALL 11 CLEARED — Bennett-5viz =====================
        # POSITIVE, wall 12 — `Bennett-p06b`'s OWN reject: the
        # `alloca { ptr, ptr }` whose allocated type the alloca arm SILENTLY
        # SKIPS, so nothing ever reserved the cells the aggregate store at `%L16`
        # would write. THE `!occursin("SILENTLY SKIPS")` LINE THIS GATE USED TO
        # CARRY IS NOW THIS POSITIVE — it flipped, it was not deleted.
        @test occursin("Bennett-p06b", msg)
        @test occursin("_p06b_cell_ptr_target_kind", msg)
        @test occursin("SILENTLY SKIPS", msg)
        # ┌────────── THE `.mem` SUFFIX TRAP — MEASURED, DO NOT SHORTEN ───────────┐
        # │ The wall-11 discriminator INVERTS: a `Bennett-37mt` / `-8bys` src      │
        # │ reject at the corpus is now a REGRESSION, and this negative is         │
        # │ STRONGER than the operand-name pair it replaces (it does not depend on │
        # │ which operand the `_ir_error` prefix quotes). BUT wall 12's message    │
        # │ DOES contain `new::Array.ref` — it quotes                              │
        # │ `store { ptr, ptr } %"new::Array.ref", …` — and does NOT contain       │
        # │ `new::Array.ref.mem`. KEEP THE `.mem` SUFFIX; dropping it turns the    │
        # │ line RED. Check discriminators against the MESSAGE TEXT, never against │
        # │ the IR (the Bennett-sy29 lesson, applied to its own successor).        │
        # └────────────────────────────────────────────────────────────────────────┘
        @test !occursin("Bennett-37mt", msg)
        @test !occursin("new::Array.ref.mem", msg)
        @test !occursin("Bennett-5viz", msg)
        # NOTE for whoever clears wall 12, all MEASURED at the wall-12 text:
        # its own message contains NEITHER `Bennett-1zow` NOR
        # `_p06b_granularity_violation`. Wall 13 is a SECOND 37mt/8bys memcpy
        # (`memcpy operand alloca has non-integer element type`, corpus site #5),
        # so `!occursin("Bennett-37mt")` flips back to a positive one wall later.
        # Wall 14 is the bvmd `SCALE-COHERENCE` reject on the 9×i64 closure
        # alloca and PRE-EXISTS 5viz (raised by the shipped site-#3 memcpy's word
        # stamp) — deferred to the `Bennett-bvmd` family arc.
        @test !occursin("SCALE-COHERENCE", msg)
        # Walls 3/5/6/7/8/9 stay cleared.
        @test !occursin("Bennett-jbko", msg)
        @test !occursin("Bennett-iwo9", msg)
        @test !occursin("Bennett-lgzx", msg)
        @test !occursin("Bennett-bvmd", msg)
        @test !occursin("BYTE-granular getelementptr", msg)
        @test !occursin("store of non-integer type", msg)
        @test !occursin("ConcurrencyViolation", msg)
        @test !(occursin("Bennett-583s", msg) && occursin("_growend!", msg))
        @test !(occursin("Bennett-p06b", msg) && occursin("gc_alloc_obj", msg))
    end
end
