# Bennett.jl — LLVM IR Handling Robustness Review

**Reviewer jurisdiction:** LLVM / compiler-frontend robustness
**Scope:** `src/ir_extract.jl` (2394 loc), `src/ir_parser.jl` (168 loc), `src/ir_types.jl` (221 loc), `src/memssa.jl` (164 loc), and the extract-side surfaces of `src/lower.jl`
**Method:** source-reading + 80+ synthetic `.ll` probes through `extract_parsed_ir_from_ll` and `reversible_compile`. Citations are file:line. Every opcode/valuekind check below was probed on an actual LLVM 15+ module.
**Stance:** skeptical, harsh. Silent drops are flagged as silent drops even when a downstream lowering error eventually fires — correctness-critical code must not rely on shake-out at the consumer.

---

## 1. Opcode × Value-kind coverage matrix

### 1.1 Opcodes (LLVM 15+ `LLVMOpcode` enum)

Legend:
**H** = handled correctly; **E** = fail-loud `_ir_error`; **S** = **silently dropped** (extractor returns `nothing`, downstream may fail at `_operand` lookup or lower); **C** = **crash** with non-Bennett error (UndefRefError, raw MethodError, etc.); **PARTIAL** = handled for some shapes only.

| Opcode | Status | Citation | Notes |
|---|---|---|---|
| `ret` | H | 1177 | void-ret with no sret crashes at `_type_width` — see §1.1a |
| `br` (cond + uncond) | H | 1165 | |
| `switch` | H | 1566 | **Bug §9.1** — phi patching |
| `indirectbr` | E | 1733 | via fallthrough |
| `invoke` | E | 1733 | via fallthrough (no landingpad support) |
| `unreachable` | H | 1209 | returns `IRBranch(nothing, :__unreachable__, nothing)` |
| `callbr` | E | 1733 | via fallthrough |
| `add/sub/mul` | H | 1107 | |
| `shl/lshr/ashr` | H | 1107 | |
| `and/or/xor` | H | 1107 | |
| `udiv/sdiv/urem/srem` | H | 1149 | |
| `fadd/fsub/fmul/fdiv` | E | 1733 | **HIGH §3.1** — only reachable as `SoftFloat.*` inlined calls on `UInt64`; raw float IR fails |
| `fneg` | H | 1690 | XOR sign bit |
| `frem` | E | 1733 | no soft-float route |
| `fptoui/fptosi` | PARTIAL | 1594 | only routes through `soft_fptosi` when callee registered *and* `src_w == 64`; falls back to **`IRCast`** for other widths (incorrect — width cast ≠ float-to-int) |
| `uitofp/sitofp` | PARTIAL | 1619 | same: only `dst_w == 64`, else silent width-cast fallback |
| `fptrunc/fpext` | E | 1733 | soft-float comment block at 1455 is a no-op (hits the general call path next, which 99% of the time doesn't register the intrinsic) |
| `trunc/zext/sext` | H | 1157 | |
| `ptrtoint` | E | 1733 | §8 |
| `inttoptr` | E | 1733 | §8 |
| `bitcast` | PARTIAL | 1680 | only same-width supported; any different-width produces `IRCast(:trunc, ...)` — the `:trunc` op-sym is wrong for same-width identity (cosmetic but confusing) |
| `addrspacecast` | E | 1733 | |
| `icmp/fcmp` | H / PARTIAL | 1117, 1642 | fcmp: only predicates `OEQ, OGT, OGE, OLT, OLE, UNE` (6 of 16); `ORD/UNO/UEQ/UGT/UGE/ULT/ULE/ONE` fail-loud; `OEQ` is **unordered-equal**, not ordered — real LLVM semantic requires NaN short-circuit. Routes to `soft_fcmp_oeq`; relying on that callee's semantics being right |
| `phi` | H | 1137 | see §4 on edge cases |
| `call` (LLVM intrinsics) | PARTIAL | 1213 | `umax/umin/smax/smin/abs/ctpop/ctlz/cttz/bitreverse/bswap/fshl/fshr/fabs/copysign/minnum/maxnum/minimum/maximum` handled; `llvm.floor/ceil/trunc/rint/round` fall through to callee registry; rest **§2 silently dropped** |
| `call` (user function) | PARTIAL | 1489 | dispatched via `_lookup_callee`; **if callee not registered, silently drops** |
| `select` | H | 1125 | ptr-typed handled w/ width=0 sentinel |
| `alloca` | PARTIAL | 1718 | integer element only; struct/float/array element **silently dropped** |
| `load` | PARTIAL | 1552 | integer return only; others silently dropped. `volatile` flag silently dropped; `atomic` silently dropped (§3.2 — correctness!) |
| `store` | PARTIAL | 1700 | integer value only; others silently dropped. `volatile`/`atomic` silently dropped |
| `getelementptr` | PARTIAL | 1512 | **§7** many failure modes |
| `fence` | E (ugly) | via `_type_width` | fence returns void; `_type_width(VoidType)` crashes at line 2373 — error message is misleading |
| `atomicrmw` | E | 1733 | |
| `cmpxchg` | E | 1733 | |
| `getelementptr inrange/inbounds` | H | 1512 | flags silently dropped, fine |
| `extractvalue` | PARTIAL | 1183 | **§1.1b** crashes on `{i32,i1}` / literal StructType |
| `insertvalue` | PARTIAL | 1195 | same — crashes on StructType aggregates |
| `extractelement/insertelement/shufflevector` | H | 2070–2128 | vector path (SLP), dynamic lane index errors |
| `freeze` | H | 1587 | `freeze undef` still errors via `_operand` at the scalar level — see §5 |
| `landingpad/resume/catch*/cleanup*` | E | 1733 | |
| `va_arg` | E | 1733 | |
| `LandingPad` etc. | E | 1733 | |

#### 1.1a Void-return non-sret hides behind `_type_width`

File `src/ir_extract.jl:796`: `rt = LLVM.return_type(ft); ret_width = _type_width(rt)` — if `rt` is `LLVM.VoidType` and there is no sret parameter, `_type_width` errors with `"unsupported LLVM type for width query: LLVM.VoidType(void)"` at line 2373. This message mentions "width query" rather than "void-returning function without sret is not supported" — confusing for any user inspecting fence-bearing or memcpy-only IR.

#### 1.1b extractvalue/insertvalue on literal StructType → UndefRefError crash

File `src/ir_extract.jl:1189` and 1202 compute `ew = LLVM.width(LLVM.eltype(agg_type)); ne = LLVM.length(agg_type)`. This presumes `agg_type` is an `LLVM.ArrayType`. For any LLVM intrinsic returning a literal struct (`{iN, i1}` — *all* `.with.overflow` intrinsics, `cmpxchg` result, any user function returning a tuple of mixed widths) `LLVM.eltype` is undefined:

```
UndefRefError: access to undefined reference
  [3] _convert_instruction(inst::LLVM.ExtractValueInst, ...)
       @ Bennett ~/Projects/Bennett.jl/src/ir_extract.jl:1189
```

This is a **crash**, not a Bennett error. Violates CLAUDE.md §1 (fail fast, fail *loud* with context). Probes: `llvm.umul.with.overflow.i32`, `insertvalue {i32,i32} undef, i32 %x, 0`.

### 1.2 Value kinds (LLVM `LLVMValueKind` enum)

| ValueKind | Extractor handling | Citation | Notes |
|---|---|---|---|
| ArgumentValueKind | H | 810 | integer/float/pointer; others silently skipped (§6) |
| BasicBlockValueKind | H | indirect | |
| MemoryUseValueKind, MemoryDefValueKind, MemoryPhiValueKind | n/a | memssa.jl | parse by regex, not iterated |
| FunctionValueKind | H (as callee) | 229 | `_lookup_callee` |
| GlobalAliasValueKind | PARTIAL | 1765 | `_resolve_aliasee` via raw C API; sentinel or silent-skip in cc0.3 catch (893) |
| GlobalIFuncValueKind | PARTIAL | 1862 | recognised in `_ptr_identity`; not walked for other purposes |
| GlobalVariableValueKind | PARTIAL | 1533, 947 | only in GEP base Case B; direct `load ptr @g` silently drops |
| BlockAddressValueKind | S | — | `@g = blockaddress(...)` silently dropped |
| ConstantAggregateZeroValueKind | H | 2341 | in scalar operand position returns sentinel |
| ConstantArrayValueKind | S | 947 | only ConstantDataArray is extracted as globals; ConstantArray silently skipped |
| ConstantDataArrayValueKind | H | 961 | gated on integer elem width ∈ [1, 64] |
| ConstantDataVectorValueKind | H | 2038 | |
| ConstantExprValueKind | PARTIAL | 1915 | only `icmp eq/ne` on resolvable pointer pairs; every other opcode errors with cc0.4 breadcrumb — *but only if it reaches `_fold_constexpr_operand`*. Several paths (the naming pass, bareback `_operand` in call arg loops, etc.) may encounter CE shapes that slip into `_operand` successfully if structure happens to match |
| ConstantFPValueKind | **S** | — | never recognised in `_operand`; would fall through to "unknown operand ref" — **§3.3** |
| ConstantIntValueKind | PARTIAL | 2339 | `convert(Int, val)` — **§5.1 silent truncation** for i128 constants whose high bits don't fit in `Int64` |
| ConstantPointerNullValueKind | PARTIAL | 1865 | recognised in `_ptr_identity`; as bare operand in `_operand` it falls through to "unknown operand ref" error |
| ConstantStructValueKind | **S** | — | not recognised anywhere; function return as `ret {i32,i32} { i32 1, i32 2 }` crashes in `_type_width` |
| ConstantTargetNoneValueKind | **S** | — | |
| ConstantTokenNoneValueKind | **S** | — | token type not supported |
| ConstantVectorValueKind | **S** | 2029 | `_resolve_vec_lanes` errors if not CDA / CAZ / Undef / Poison. A ConstantVector with ConstantExpr lanes is unreachable |
| InlineAsmValueKind | **S (silent drop of call)** | 1508 | §2 probe 7: `%r = call asm "..."` drops the call, leaves `%r` undefined, crashes at lower with "Undefined SSA variable: %r" — violates CLAUDE.md §1 |
| InstructionValueKind | H | — | |
| MetadataAsValueValueKind | S | — | `!dbg` / `!tbaa` ignored (probably correct to ignore, but nothing validates that user metadata won't smuggle semantic info) |
| PoisonValueValueKind | PARTIAL | 2054 | vector lane path handles via `:__poison_lane__` sentinel; scalar operand position errors with "unknown operand ref" — confusing message |
| UndefValueValueKind | PARTIAL | 2054 | same as Poison |

---

## 2. Top 10 ways a valid LLVM module causes Bennett.jl to crash or silently miscompile

### [CRIT-1] `convert(Int, LLVM.ConstantInt)` silently truncates i128 constants to their low 64 bits

File `src/ir_extract.jl:2340`. `_operand(val::LLVM.Value, ...)` for `ConstantInt` does `iconst(convert(Int, val))`.

Verified: `ret i128 170141183460469231731687303715884105728` (exactly 2^127) produces `IRRet(IROperand(:const, Symbol(""), 0), 128)`. The i128 value `0x8000_0000_0000_0000_0000_0000_0000_0000` is silently turned into `0`. The resulting circuit returns 0 for every input.

Broader blast radius: any i128 constant whose low 64 bits happen to be zero is silently zero. Any i128 constant whose low 64 bits happen to match an unrelated pattern is silently that low-64 pattern with the high bits discarded. Other widths: only i128+ are exposed, and the probe suite says i128 with value 2^127−1 (127 ones) gave 127 CNOTs — so the low-64 bits were set correctly, but the top 63 bits were `0xffffffff_ffffffff` and `IROperand.value` stored only the low 64. `lower.jl`'s `resolve!` at line 177 iterates `val >> (i-1) & 1` for `i in 1:width` — so above bit 64 it reads `(0 >> k) & 1 = 0`. Silent miscompile.

**Severity:** critical — a plausible i128 function (SHA-512 constants, crypto) silently returns wrong answers.

**Fix sketch:** `IROperand` should carry `value::BigInt` (or `value::UInt128`, plus width) and `lower.jl`'s `resolve!` should iterate against the widened value. Alternatively, use `LLVM.API.LLVMConstIntGetZExtValue`/`…GetSExtValue` for ≤64-bit and error loudly for >64-bit constants until BigInt support lands.

### [CRIT-2] `extractvalue` / `insertvalue` on literal StructType → raw `UndefRefError`

File `src/ir_extract.jl:1189, 1202`. `LLVM.eltype(agg_type)` is called assuming `ArrayType`. For StructType (every `.with.overflow` intrinsic, every mixed-width tuple, every SROA-exposed struct) this crashes with `UndefRefError` not a Bennett-formatted error.

Reproducer: `%r = call {i32,i1} @llvm.umul.with.overflow.i32(i32 %a, i32 %b); %v = extractvalue {i32,i1} %r, 0`. The call is silently dropped (no known callee), but then the `extractvalue` tries to decode `{i32,i1}` as array and crashes.

**Severity:** critical — CLAUDE.md §1 "crashes not corrupted state" still requires the crash to be **loud with context**, not a bare `UndefRefError` from inside LLVM.jl.

### [CRIT-3] Switch phi patching only patches already-written result blocks

File `src/ir_extract.jl:1053–1078`. `_expand_switches` patches phi nodes in `result[j]` for `j in eachindex(result)`, but at the time the switch block is processed, only blocks that have already been appended to `result` are visible. Phi-bearing successor blocks are processed **later** in the outer `for block in blocks` loop, and at that point the `phi_remap` dict is out of scope (it's local to the switch-block iteration).

Reproducer (probe 75): two cases targeting the same block `:a` with a phi `[(10, :entry), (10, :entry)]` — after expansion the phi still reads both edges from `:entry`, but at runtime case 2's branch comes from `_sw_entry_2`. Second issue: for two cases targeting the same block, `phi_remap[:a]` is overwritten, losing information.

Verified: the phi after extraction still shows `Tuple{...}[(10, :entry), (10, :entry)]` — neither incoming was remapped, so the phi-resolution algorithm in `lower.jl` may synthesize a MUX with wrong branch conditions.

**Severity:** critical — silent miscompile on Julia-generated `@enum`-style dispatch with cascading switches. Falls into CLAUDE.md §7 territory ("bugs are deep and interlocked" — phi + switch).

**Fix sketch:** do the phi-patching *after* all blocks are in `result`. Maintain `phi_remap` as a module-level dict (switch_block → target → source) and apply in a single sweep at the end.

### [CRIT-4] GEP with typed element stride records index-not-bytes in `IRPtrOffset.offset_bytes`

File `src/ir_extract.jl:1519`. `offset = convert(Int, ops[2])` — the raw *index* value. Stored directly in `IRPtrOffset.offset_bytes`. `lower_ptr_offset!` at `src/lower.jl:1528` computes `bit_offset = inst.offset_bytes * 8`, treating `offset_bytes` as bytes.

For `getelementptr i32, ptr %p, i64 1` (LLVM textual, typed element), the semantic stride is 4 bytes (1 × sizeof(i32)). The extractor records 1 byte. Verified (probe 46b): `IRPtrOffset(:q, ..., 1)` for `GEP i32 index 1`.

This is only safe when the source-element type is `i8` (byte-addressed, which is Julia's default since LLVM ≥ 15 opaque pointers). Any `.ll` from C/Rust that uses typed GEP silently miscompiles.

**Severity:** critical — discovered while probing TC corpus compatibility. The TC1/TC2/TC3 test results mentioned in the prompt (extract succeeds, lower fails) probably hide more instances.

**Fix sketch:** read `LLVMGetGEPSourceElementType`, compute `stride_bytes = _type_width(elt_ty) ÷ 8`, store `offset_bytes = index * stride_bytes`.

### [CRIT-5] IRVarGEP elem_width defaults to 8 bits for non-integer source types

File `src/ir_extract.jl:1526, 1537`. `ew = src_type isa LLVM.IntegerType ? LLVM.width(src_type) : 8`.

For `getelementptr double, ptr %p, i64 %i` the stride is 64 bits (8 bytes). The extractor records `elem_width = 8` (meaning 1 byte per element, since `IRVarGEP.elem_width` is in bits per the type docstring and used as such in `lower_var_gep!` at `src/lower.jl:1607`). Load at index 1 would read the 2nd *bit*, not the 2nd *double*.

Verified (probe 47): `IRVarGEP(:q, ..., :i, 8)` for double-stride GEP. Silent miscompile.

**Severity:** critical — compound arithmetic on float arrays corrupted.

**Fix sketch:** error-loud when source element is non-integer; don't guess 8.

### [CRIT-6] Atomic load/store/RMW drop atomicity silently; `volatile` dropped silently

File `src/ir_extract.jl:1552, 1700`. `IRLoad` and `IRStore` hold only `width` — no ordering/atomic flags.

- `atomic load i32` produces `IRLoad(:v, ..., 32)` — same as a plain load. Probe 1 confirmed.
- `store volatile i32 %v, ptr %p` produces `IRStore(..., ..., 32)` — no volatile flag. Probe 6 confirmed.
- `atomicrmw`/`cmpxchg` fail-loud (good). Fence fails via unrelated `_type_width` error (bad message).

For a reversible-circuit target, dropping atomicity is semantically equivalent (there's no concurrent observer). But **silently dropping** a semantic marker is a CLAUDE.md §1 violation — should be explicit. The concern is that user code assuming atomic-fence-based synchronisation between callee and a Sturm.jl quantum control primitive would produce a circuit that fails to honour the happens-before, and the user would have zero warning.

**Severity:** high — not a correctness bug for the MVP, but a trap for v0.6+ concurrency work.

### [CRIT-7] Inline asm call is silently dropped; result SSA left undefined

File `src/ir_extract.jl:1508` — call with unknown callee returns `nothing`. InlineAsm callee is never recognised. `_lookup_callee(cname)` where `cname = ""` (inline asm has no name) returns nothing. Entire call dropped.

Consumer of the result fails at lower time with `Undefined SSA variable: %r`. This is fail-loud at lower, but not at extract. CLAUDE.md §1 explicitly says **fail fast**, meaning at the earliest opportunity — silent-drop-at-extract + late-crash-at-lower is anti-pattern.

Verified: probe 7 and probe 8 (ext call to a `declare i32 @extfn(i32)`).

**Severity:** high — test_t5_corpus_c.jl almost certainly encounters this on hand-written fixtures.

**Fix sketch:** when `_lookup_callee` returns nothing, `_ir_error(inst, "call to $(cname) has no registered callee handler")`. If the user genuinely wants the call stubbed out, require an explicit `register_callee_stub!` call.

### [CRIT-8] Multi-index GEP (struct member) silently drops the GEP

File `src/ir_extract.jl:1516, 1533` — both Case A and Case B require `length(ops) == 2`. Julia's common pattern `getelementptr %S, ptr %p, i32 0, i32 1` has `length(ops) == 3`. Falls through to `return nothing # GEP with unknown base — skip`.

Verified (probe 33): multi-index GEP produces no IR, and the downstream `load` loses its `ptr %q` resolution, crashing at lower with "Undefined SSA variable: %v" (probe 33b).

**Severity:** high — struct accesses from C/Rust fixtures hit this immediately. Covers TC2/TC3 corpus classes per the prompt's implicit mention.

### [CRIT-9] `_get_deref_bytes` regex fallback is function-wide, not per-parameter

File `src/ir_extract.jl:2326–2334`. The regex `dereferenceable\((\d+)\)` is applied to the whole `split(ir_str, "\n")[1]`, which is the `define ...` line. If *any* parameter has a dereferenceable attribute, **every** pointer-typed parameter receives that byte count.

Verified (probe 60): `define i32 @f(ptr dereferenceable(16) %p, ptr %q)` produces `args=[(:p, 128), (:q, 128)]`. `%q` gets 128 bits (16 bytes) of phantom input wires — this allocates wires that have no meaning, silently doubling the input-wire count of any function that mixes dereferenceable and non-dereferenceable pointers.

Also: `LLVM.parameter_attributes(func, idx)` on line 2315 fails to iterate in LLVM.jl 9.4.6 — raises a MethodError the try/catch swallows. So the fallback regex is the **sole** code path. No test covers it.

**Severity:** high — NTuple-input functions with mixed pointer signatures misallocate wires.

### [CRIT-10] `cc0.3` catch-block swallows unrelated MethodErrors

File `src/ir_extract.jl:896–907`. The catch block says:

```julia
if occursin("Unknown value kind", msg) ||
   occursin("LLVMGlobalAlias", msg) ||
   (e isa MethodError && occursin("PointerType", msg))
    nothing
else
    rethrow()
end
```

`MethodError && occursin("PointerType", msg)` is catastrophically broad. Any unrelated bug whose error message happens to contain the substring `"PointerType"` is silenced — and since `PointerType` is *everywhere* in LLVM.jl stack traces, many unrelated crashes would be masked. The MethodError filter gate helps, but only as long as the underlying bug shape happens to be a MethodError.

**Severity:** medium — hard to prove in production but a ticking time-bomb when LLVM.jl updates and its error messages shift.

**Fix sketch:** the cc0.3 escape hatch should match on the *structure* of the failure (e.g., "LLVM.jl returned nothing from `identify()`") rather than string substrings.

---

## 3. Float vs integer consistency (§3 prompt topic)

### 3.1 Raw `fadd/fsub/fmul/fdiv` / `fneg` divergence from float→soft-float route

The `SoftFloat` struct in `src/Bennett.jl:220` rewrites Julia-level `a + b` on `SoftFloat` to `soft_fadd(a.bits, b.bits)`. The Julia-side callee registry maps the resulting `call @j_soft_fadd_NNN` to `IRCall` with the registered callee. Extractor never sees a raw `fadd` opcode in the Julia-driven path.

**But** `extract_parsed_ir_from_ll(path; entry_function="f")` — the P5a corpus path — does see raw `fadd`. There's no soft-float dispatch outside the `SoftFloat` wrapper. Probe 16 confirms: raw `fadd double %x, %y` errors "unsupported LLVM opcode". This is actually good failure behaviour — but the error message doesn't suggest "compile via SoftFloat wrapper", leaving users confused about why a valid .ll doesn't work.

### 3.2 `fptoui/fptosi/uitofp/sitofp` silent width-cast fallback

File `src/ir_extract.jl:1614, 1638`. When the soft-float callee isn't registered **or** the width isn't 64, the code falls back to:

```julia
return IRCast(dest, dst_w < src_w ? :trunc : (dst_w > src_w ? :zext : :trunc), _operand(src, names), src_w, dst_w)
```

This treats a `double → i32` conversion as a **bit-level trunc**, not a floating-point value conversion. For Julia's Float32→Int8, this is pure nonsense — a 32-bit float `1.0` is `0x3f800000`, truncating to 8 bits gives `0x00`. Silently wrong.

**Severity:** high, if any Float32 path ever exercises this. The `SoftFloat` wrapper forces Float64 via `reinterpret(UInt64, Float64(x))`, so today it's dormant. But the codepath is a land mine.

### 3.3 `ConstantFP` in operand position is not handled

`_operand` at 2338 has no branch for `LLVM.ConstantFP`. Any float literal in operand position (e.g., `fadd double %x, 3.14`) would hit the generic branch and error "unknown operand ref for: double 3.14e+00". Probe: any raw-fp `.ll` exercising a literal hits this. The error message blames "producing instruction skipped" which is misleading.

### 3.4 `frem`, `fpext`, `fptrunc` — no soft-float routing exists

Comment block at `src/ir_extract.jl:1455–1466` gestures at `llvm.floor/ceil/trunc/rint/round` but drops to the fall-through `return nothing` because no intrinsic handler emits an IRCall. The callee registry line below handles `call` instructions targeting registered functions, but these LLVM intrinsics are never registered. So the intrinsics *are* silently dropped.

Verified: probe 14 (`fptrunc`) and probe 15 (`frem`) both fail-loud (which is the correct behaviour). But the comment block is misleading — it reads as if the intrinsics are dispatched when they aren't.

---

## 4. Phi node edge cases (§5 prompt topic)

| Shape | Extractor | Lower |
|---|---|---|
| 0 incoming | Accepted (probe 39) | Crash at `resolve_phi_predicated!` (incoming vector is empty — `incoming[end]` out of bounds) |
| 1 incoming | Accepted | OK: early-return in `resolve_phi_predicated!` |
| 1 incoming + self-ref (loop) | Accepted | OK via loop-header path |
| Many incoming (switch merge) | Accepted | PARTIAL — **§9.1 phi-remap bug** |
| Self-referencing non-loop | Accepted | Would crash in topo_sort or MUX resolution |
| Phi with different widths per incoming | Accepted | **Never detected** — `IRPhi.width` is a single value from the *instruction result type*, so mixed-width incoming (malformed LLVM) is implicitly trusted |
| Phi-of-phi (same block) | Accepted (two-pass naming) | Depends on lower.jl ordering — `lower_phi!` assumes incoming already lowered |
| Pointer-typed phi (width=0) | H | §6 (ptr_provenance) — requires `ptr_provenance` dict, errors if missing |

**Gap:** no `_ir_error` guards reject phi with 0 incoming or with mismatched widths. `_convert_instruction` at 1137 blindly constructs `IRPhi`. Defense-in-depth missing.

---

## 5. Constant handling

### 5.1 ConstantInt silent truncation — see CRIT-1

### 5.2 ConstantFP — see §3.3

### 5.3 ConstantAggregateZero: only handled as scalar operand sentinel (`:__zero_agg__`, 2342). In vector lane path: OK (`[iconst(0) for _ in 1:got_n]`).

### 5.4 ConstantStruct / ConstantArray / ConstantVector — §1.2.

### 5.5 ConstantExpr: MVP scope is `icmp eq/ne` with pointer identity decidable via `_ptr_identity`. Everything else errors loud (good). But the escape path via `_ptr_addresses_equal` returns `nothing` in many realistic Julia scenarios (addresses are allocator-dependent) — failure rate in real Julia IR will depend on what optimize=true produces.

### 5.6 UndefValue / PoisonValue (scalar position): error message "unknown operand ref" is misleading (probe 31, 32). Should be explicit:

```
ir_extract.jl: poison/undef in operand position of %y = add — poison propagation not modelled
```

### 5.7 `convert(Int, LLVM.ConstantInt)` for negative i8/i16: works (Julia widens signed). But for **unsigned** values ≥ 2^31 on a 32-bit Julia build (unlikely but possible), `Int` is 32-bit — another silent truncation.

---

## 6. Global values

| Kind | Handled? | Citation |
|---|---|---|
| GlobalVariable — constant CDA integer | H (globals dict) | 947 |
| GlobalVariable — non-constant | S | filtered at 954 |
| GlobalVariable — direct load `load i32, ptr @g` (no GEP) | **S silent drop** — probe 34 | 1555 (haskey fails) |
| GlobalVariable — load via 3-index GEP (`[N x T], ptr @g, 0, idx`) | **S silent drop** — probe 82 | 1516 + 1533 both require `length(ops)==2` |
| GlobalVariable — i1 / i128 elements | S | 1 ≤ elem_width ≤ 64 gate at 967 |
| GlobalAlias — chain resolved via raw C API | H | 1765 |
| GlobalAlias — cyclic / depth > 16 | Returns nothing → sentinel | 1778 |
| Function-as-value (function pointer) | S (used only as callee) | — |
| GlobalIFunc | PARTIAL | 1862 (recognised in `_ptr_identity`) |
| BlockAddress | S | — |

**The three-index GEP case is the single most impactful gap** — Julia and LLVM both emit `getelementptr [N x T], ptr @g, i32 0, i32 %i` as the standard global-array access. The extractor requires either a 2-index GEP from a local ptr or a 2-index GEP from `@g`. Neither matches the Julia-common pattern. Any `@const_array[i]` access that survives `optimize=true` sroa/gvn (i.e., any large-enough array) hits this and fails at lower.

---

## 7. GEP edge cases

| Case | Handled |
|---|---|
| 2-index GEP on local ptr, const index | PARTIAL (§CRIT-4 — index-not-bytes) |
| 2-index GEP on local ptr, var index | PARTIAL (§CRIT-5 — elem_width fallback) |
| 2-index GEP on global const, const index | H + routes to QROM |
| 2-index GEP on global const, var index | H + routes to QROM |
| 3+ index GEP (struct / nested) | S (drops, undefined dest) |
| Negative constant index (probe 46) | Accepted, but produces negative `offset_bytes` which indexes out of range — silent miscompile / slicing bug |
| Zero-index GEP (identity) | H via `IRPtrOffset(0)` |
| GEP with `inrange` / `inbounds` flags | Flags silently dropped (safe — semantic hint only) |
| Variable-length-array (VLA) GEP | n/a |
| Opaque-pointer IR (no element type) | `LLVMGetGEPSourceElementType` returns the stored source element; works |

---

## 8. ptrtoint / inttoptr (prompt topic §8)

Handled only inside `_ptr_identity` as ConstantExpr peeling (1881 `LLVMIntToPtr` → canonical address). Handled inside `_fold_constexpr_operand` (1919): **explicitly errors loud** with a cc0.4/cc0.6 breadcrumb when present as a ConstantExpr operand.

As a **top-level instruction**, both `ptrtoint` and `inttoptr` fall through to `_ir_error(inst, "unsupported LLVM opcode")` at 1733. Fail-loud. Good.

The gap: they are tracked in `_CONSTEXPR_OPCODE_NAMES` but not in `_LLVM_OPCODE_NAMES` error dict — wait, they *are* at lines 310–311. So error messages get the right opcode name. Good.

---

## 9. Specific correctness bugs beyond the top 10

### 9.1 Switch phi patching — §CRIT-3 already covered. The combined failure modes:

1. Cases targeting the same block overwrite the remap entry.
2. Target blocks processed later than the switch block are not patched.
3. The fix needs a two-pass approach.

### 9.2 `_ptr_identity` chase-depth is 16 — not 17

File `src/ir_extract.jl:1859`. Aliases longer than 16 are silently returned as `nothing`. If Julia-JIT emits a pathological alias chain this is a correctness cliff. The `_resolve_aliasee` at 1765 also uses depth 16. Identical logic; consistent. Comment says "16 is well beyond anything Julia emits" — which is a present-day assumption.

### 9.3 `_expand_switches` synthetic labels collide when run more than once

File `src/ir_extract.jl:1014`. `_sw_$(orig_label)_$i` is deterministic. If `_expand_switches` is called twice on the same IR (pre- and post- some hypothetical pass), the second run inserts a block with the same name as the one generated by the first. Multi-compile pipeline with shared module would fail. Not a current risk but a trap.

### 9.4 `_convert_instruction` — unreachable target `:__unreachable__` is a *global* label

All unreachable terminators point to the same label `:__unreachable__` (line 1210). There is no block with that label. Lower.jl's `preds` dict will have `:__unreachable__ => [every unreachable's block]` which is nonsensical. Verified (probe 65) lower succeeds, implying lower silently ignores the phantom target. That is a miracle of implicit behaviour rather than a defended invariant.

### 9.5 `_type_width` on VectorType — missing case

File `src/ir_extract.jl:2362`. Only IntegerType, ArrayType, FloatingPointType are handled. VectorType falls to "unsupported LLVM type for width query". A vector return value (which is legal LLVM) hits this — probe 44 confirms. But vector returns are rare in Bennett's scope. The issue is only that the error message blames "width query" when the right message is "vector-valued returns aren't supported".

### 9.6 `_operand` falls through for many valid ValueKinds

File `src/ir_extract.jl:2338`. Only `ConstantInt`, `ConstantAggregateZero`, `ConstantExpr`, and named-SSA are handled. Anything else falls into the `haskey(names, r)` branch and raises "unknown operand ref". Kinds that will hit this in real IR:
- ConstantFP
- ConstantPointerNull
- ConstantVector (unless dispatched via `_resolve_vec_lanes` first)
- UndefValue / PoisonValue (scalar)
- Function / GlobalVariable (when used as a value, not just callee)
- BlockAddress

Every one of these produces the same error string ("the producing instruction was skipped"), which is misleading — nothing was "skipped", the ValueKind is simply unhandled. The error message should dispatch on `LLVMGetValueKind`.

### 9.7 `_operand_safe` exists but is only called from `_safe_operands` plumbing

File `src/ir_extract.jl:1803`. Never invoked anywhere else except where someone went to the trouble to walk operands via `_safe_operands`. Most call-sites use `LLVM.operands(inst)` directly (raises on GlobalAlias). Dead code that suggests a safety retrofit was only half-done.

### 9.8 Memoization of `names` is per-function, not per-module

File `src/ir_extract.jl:805`. `names` is local to `_module_to_parsed_ir_on_func`. OK for the current `reversible_compile` entry points. But if a future pass needs to walk multiple functions (e.g. to inline a callee's IR directly instead of via the Julia-level `register_callee!`), the ref → Symbol map won't survive the function boundary.

### 9.9 `_auto_name(counter)` restarts per compilation

File `src/ir_extract.jl:249`. The counter is a `Ref{Int}` passed in. Each function starts at 0. If two ParsedIRs are merged (e.g., for callee inlining at the extract stage), their `__vN` names collide. Not a current concern, but an implicit invariant that the next architecture change may break.

---

## 10. Vector instruction coverage (prompt §10)

Vector path at 2063 handles: insertelement, shufflevector, extractelement, scalar arithmetic (add/sub/mul/and/or/xor/shl/lshr/ashr), icmp, select, cast (sext/zext/trunc), bitcast (vector↔same-shape vector, `<N x i1>` → iN), vector load (2278).

**Missing vector opcodes** — all fail via `_ir_error(inst, "unsupported vector opcode $opc")` at 2298:
- `fadd/fsub/fmul/fdiv` on vectors (LLVM vectorises float code too)
- `icmp/fcmp` on vectors (handled for icmp but not fcmp)
- vector `fptosi/sitofp/fpext/fptrunc`
- vector `load`s with non-integer lanes
- vector `store` (vector store is handled by sret-pending hook at `_collect_sret_writes` — but only for stores into the sret buffer; stores into a regular alloca fall through)
- `llvm.vector.reduce.*` intrinsics (probe 11 confirms fail-loud with "unsupported vector opcode LLVMCall")

**Dynamic lane index error** for insertelement/extractelement: fail-loud (probe-style). Good.

**Vector bitcast `<N x iW>` → scalar `iN` only supported for `<N x i1>` → iN** (line 2238). Any other shape change fails loud. `<2 x i32>` → `i64` (bit-pack two 32-bit lanes into a 64-bit int) would fail — not a correctness bug, just a coverage gap.

---

## 11. `ir_parser.jl` — legacy regex parser

**It is still exported and used — but only by tests.** Specifically:
- `test/test_parse.jl` (via `parse_ir(ir)` — 5 calls)
- `test/test_branch.jl:16`
- `test/test_loop.jl:11`

Outside tests, nothing calls it. It is exported in `src/Bennett.jl:36`. **Per CLAUDE.md §5 it's marked as "backward compat" but the comment is misleading** — actual production compilation goes exclusively through `extract_parsed_ir` / `extract_parsed_ir_from_ll` / `extract_parsed_ir_from_bc`, all of which call `_module_to_parsed_ir`. The parser is dead for production purposes.

**Coverage of the parser is abysmal:**
- Covers: add/sub/mul/and/or/xor/shl/lshr/ashr, icmp, select, phi, ret, br, sext/zext/trunc.
- **Missing**: call, load, store, alloca, getelementptr, insertvalue, extractvalue, unreachable, bitcast, switch, freeze, fneg, all float ops, all intrinsics, all pointer arithmetic, aggregate returns (ret_elem_widths is hardcoded to `[ret_width]` on line 167).
- Non-MVP shapes (negative integer constants, hex literals, named blocks with `.`, etc.) are rejected via the tight regex.
- Strips no metadata — `!dbg`, `!tbaa`, etc. trailing would break the BINOP regex line match.

**Recommendation [MEDIUM]:** either remove `parse_ir` entirely (after migrating `test_parse.jl` / `test_branch.jl` / `test_loop.jl` to `extract_parsed_ir_from_ll`), or mark it loudly as "test-only, not maintained for real IR" in `Bennett.jl` export and the docstring. Shipping it as a user-visible export invites misuse.

---

## 12. Two-pass name table (prompt §20)

Pass 1 names every `LLVM.parameter` + `LLVM.instructions(bb)` in every `bb`. Since LLVM basic-block order is well-defined, and every SSA value in LLVM IR is defined by an instruction or parameter, pass 1 sees every named reference.

**Potential hole:** pass 1 only walks the entry function (`func` — one function). Cross-function references (indirect calls, `@other_func` as value) would not be in `names`. But cross-function SSA references are illegal in LLVM anyway — functions have disjoint SSA namespaces. So the hole is theoretical.

**Back-edge phi:** pass 1 finishes before pass 2 starts, so phi operands referring to SSA values defined later in the same block (self-loop phi) resolve correctly. Verified (probes 20, 28, 79).

**Verdict:** two-pass naming is bulletproof against forward refs within a single function's IR.

---

## 13. SROA auto-prepend (prompt §21)

File `src/ir_extract.jl:75, 430`. `_module_has_sret` scans every function in the module for the `sret` attribute on any parameter.

**Correctness:**
- Detects sret on the entry function ✓
- Detects sret on *other* functions in the module even when the entry function has none — potentially wasted work, but benign.
- Detects sret only when parameter has the `sret` enum attribute — misses *typed* `sret(<ty>)` only if LLVM.jl's enum-kind lookup fails. `LLVMGetEnumAttributeKindForName("sret", 4)` returns the canonical kind; this is the stable API.
- **Miss-case:** a parameter that is *dereferenceable* and carries an sret-like pointer but doesn't have the `sret` attribute is not detected. Rare — only comes up with hand-written fixtures.

**Nested sret?** "What if sret is nested in a pointer-type parameter" — LLVM doesn't permit this syntactically; `sret` is a first-class parameter attribute, not a type qualifier. Non-issue.

**Verdict:** the sret auto-prepend is correct for Julia-emitted IR. Less tested on hand-written fixtures, but the attribute model is stable.

---

## 14. MemorySSA integration (prompt §22)

File `src/memssa.jl`. Runs the LLVM printer pass `print<memoryssa>` via `Pipe()` + `redirect_stderr`, then **parses its stderr output with regex**. This is a direct CLAUDE.md §5 violation ("LLVM IR output is not a stable API") — the annotation format is regex-fragile across LLVM versions.

Regex fragility:
- `_RE_MEM_DEF` at line 44: `; <id> = MemoryDef(<id|liveOnEntry>)` — correct for LLVM 15+.
- `_RE_PHI_ENTRY` at line 47: `{<bb>, <id|liveOnEntry>}` — matches iff there are no nested braces and no spaces around `,` that LLVM's formatter doesn't emit.
- Line-number association is by 1-based line number in the printed text. If LLVM adds a blank line or reformats (which it does between versions), line numbers shift.

**When is memssa used?** Only when `use_memory_ssa=true` is passed explicitly (defaults false). Grep shows `test_memssa.jl`, `test_memssa_integration.jl` are the only consumers, and `_run_memssa_on_ir` is called from there + from `extract_parsed_ir`. Not on the default compile path.

**The `parse_memssa_annotations` function assumes in-order iteration matches the LLVM printer's visit order** — i.e., that LLVM.jl's `LLVM.instructions(bb)` visits instructions in the same order as the `print<memoryssa>` pass's stdout. This is stable for reasonable LLVM versions but is an assumption worth pinning.

**Correctness of the alias model:** the code doesn't model aliasing itself, it consumes LLVM's MemorySSA analysis. LLVM's MemorySSA *is* a correct conservative alias model. Bennett trusts it.

**Verdict:** functional but brittle. When LLVM bumps minor versions and the printer format shifts, this silently breaks. Add a regression test that runs a known-good `.ll` through memssa and checks a specific def-id assignment.

---

## 15. `optimize=true` vs `optimize=false` robustness (prompt §18)

The walker is **tuned to `optimize=true`**. Concretely:
- The `cc0.4` ConstantExpr path assumes `optimize=true` constant-folded `isnothing(x)` checks into ConstantExpr<icmp eq>.
- The sret auto-prepend of sroa+mem2reg is specifically to handle `optimize=false`-emitted memcpy-form sret, but that's one narrow case.
- Regex for dereferenceable attribute parses the first function-def line — `optimize=false` may produce a long line the regex has no trouble with, but `optimize=true` removes some attributes. Not a stability issue.

**Pipeline-ordering assumption:** when `preprocess=true`, the pass sequence is `sroa, mem2reg, simplifycfg, instcombine`. Other orders produce different IR shapes that the walker doesn't handle (verified by sret handling crashing on unSROA'd memcpy at 494). Line 75 auto-prepends SROA only when `_module_has_sret` fires — so `preprocess=false` + sret-function silently works. Good.

**Vectorisation:** SLP runs in `optimize=true`. The `cc0.7` scalariser at line 2063 handles the common SLP shapes. But if a future LLVM version emits `<N x iW>` where N > 64 or W not in {1,8,16,32,64}, `_vector_shape` at 2008 errors loud. Acceptable guardrail.

---

## 16. Julia-emitted IR vs hand-written fixtures (prompt §24)

Strongly Julia-tuned assumptions:
1. `_find_entry_function` fallback (732): picks the first `julia_*`-prefixed function with a body. Doesn't work on C/Rust fixtures — but those use the explicit `entry_function` keyword.
2. Pointer args need `dereferenceable(N)` to be added to `args`. C/Rust fixtures that don't annotate their pointers (common for in-out params) get them silently dropped (probe 64 — opaque ptr without deref).
3. The callee registry is populated with `soft_*` functions (`src/Bennett.jl:163–208`). C/Rust calls resolve nothing, silently drop. Probe 38 confirms.
4. Multi-index GEP (common for struct field access in C/Rust, rare in optimize=true Julia IR) silently drops. Probe 33.
5. Global-array access via 3-index GEP (both Julia and C emit this) silently drops. Probe 82.
6. Literal StructType returns (common in C) crash with `UndefRefError` on `extractvalue`. Probe 37, 51.

The TC1/TC2/TC3 prompt remark "extract succeeds, lower fails" is borne out: extract is lenient (silent-drop for call/gep/load/store whose base ref is unknown), lower is fail-loud (undefined SSA variable). This **violates CLAUDE.md §1** (fail fast).

---

## 17. Prioritised findings

### CRITICAL — silent miscompile, CLAUDE.md §1 violation, user-visible bug today

- **CRIT-1** i128 ConstantInt silent truncation (§2 item 1, `src/ir_extract.jl:2340`)
- **CRIT-2** extractvalue/insertvalue on StructType → raw UndefRefError (§1.1b, `src/ir_extract.jl:1189, 1202`)
- **CRIT-3** Switch phi patching is incomplete and order-dependent (§9.1, `src/ir_extract.jl:1053–1078`)
- **CRIT-4** GEP `offset_bytes` conflates index with bytes for typed GEP (§7, `src/ir_extract.jl:1519`)
- **CRIT-5** IRVarGEP `elem_width` defaults to 8 for non-integer source type (§7, `src/ir_extract.jl:1526, 1537`)

### HIGH — silent drop that eventually fails at lower; correctness trap for hand-written IR

- **HIGH-6** Atomic / volatile semantic markers silently dropped (§3.2, `src/ir_extract.jl:1552, 1700`)
- **HIGH-7** Inline asm call silently dropped — dest SSA undefined at lower (§2 item 7, `src/ir_extract.jl:1508`)
- **HIGH-8** Multi-index GEP (struct access) silently dropped (§6/7, `src/ir_extract.jl:1516, 1533`)
- **HIGH-9** `_get_deref_bytes` regex is function-wide — pollutes non-deref pointer args with false bit-widths (§6, `src/ir_extract.jl:2326`)
- **HIGH-10** `cc0.3` catch block is too broad (MethodError × "PointerType" substring — §2 item 10, `src/ir_extract.jl:896–907`)
- **HIGH-11** Global-variable 3-index GEP silently dropped (§6, `src/ir_extract.jl:1516, 1533`)
- **HIGH-12** Call to unregistered function silently dropped — dest SSA undefined at lower (§2 item 7, `src/ir_extract.jl:1508`)
- **HIGH-13** Direct `load ptr @g` silently dropped (§6, `src/ir_extract.jl:1555`)
- **HIGH-14** `fptoui/fptosi/uitofp/sitofp` fallback treats float cast as bit-trunc (§3.2, `src/ir_extract.jl:1614, 1638`)
- **HIGH-15** ConstantFP / ConstantPointerNull in scalar operand position → misleading "unknown operand ref" error (§9.6, `src/ir_extract.jl:2338`)

### MEDIUM — fail-loud but confusing error messages; architectural risk

- **MED-16** Void-return non-sret crashes at `_type_width` with generic message (§1.1a, `src/ir_extract.jl:2373`)
- **MED-17** Vector-valued return types crash with "width query" error (§9.5, `src/ir_extract.jl:2372`)
- **MED-18** `_operand_safe` is dead/half-adopted — `_safe_operands` is only used in one place (§9.7)
- **MED-19** `_expand_switches` synthetic labels would collide if the function ran twice on the same IR (§9.3)
- **MED-20** `:__unreachable__` is a global phantom label (§9.4)
- **MED-21** Phi with 0 incoming or mismatched-width incoming accepted without validation (§4)
- **MED-22** MemorySSA annotation parser is regex-over-LLVM-printer output — CLAUDE.md §5 violation in spirit (§14)
- **MED-23** `ir_parser.jl` is dead code paraded as "backward compat" — should be removed or clearly labelled test-only (§11)
- **MED-24** UndefValue/PoisonValue in scalar operand position produces "unknown operand ref" — should explicitly reject with a distinct error naming the ValueKind (§5.6, `src/ir_extract.jl:2338`)
- **MED-25** `LLVM.parameter_attributes(f, idx)` throws MethodError in LLVM.jl 9.4.6; `_get_deref_bytes` silently falls back to the broken function-wide regex (§9 + CRIT-9)
- **MED-26** Negative constant GEP index accepted, lower produces out-of-bounds slicing (§7 probe 46)

### LOW / NIT

- **LOW-27** `bitcast` same-width records op-sym `:trunc` — misleading (§1.1)
- **LOW-28** The comment at 1455–1466 about `llvm.floor/ceil/trunc` is a no-op in the current code path — delete or implement (§3.4)
- **LOW-29** `_auto_name` counter restarts per compilation — will collide if two ParsedIRs get merged (§9.9)
- **LOW-30** `_ptr_identity` chase-depth 16 is a magic number — make `const PTR_CHASE_DEPTH = 16` (§9.2)
- **LOW-31** `_resolve_aliasee` duplicates the chase-logic of `_ptr_identity`'s GlobalAlias case — deduplicate (§1)
- **LOW-32** Many `try … catch … nothing` blocks in `_safe_is_vector_type`, `_any_vector_operand`, `_safe_operands`, `_get_deref_bytes`, `_extract_const_globals`. Each broadens the set of swallowed errors. Replace with `LLVM.API.LLVMGetValueKind(ref)` guards that cheaply decide whether to proceed
- **LOW-33** `ret` handler at 1178 calls `_iwidth(ops[1])` which errors on non-integer ops — should match what return-type derivation above the block already did

---

## 18. What the test corpus does NOT cover

Based on grepping the test suite against failure modes above:
- **No test for i128+ ConstantInt values** — the `_narrow_ir` tests only go to 64 bits. CRIT-1 has zero test coverage.
- **No test for switch with duplicate case targets or switch with later-than-entry target blocks containing phis** — CRIT-3 untested.
- **No test for typed-element GEP** — all existing tests use Julia-emitted i8-stride GEP. CRIT-4/5 untested.
- **No test for literal StructType extractvalue/insertvalue** — all tests use array types. CRIT-2 untested.
- **No test for atomic/volatile load/store** — HIGH-6 untested.
- **No test for function with multiple pointer args, mixed dereferenceable** — HIGH-9 untested.
- **No test for `llvm.umul.with.overflow` or similar struct-returning intrinsics** — CRIT-2 repro untested.
- **No test for direct global `load ptr @g`** — HIGH-13 untested.
- **The P5a/P5b corpus tests** exist but appear to exercise only narrow shapes; all CRIT-1 through CRIT-5 slip through.

---

## 19. Overall assessment

The extractor is a competent LLVM 15+ walker that handles 80% of Julia-emitted IR robustly. It fails decisively on clearly-unsupported constructs (catch/resume/invoke/atomicrmw/indirectbr) and silently degrades on *edge cases* that are unfortunately common in hand-written fixtures and in Julia IR when the optimiser does something unusual.

**The three worst properties:**

1. **Silent drops on unrecognised pointer bases** (line 1516/1533/1548/1555/1706) are industrial-strength anti-patterns. The consistent pattern — return `nothing` when unsure — conflicts with CLAUDE.md §1 fail-fast. Each drop creates an undefined SSA reference that only fails at lower time, obscuring the actual root cause (unsupported GEP shape) behind a generic "Undefined SSA variable" error.

2. **`convert(Int, ...)` on ConstantInt values >64 bits silently truncates** (line 2340). This is a correctness bug with no visible symptom until the circuit is simulated against a reference. For any i128 crypto primitive, SHA-256 constants when compiled at wider widths, or `BigInt`-lowered arithmetic, this silently corrupts.

3. **StructType aggregates crash with `UndefRefError`** on extractvalue/insertvalue (lines 1189/1202). Any LLVM intrinsic returning `{iN, i1}` (all `.with.overflow`, `cmpxchg`, many standard library atomics) crashes the extractor with a bare LLVM.jl error. Not a Bennett error. Not with context. Not actionable.

**Suggested immediate actions:**

1. Replace `return nothing` at 1508, 1548, 1561, 1710 with `_ir_error(inst, "<specific unsupported shape>")`.
2. Widen `IROperand.value` to `Int128` or `BigInt`; adjust `resolve!` in lower.jl to iterate appropriately.
3. Add an `agg_type isa LLVM.ArrayType` guard in `_convert_instruction` at 1188/1202 with `_ir_error(inst, "extractvalue/insertvalue on StructType aggregates not supported — Julia tuple returns flow through the ArrayType path")`.
4. Fix the switch phi-patching to run after all blocks are collected.
5. Fix GEP to actually multiply by element stride.
6. Rewrite `_get_deref_bytes` to match `dereferenceable\((\d+)\)\s+%<paramname>` anchored to the right parameter.
7. Add regression tests for each of the 80 probes above — CLAUDE.md §6 baselines the project's correctness.
8. Remove `ir_parser.jl` or gate it behind a test-only module.

**Estimated effort:** 2–3 weeks of focused work. The bugs are individually small but interlocked — the agent should test every fix against the full probe corpus above to catch regressions.

The phrase "every line of code gets looked at critically" is the correct standard here. The extractor's 2394 lines contain at least eight silent miscompiles, five crash-on-valid-input bugs, and an architectural pattern (catch-and-return-nothing) that concentrates correctness risk at the consumer. Given Bennett.jl's ambition (quantum control in Sturm.jl), these must be fixed before the compiler is trusted with anything beyond the existing curated test corpus.
