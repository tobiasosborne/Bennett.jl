; Bennett-p06b / CW-D (ADR 0017 CW-D workstream) — whole-aggregate `store`
; decomposition fixtures (`bennettvm-xkl` wall 6, extraction side).
;
; Under the closed-world `ptr_cells` gate a
;   `store <S> %agg, ptr %p`      (S an unpacked StructType of N 64-bit fields)
; decomposes into, for each field k,
;   IRExtractValue(fk, <agg>, k, 0, N, field_widths)
;   IRPtrOffset(ak, <p>, LLVMOffsetOfElement(S, k), 64)
;   IRStore(ssa(ak), ssa(fk), 64)
; — i.e. EXACTLY the field-wise spelling the extractor already admits (the
; Bennett-6bu3 extractvalue arm + the BVM ADR 0020 D4 two-index struct-GEP arm
; + the Bennett-ares/beaw `store ptr` cell arm). No new IRInst, no new BVM
; opcode. Under `ptr_cells=false` nothing here is admitted and the pre-existing
; Bennett-lgzx / U114 reject fires byte-identically.
;
; EXPLICIT `target datalayout` (Bennett-p06b implementer gotcha, from
; proposal_A §2.2 probe 9): with NO datalayout LLVM's default gives `i64` ABI
; alignment 4, which moves struct members off their Julia/x86-64 offsets and
; makes offset assertions test the wrong layout. The long x86-64 string with
; `p270:0:32` is REJECTED by this LLVM ("Invalid pointer size of 0 bytes"), so
; the short canonical form below is the one to use.

target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

%struct.p06bT = type { i64, ptr }

declare ptr @malloc(i64)
declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)

@p06b_g = global [2 x ptr] zeroinitializer

; ===========================================================================
; ADMIT — the CORPUS shape. Target is a `load ptr` (the GC-roots read in
; `_growend!` `%L93`); value is an `insertvalue` chain. The two read-back
; struct GEPs are the CELL-AGREEMENT witness: the D4 arm stamps them
; `(0, 64)` / `(8, 64)`, and p06b's stores must carry the IDENTICAL pairs.
; ===========================================================================
define i64 @p06b_load_target(ptr %root, ptr %a, ptr %b) {
entry:
  %slot = load ptr, ptr %root, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %f0 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 0
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 1
  %r0 = load i64, ptr %f0, align 8
  %r1 = load i64, ptr %f1, align 8
  %s = add i64 %r0, %r1
  ret i64 %s
}

; ===========================================================================
; ADMIT — general N (three fields at 0/8/16). This is the fixture a
; "restrict to exactly two pointer fields" refactor cannot pass.
; ===========================================================================
define i64 @p06b_3x64(i64 %x, i64 %y, i64 %z) {
entry:
  %slot = alloca i64, i32 3, align 8
  %t0 = insertvalue { i64, i64, i64 } zeroinitializer, i64 %x, 0
  %t1 = insertvalue { i64, i64, i64 } %t0, i64 %y, 1
  %agg = insertvalue { i64, i64, i64 } %t1, i64 %z, 2
  store { i64, i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; ADMIT / GATE WITNESS — every field is a plain i64, so `_struct_field_widths`
; certifies the `insertvalue`s at BOTH gate settings and the ONLY
; ptr_cells-dependent construct in the function is the aggregate STORE itself.
; (A `{ptr,ptr}` fixture would reject EARLIER, at the 6bu3 pointer-field guard
; on the `insertvalue`, and so would NOT witness that the STORE arm is gated.)
; ===========================================================================
define i64 @p06b_2x64_gate(i64 %x, i64 %y) {
entry:
  %slot = alloca i64, i32 2, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; ADMIT — `call`-returning-pointer target (the arena/`malloc` cell). Doubles
; as the POSITIVE CONTROL for the granularity guard below: same shape, but
; with NO byte-granular GEP on the target object.
; ===========================================================================
define i64 @p06b_call_target(ptr %a, ptr %b) {
entry:
  %slot = call ptr @malloc(i64 16)
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 1
  %r1 = load i64, ptr %f1, align 8
  ret i64 %r1
}

; ===========================================================================
; ADMIT — MODELLED `alloca ptr, i32 2` target (the ADR 0020 D5c arm emits a
; real `IRAlloca(_, 64, 2)`). The positive half of the (P4) whitelist: the
; guard is NOT vacuous.
; ===========================================================================
define i64 @p06b_alloca_ptr_target(ptr %a, ptr %b) {
entry:
  %slot = alloca ptr, i32 2, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P4) — pointer ARGUMENT target, DEFERRED. `module_walk.jl` gives a
; pointer parameter TWO models: `dereferenceable(N) > 0` is the Julia
; NTuple-by-ref FLAT WIRE ARRAY (N*8 bits, recorded in `ptr_params`), while
; `deref == 0` is the ADR 0020 D2 opaque Int64 cell-address. Only the second is
; a cell, and the sret parameter is separately claimed by the dv1z pre-walk.
; Rather than encode that three-way discrimination on no corpus witness, p06b
; refuses argument targets outright and names the deferral.
; ===========================================================================
define i64 @p06b_arg_target(ptr %slot, ptr %a, ptr %b) {
entry:
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; ADMIT — a NAMED `%struct.p06bT = type { i64, ptr }`. Same field shape as the
; Julia GenericMemory header but NOT a literal struct, so
; `_is_genericmemory_header_struct` is false and the word-granular (64) stamp
; applies — exactly as the D4 GEP arm already discriminates for the C tier
; (test_haiy / test_nd45 pins). This is the discriminator test for (P1).
; ===========================================================================
define i64 @p06b_named_struct(i64 %len, ptr %d) {
entry:
  %slot = alloca ptr, i32 2, align 8
  %t0 = insertvalue %struct.p06bT zeroinitializer, i64 %len, 0
  %agg = insertvalue %struct.p06bT %t0, ptr %d, 1
  store %struct.p06bT %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; ADMIT — SELF-REFERENTIAL: the store target is ALSO stored as field 1. Pins
; that store ORDER is immaterial: every field value is read from the SSA
; aggregate (registers), never from memory, so the N cell writes cannot
; observe each other.
; ===========================================================================
define i64 @p06b_self_ref(ptr %a) {
entry:
  %slot = call ptr @malloc(i64 16)
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %slot, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P1) — the LITERAL `{ i64, ptr }` Julia GenericMemory HEADER. The D4
; GEP arm stamps this ONE type BYTE-granular (elem_width = 8, CW-D4 /
; bennettvm-9n3y), so a word-granular (64) store would land on cells 0/1 while
; its own field GEPs land on byte-cells 0/8 — two cell maps for one object.
; Deliberately refused rather than mirrored (no live corpus witness).
; ===========================================================================
define i64 @p06b_hdr_literal(i64 %len, ptr %d) {
entry:
  %slot = alloca ptr, i32 2, align 8
  %t0 = insertvalue { i64, ptr } zeroinitializer, i64 %len, 0
  %agg = insertvalue { i64, ptr } %t0, ptr %d, 1
  store { i64, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P3) — SUB-CELL field layouts. `{i32,i32}` puts field 1 at byte
; offset 4; `{i64,i8}` / `{i8,i64}` have a field narrower than one cell.
; BVM's `MemoryStore` writes a WHOLE 64-bit cell, so a sub-cell field would
; need a read-modify-write of the surrounding cell that the cell model
; (ADR 0018 §A) does not express.
; ===========================================================================
define i64 @p06b_2x32(i32 %x, i32 %y) {
entry:
  %slot = alloca i64, i32 2, align 8
  %t0 = insertvalue { i32, i32 } zeroinitializer, i32 %x, 0
  %agg = insertvalue { i32, i32 } %t0, i32 %y, 1
  store { i32, i32 } %agg, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_i64_i8(i64 %x, i8 %y) {
entry:
  %slot = alloca i64, i32 2, align 8
  %t0 = insertvalue { i64, i8 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i8 } %t0, i8 %y, 1
  store { i64, i8 } %agg, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_i8_i64(i8 %x, i64 %y) {
entry:
  %slot = alloca i64, i32 2, align 8
  %t0 = insertvalue { i8, i64 } zeroinitializer, i8 %x, 0
  %agg = insertvalue { i8, i64 } %t0, i64 %y, 1
  store { i8, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT — the Bennett-6bu3 field-certification surface, INHERITED VERBATIM.
; p06b must NOT annex this territory: every one of these must keep naming
; Bennett-6bu3. Stored as `zeroinitializer` so the type check (which runs
; FIRST) is what rejects, not the value check.
; ===========================================================================
define i64 @p06b_packed(ptr %slot) {
entry:
  store <{ ptr, ptr }> zeroinitializer, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_empty(ptr %slot) {
entry:
  store { } zeroinitializer, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_i64_i1(ptr %slot) {
entry:
  store { i64, i1 } zeroinitializer, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_double_field(ptr %slot) {
entry:
  store { double, i64 } zeroinitializer, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_nested(ptr %slot) {
entry:
  store { { i64, i64 }, i64 } zeroinitializer, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT — target is a GLOBAL, i.e. NOT a registered SSA name. Reuses the
; PRE-EXISTING Bennett-lgzx / U114 registered-SSA message VERBATIM (Rule 12:
; do not mint new message territory for a condition the file already words).
; ===========================================================================
define i64 @p06b_global_target(ptr %a, ptr %b) {
entry:
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr @p06b_g, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P4) — the SILENT-ALLOCA hazard. `alloca { ptr, ptr }` has a
; StructType allocated type, which the alloca arm SILENTLY SKIPS (emits NO
; `IRAlloca`) while `module_walk.jl`'s naming pass has ALREADY registered the
; dest symbol. A naive `haskey(names, ptr.ref)` target guard therefore ADMITS
; this and hands BennettVM stores into a cell no allocation ever reserved.
; ===========================================================================
define i64 @p06b_alloca_struct_target(ptr %a, ptr %b) {
entry:
  %slot = alloca { ptr, ptr }, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P4) — a `phi ptr` / `select ptr` target carries the Bennett-cc0 M2b
; WIDTH-0 SENTINEL: its routing is recorded in `ptr_provenance` at LOWERING
; time rather than as a value, so `IRPtrOffset` off it would address a cell
; that was never materialised.
; ===========================================================================
define i64 @p06b_phi_target(i1 %c, ptr %p, ptr %q, ptr %a, ptr %b) {
entry:
  br i1 %c, label %t, label %f
t:
  br label %j
f:
  br label %j
j:
  %slot = phi ptr [ %p, %t ], [ %q, %f ]
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_select_target(i1 %c, ptr %p, ptr %q, ptr %a, ptr %b) {
entry:
  %slot = select i1 %c, ptr %p, ptr %q
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P5) — CELL-GRANULARITY SPLIT. The target object is addressed at
; BOTH byte granularity (`gep i8 %slot, 8` -> IRPtrOffset(_, _, 8, 8) -> BVM
; cell 8) AND word granularity (this store's struct fields -> cell 1). Two
; cells for one byte offset. Refusing to WRITE through one of two disagreeing
; cell maps (CW-D4 / bennettvm-9n3y; @p06b_call_target is the positive
; control — same shape WITHOUT the byte GEP).
; ===========================================================================
define i64 @p06b_granularity(ptr %a, ptr %b) {
entry:
  %slot = call ptr @malloc(i64 16)
  %byte8 = getelementptr inbounds i8, ptr %slot, i32 8
  store ptr null, ptr %byte8, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P6) — the VALUE operand must be an `insertvalue` INSTRUCTION, the
; only aggregate producer BennettVM's `agg_dests` registry certifies as
; carrying a per-slot family that a later `IRExtractValue` can read.
;   * `zeroinitializer` -> `_operand` yields the ZeroAggSentinel, which BVM's
;     ingest explicitly rejects for an extractvalue aggregate;
;   * `load { ptr, ptr }` -> no `IRInsertValue` ever defines the dest;
;   * `undef` -> a reversible VM cannot invent and later restore a value.
; ===========================================================================
define i64 @p06b_zeroinit_value(ptr %a) {
entry:
  %slot = alloca ptr, i32 2, align 8
  store { ptr, ptr } zeroinitializer, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_load_value(ptr %src) {
entry:
  %slot = alloca ptr, i32 2, align 8
  %agg = load { ptr, ptr }, ptr %src, align 8
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

define i64 @p06b_undef_value(ptr %a) {
entry:
  %slot = alloca ptr, i32 2, align 8
  store { ptr, ptr } undef, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT — an ArrayType aggregate store is NOT a StructType store: the p06b
; arm never sees it and the Bennett-lgzx / U114 text stands UNCHANGED at both
; gate settings.
; ===========================================================================
define i64 @p06b_array_store(ptr %a, ptr %b) {
entry:
  %slot = alloca ptr, i32 2, align 8
  %t0 = insertvalue [ 2 x ptr ] zeroinitializer, ptr %a, 0
  %agg = insertvalue [ 2 x ptr ] %t0, ptr %b, 1
  store [ 2 x ptr ] %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT — the Bennett-4mmt / U14 volatile and Bennett-ares strong-ordering
; guards PRECEDE the p06b arm and are untouched by it.
; ===========================================================================
define i64 @p06b_volatile(ptr %slot, ptr %a, ptr %b) {
entry:
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store volatile { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ###########################################################################
; ## Bennett-p06b HOSTILE REVIEW (2026-08-06) — the reviewer's repros, all  ##
; ## permanent gates. Each names the defect it closes.                      ##
; ###########################################################################

; ===========================================================================
; REJECT (P4c) D1 — CAPACITY. The target's producer emits an IRAlloca, but for
; ONE cell; a 2-field store writes cells 1 AND 2, clobbering the NEXT alloca.
; Executed witness (scratchpad e2e2.jl): EXPECTED 999, ACTUAL 42, NO ERROR.
; (P4) certified that an IRAlloca WOULD be emitted, never that it reserves >= N
; cells — a guarantee the message asserted and no predicate checked.
; ===========================================================================
define i64 @p06b_alloca_1cell(i64 %x, i64 %y) {
entry:
  %slot = alloca i64, align 8
  %spare = alloca i64, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; REJECT (P4c) D1 — the malloc tier of the same hazard (scratchpad e2e3.jl).
define i64 @p06b_malloc_1cell(i64 %x, i64 %y) {
entry:
  %slot = call ptr @malloc(i64 8)
  %other = call ptr @malloc(i64 8)
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; REJECT (P4c) D1 — a RUNTIME alloca count is not a static capacity proof.
define i64 @p06b_alloca_dyncount(i64 %n, i64 %x, i64 %y) {
entry:
  %slot = alloca i64, i64 %n, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; REJECT (P4c) D1 — `[16 x i8]` is MODELLED by the alloca arm but at
; elem_width 8: `IRAlloca(_, 8, 16)` reserves 16 BYTE cells, not 2 word cells,
; so the cell arithmetic of the decomposition does not apply to it.
define i64 @p06b_alloca_i8arr(i64 %x, i64 %y) {
entry:
  %slot = alloca [16 x i8], align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P5) D2 — GEP-OF-GEP through the dropped index-0 carve-out. The
; accepted 2-op index-0 GEP produced `IRPtrOffset(_, _, 0, 8)` — a FRESH
; BYTE-granular base that the one-level use scan never followed — and `%g8`
; then lands on byte-cell 8 while the store's field 1 lands on cell 1. Exactly
; the CW-D4 / 9n3y split (P5) exists to refuse. The carve-out is DROPPED.
; ===========================================================================
define i64 @p06b_gep_of_gep(ptr %root, ptr %a, ptr %b) {
entry:
  %slot = load ptr, ptr %root, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %g0 = getelementptr inbounds i8, ptr %slot, i64 0
  %g8 = getelementptr inbounds i8, ptr %g0, i64 8
  %r = load i64, ptr %g8, align 8
  ret i64 %r
}

; REJECT (P5) D7 — a 2-op STRUCT-STRIDED GEP (`{ptr,ptr}, ptr %slot, i64 1`)
; steps by a whole 16-byte struct. It is NOT "byte-granular"; the reject noun
; must say STRUCT-STRIDED (D7 message-accuracy defect).
define i64 @p06b_struct_stride(ptr %root, ptr %a, ptr %b) {
entry:
  %slot = load ptr, ptr %root, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %g = getelementptr inbounds { ptr, ptr }, ptr %slot, i64 1
  %r = load i64, ptr %g, align 8
  ret i64 %r
}

; ===========================================================================
; REJECT (P5) D3 — SIBLING RE-LOAD. Two `load ptr, ptr %root` of the SAME slot
; give two SSA names; an SSA-scoped scan over `%slot` never sees `%slot2`'s
; byte GEP. This is the canonical GC reload-after-safepoint shape, so it is
; live corpus territory, not a synthetic worry.
; ===========================================================================
define i64 @p06b_realias(ptr %root, ptr %a, ptr %b) {
entry:
  %slot = load ptr, ptr %root, align 8
  %t0 = insertvalue { ptr, ptr } zeroinitializer, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %slot2 = load ptr, ptr %root, align 8
  %byte = getelementptr inbounds i8, ptr %slot2, i64 8
  %r = load i64, ptr %byte, align 8
  ret i64 %r
}

; ===========================================================================
; REJECT (P6) D4 — CHAIN ROOT. (P6) checked only the OUTERMOST insertvalue;
; the chain here is rooted at a `load { ptr, ptr }`, which BennettVM's
; `agg_dests` never registers. `IRInsertValue` has NO membership guard on its
; own `agg`, so this died as a contextless KeyError in the WRONG repo.
; ===========================================================================
define i64 @p06b_chainroot_load(ptr %root, ptr %src, ptr %a) {
entry:
  %slot = load ptr, ptr %root, align 8
  %base = load { ptr, ptr }, ptr %src, align 8
  %agg = insertvalue { ptr, ptr } %base, ptr %a, 0
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ADMIT (P6) D4 — an `undef`/`poison`-rooted chain IS certified: every field is
; overwritten by the chain, and the root contributes no cell value.
define i64 @p06b_chainroot_undef(ptr %root, ptr %a, ptr %b) {
entry:
  %slot = load ptr, ptr %root, align 8
  %t0 = insertvalue { ptr, ptr } undef, ptr %a, 0
  %agg = insertvalue { ptr, ptr } %t0, ptr %b, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  ret i64 0
}

; ###########################################################################
; ## HOSTILE REVIEW ROUND 2 (2026-08-06) — defects found by probing the     ##
; ## round-1 FIXES. All permanent gates.                                    ##
; ###########################################################################

; ===========================================================================
; REJECT (P4c) N1 — the capacity MIRROR drifted from the alloca arm. The arm
; maps `alloca [K x iM], i32 N` to `IRAlloca(_, M, K)` — it DISCARDS N — but
; the mirrored capacity predicate read N and certified K*N. So
; `alloca [1 x i64], i32 4` reserved ONE cell and certified FOUR. Executed
; witness (scratchpad h1_e2e.jl): EXPECTED 999, ACTUAL 42. Capacity is now
; DERIVED from the arm's own `_alloca_reservation`, and an ArrayType count != 1
; is refused outright rather than trusted (the arm's under-reservation for
; N != 1 is Bennett-uiqq, deliberately not fixed here).
; ===========================================================================
define i64 @p06b_arr_count(i64 %x, i64 %y) {
entry:
  %slot = alloca [1 x i64], i32 4, align 8
  %spare = alloca i64, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ADMIT — the ArrayType positive control: `alloca [2 x i64]` (implicit count 1)
; genuinely reserves 2 word cells, so a 2-field store fits.
define i64 @p06b_arr_ok(i64 %x, i64 %y) {
entry:
  %slot = alloca [2 x i64], align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %slot, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P5) N2 — REDUNDANT GEPs defeated the alias key. Two IDENTICAL
; `getelementptr i8, ptr %root, i64 0` gave two SSA refs, so the SSA-ref-keyed
; alias group never linked `%s1` and `%s2` and the byte GEP on `%s2` went
; unseen: ADMITTED, VM returned 0 where LLVM says 42. `optimize=false` — which
; this extractor mandates (Rule 5) — emits redundant GEPs routinely. The key is
; now canonicalised through all-constant-index GEPs to (root, total offset).
; ===========================================================================
define i64 @p06b_redundant_gep(ptr %root, i64 %x, i64 %y) {
entry:
  %g1 = getelementptr inbounds i8, ptr %root, i64 0
  %s1 = load ptr, ptr %g1, align 8
  %g2 = getelementptr inbounds i8, ptr %root, i64 0
  %s2 = load ptr, ptr %g2, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %s1, align 8
  %byte = getelementptr inbounds i8, ptr %s2, i64 8
  %r = load i64, ptr %byte, align 8
  ret i64 %r
}

; REJECT (P5) N2 — the SHARED-GEP spelling of the same hazard (already closed
; by D3; kept so the canonicalisation cannot regress it).
define i64 @p06b_shared_gep(ptr %root, i64 %x, i64 %y) {
entry:
  %g1 = getelementptr inbounds i8, ptr %root, i64 0
  %s1 = load ptr, ptr %g1, align 8
  %s2 = load ptr, ptr %g1, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %s1, align 8
  %byte = getelementptr inbounds i8, ptr %s2, i64 8
  %r = load i64, ptr %byte, align 8
  ret i64 %r
}

; ADMIT (P5) N2 — the POSITIVE CONTROL the canonicalisation must not break: a
; sibling re-load whose only use is a WORD-granular struct GEP still agrees.
define i64 @p06b_sibling_ok(ptr %root, i64 %x, i64 %y) {
entry:
  %s1 = load ptr, ptr %root, align 8
  %s2 = load ptr, ptr %root, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %s1, align 8
  %f = getelementptr inbounds { i64, i64 }, ptr %s2, i32 0, i32 1
  %r = load i64, ptr %f, align 8
  ret i64 %r
}

; ===========================================================================
; ADMIT (P4b) N3, BYTE-STAMPED — Bennett-bvmd (xkl wall 8) INVERTED this
; fixture. `julia.gc_alloc_obj` is the JULIA heap tier, which BennettVM
; reserves BYTE-granular (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)`,
; BVM src/ir/intrinsics.jl:256-257, CW-D4). p06b USED to write WORD-granular
; cells here, so a Julia-idiom field read at byte offset 8 landed on cell
; base+8 and missed the write entirely: EXPECTED 42, ACTUAL 0 (scratchpad
; h17_e2e.jl) — hence the original refusal.
;
; bvmd admits the tier at the granularity the RESERVATION actually uses: the
; decomposition stamps `elem_width = 8`, so field k lands on BYTE cell `o_k`,
; which is the cell the object's own `gep i8` readers name. The h17 repro is
; sound under the new emission only because the D4 two-index struct-GEP arm was
; re-stamped in the SAME change (`_cell_elem_width_struct_gep`, provenance-first
; union) — without that, the defect would have flipped from "store word, read
; byte" to "store byte, read word": still broken, differently.
; ===========================================================================
define i64 @p06b_gc_alloc_target(ptr %tls, ptr %tag, i64 %x, i64 %y) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %tls, i64 24, ptr %tag)
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %obj, align 8
  ret i64 0
}

; ===========================================================================
; REJECT (P4c) in BYTE cells — Bennett-bvmd. The capacity guard survives the
; admission, it just changes UNIT: `_alloc_cells(::IntrinsicGCAlloc)` reserves
; `nbytes` BYTE cells, and a 2-field `{i64,i64}` decomposition writes bytes
; [0,16). An 8-byte box reserves 8 byte-cells, so field 1 at cell +8 would land
; on the NEXT arena allocation — the D1 clobber, one tier down. This is the ONE
; gc_alloc reject that survives bvmd, and it keeps the gc_alloc arm inside the
; (h) message-hygiene sweep.
; ===========================================================================
define i64 @p06b_gc_alloc_small(ptr %tls, ptr %tag, i64 %x, i64 %y) {
entry:
  %obj = call ptr @julia.gc_alloc_obj(ptr %tls, i64 8, ptr %tag)
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %obj, align 8
  ret i64 0
}

; ===========================================================================
; KNOWN-ADMITTED WITNESS — Bennett-khb2. The `:load` target kind has NO static
; capacity proof (the corpus shape). This fixture DOES extract today; the
; residual is disclosed, not closed. IF THIS FIXTURE STARTS REJECTING, someone
; closed khb2 — that is a deliberate flag to update the gate, NOT a regression.
; ===========================================================================
define i64 @p06b_khb2_loadclobber(ptr %slot, i64 %x, i64 %y) {
entry:
  %small = call ptr @malloc(i64 8)
  %other = call ptr @malloc(i64 8)
  store ptr %small, ptr %slot, align 8
  %tgt = load ptr, ptr %slot, align 8
  %t0 = insertvalue { i64, i64 } zeroinitializer, i64 %x, 0
  %agg = insertvalue { i64, i64 } %t0, i64 %y, 1
  store { i64, i64 } %agg, ptr %tgt, align 8
  ret i64 0
}
