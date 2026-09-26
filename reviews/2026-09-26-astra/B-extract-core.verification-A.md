# Verification A — B-extract-core F1–F12 — 2026-09-26

Independent re-execution of findings F1–F12 of `B-extract-core.md`. Julia 1.12.3 / LLVM 18,
`julia --project --check-bounds=yes --compiled-modules=existing`, x86_64 Linux. All probes are
scratchpad scripts run against the checked-out tree; no src/test edits. F10 ran in two separate
`ulimit -c 0` processes. "In-memory helper" = `Bennett._parsed_ir_from_ir_string(ir; kw...)`
(src/extract/entry.jl:95), the same tail the public `extract_parsed_ir_from_ll` / by-value
`extract_parsed_ir` paths use; the report's calls match real signatures (no MethodError occurred).
Circuit checks use `reversible_compile(::ParsedIR)`, `simulate`, `verify_reversibility(c; n_tests=4|16)`.

## Summary

| F# | Verdict | Severity ok? | Reachability | Dedup | Note |
|---|---|---|---|---|---|
| F1 bare-name callee substitution | CONFIRMED | S0 yes | Julia (public API: two modules + `register_callee!`) | NEW (≠ wh1p case-folding, ≠ 6rqq test-registry leak) | 256/256 Int8 wrong both registration orders; verify=true |
| F2 zero memset deleted | CONFIRMED | S0 yes | from_ll; C -O0 plausible (not run: no clang); not observed from Julia | OVERLAPS Bennett-zmry (P3 feature bead; active miscompile not recorded) | ParsedIR = alloca/store/load only; 42→42, want 0 |
| F3 sret funnel deleted | CONFIRMED (+ wider) | S0 yes | from_ll; C -O0 plausible (effects after join before `return s`) | NEW (contradicts closed jghk) | Also drops a plain global store in the funnel; single-block store+call variant correctly rejects |
| F4 fshl/fshr at shift 0 | CONFIRMED | S0 yes | from_ll only observed; Julia idiom keeps the `s==0` select guard (correct); corpus fshl is rotate-only | NEW | 8160 mismatches on an 18×16×256 grid; fshr s=0 → 0x36 want 0x34 |
| F5 packed `<8 x i1>` load | CONFIRMED | S0 yes | from_ll only (Julia Bool memory is i8; no `<N x i1>` load in build/ corpus) | NEW | 8 IRPtrOffset all offset 0; in 2 → 0, want 1 |
| F6 f32 fptosi as IRCast | CONFIRMED, **Julia-reachable** | S0 yes (bead P3 too low) | **Julia**: `reversible_compile(b->unsafe_trunc(Int32,reinterpret(Float32,b)),UInt32)` | DUPLICATE-OF Bennett-3wk7 — its "raw .ll only" claim is refuted | Julia witness returns 0x3fc00000 (1069547520), native 1 |
| F7 uitofp i64 → soft_sitofp | CONFIRMED, **Julia-reachable** | S0 yes | **Julia**: `reinterpret(UInt64, Float64(x::UInt64))` | NEW (only a title word "uitofp-edge" in Bennett-tfx; closed 1la claims fixed) | typemax → bff0…, want 43f0…; 2^63 → c3e0…, want 43e0… |
| F8 ParsedIR name conflation | CONFIRMED (both witnesses) | S0 yes | (a) from_ll only (needs source-named `%__vN`); (b) from_ll / C-plausible (global `@p` + param `%p`); not Julia (arg/global naming differs) | NEW | (a) 3→8 want 7; (b) (42,0)→99 want 42; verify=true both |
| F9 vector sret store pending | CONFIRMED, **Julia-reachable** | S1 defensible (loud AssertionError, not silent) — could be S2 | **Julia**: `g(x::Int64)=(x,x,x,x)` (sret + `store <N x i64>`) | NEW (contradicts closed 0c8o) | Fail-loud, so no wrong result; blocks a trivial tuple return |
| F10 nested ConstantArray segfault | CONFIRMED (+ wider) | S1 yes | from_ll; C/Rust-plausible (struct with `ptrtoint` constexpr array elements also crashes) | NEW | Exit 139 at `LLVMGetElementAsConstant` ← module_walk.jl:880; dense control OK |
| F11 stale circuit after redefinition | CONFIRMED | S0 yes | Julia (public API) | DUPLICATE-OF Bennett-4ddk (= circuit-core F1) | native 5, circuit 4, verify=true |
| F12 heap memset/atomicrmw dropped | CONFIRMED, **Julia-reachable** | S0 yes (strongest in set) | **Julia**: `fill!` on a `Memory{Int8}` under `mem=:heap` | NEW (sibling of B-extract-vm dropped-write finding, different recogniser) | Julia witness 256/256 wrong; fixture mutations 42→42 want 7 |

Net: 12/12 reproduced. 4 findings are reachable from ordinary Julia code (F6, F7, F9, F12) beyond
the two already public-API (F1, F11); F6's bead understates reachability.

## Per-finding details

### F1 — CONFIRMED, S0
Note: my first attempt extracted `f` *before* registering and hit the (correct) Bennett-5oyt
"no registered callee handler" error — that is expected behaviour, not a refutation. Re-run as
written: after `register_callee!(ReviewB.same)`, `extract_parsed_ir(fA, Tuple{Int8})` contains
`IRCall(:__v1, Main.ReviewB.same, [SSAOperand(Symbol("x::Int8"))], [8], 8)`; the LLVM call is to
`j_same_555`. `reversible_compile(fA, Int8)`: native(7)=8, circuit(7)=9, **256/256 inputs wrong**,
`verify_reversibility(c; n_tests=16)=true`. Reverse order (register ReviewA afterwards, compile
`fB` calling ReviewB): native(7)=9, circuit(7)=8, 256/256 wrong — last registration wins silently.
Dedup: Bennett-wh1p is case-folding; Bennett-6rqq is suite-order registry leakage (related
mechanism — a global bare-name registry — but not this cross-module substitution). NEW.

### F2 — CONFIRMED, S0
Report IR verbatim. ParsedIR instructions: `[IRAlloca, IRStore, IRLoad]` — memset gone.
`simulate(c, UInt8(42)) = 42` (want 0); verify=true. Reachability: Julia at optimize=true DSEs
this shape; no zero-memset-after-store in build/ (3 .ll files). A C `memset(&v,0,n)` after a write
at -O0 would produce exactly this, so C-track plausible (clang absent here — not executed).
Dedup: Bennett-zmry (open P3) is the destructive-store feature and names the same test; it does
not record that the current code *accepts and miscompiles*. OVERLAPS; zmry should be re-scoped or
a fail-loud guard added now.

### F3 — CONFIRMED, S0 (broader than reported)
Report IR verbatim: ParsedIR has 1 block with only `IRInsertValue`; in 3 → out 3 (want 99);
verify=true. Extra probe: replacing the funnel's `call @mutate` with `store i8 5, ptr @gg` (global)
also extracts to just `[IRInsertValue]` — the global store is silently dropped (any effect in a
store-free `ret void` block is lost, not only sret-escaping calls). Control: the same
store-then-call in a *single* block rejects loudly (unregistered callee `mutate`), so the defect is
specific to the funnel-elimination path. Reachability: from_ll; C -O0 with code after a join and
before `return s` (NRVO) is a plausible producer; not observed from Julia. NEW (closed Bennett-jghk
introduced the funnel scheme).

### F4 — CONFIRMED, S0
Report IR: fshl on (0x12, 0x34, s): s=0/8/16 → 0x36 (want 0x12); s=1/9 → 0x24 (correct).
Grid a∈0:15:255, b∈0:17:255, s∈0:255: **8160 mismatches** out of 73728 (consistent with only s≡0 mod 8 failing; per-s breakdown not tabulated).
fshr variant, s=0 → 0x36 (want 0x34). verify=true. Reachability: Julia
`(s&=7; s==0 ? a : (a<<s)|(b>>(8-s)))` *does* produce `llvm.fshl.i8` at optimize=true, but LLVM
keeps `select (icmp eq s,0), a, fshl` so the compiled circuit is correct (0 mismatches);
`bitrotate` (same operands) is also correct (0/4096); the only fshl in build/ is a rotate
(`t5_tr2_hashmap.ll:522`). So the S0 is currently reachable only via hand-written/external IR
where a distinct-operand fshl sees a zero count; it is one InstCombine fold away from Julia. NEW.

### F5 — CONFIRMED, S0
Report IR: 8 `IRPtrOffset` nodes with offsets `[0,0,0,0,0,0,0,0]`; in 2 → 0 (want 1);
verify=true. Reachability: from_ll only — Julia stores Bool as i8, and there is no `<N x i1>` memory
load in build/. Low reachability but an unambiguous silent wrong answer. NEW.

### F6 — CONFIRMED, S0; Julia-reachable
Report IR: ParsedIR `[IRCast(:f,:trunc,:bits,32,32), IRCast(:r,:trunc,:f,32,32)]`; in 0x3fc00000
→ 0x3fc00000 (want 1); verify=true. **New witness via ordinary Julia:**
`g6(b::UInt32) = unsafe_trunc(Int32, reinterpret(Float32, b))`; `reversible_compile(g6, UInt32)`
compiles, native `g6(0x3fc00000)=1`, circuit **1069547520**, verify=true. Bennett-3wk7 (open, P3)
describes the defect accurately but asserts "Reachable only on raw .ll/.bc path (Julia path rejects
Float32 upstream), so latent/low severity" — refuted: only Float32 *arguments* are rejected, f32
intermediates in integer-signature functions are not. DUPLICATE-OF Bennett-3wk7; recommend raising
to S0/P1 and correcting its reachability text.

### F7 — CONFIRMED, S0; Julia-reachable
Report IR emits `IRCall(:f, SoftFloatLib.soft_sitofp, [x], [64], 64)`. Results: typemax(UInt64)
→ `bff0000000000000` (want `43f0000000000000`); 2^63 → `c3e0000000000000` (want
`43e0000000000000`); 5 → correct; verify=true. **Julia witness:** `g7(x::UInt64) =
reinterpret(UInt64, Float64(x))` — IR contains `uitofp`; `reversible_compile(g7, UInt64)` gives
`bff0000000000000` for typemax vs native `43f0000000000000`. Every UInt64 ≥ 2^63 is converted as
negative. Dedup: Bennett-tfx only carries "uitofp-edge" in its title (no description); closed
Bennett-1la claims uitofp is done. NEW.

### F8 — CONFIRMED (both witnesses), S0
(a) `%__v1` parameter + unnamed `%0`: ParsedIR `IRBinOp(:__v1, :add, :__v1, 1)` then
`IRBinOp(:r, :add, :__v1, :__v1)` — the unnamed result overwrote the parameter's name; 3 → 8
(want 7); verify=true. (b) `@p` global + `%p` parameter: ParsedIR `[IRVarGEP, IRLoad]`, (42,0) →
99 (want 42); verify=true. Reachability: (a) needs a frontend that emits `%__vN` source names —
Julia names args `%"x::T"`, no corpus hit; from_ll-only in practice. (b) requires a global and a
local sharing a name — impossible from Julia's naming (`+Core…#N`, `jl_global#N`), plausible from
clang/rustc output. Severity S0 correct (silent wrong answer, verify passes); reachability low for
(a), moderate for (b). NEW.

### F9 — CONFIRMED, severity S1 defensible; Julia-reachable
Report IR → `AssertionError: ir_extract.jl: 1 pending sret vector store(s) remain unresolved at ret
void …`. **Julia witness:** `g9(x::Int64) = (x, x, x, x)` — optimized IR has `sret` and a
`store <N x i64>`; `extract_parsed_ir(g9, Tuple{Int64})` throws the same assertion. This is
fail-loud (no wrong result), so under the S1 definition it counts only as "crash on valid input";
since it is an internal `@assert` rather than a contextual rejection and hits a trivial Julia
tuple return, S1 is reasonable; S2 would also be defensible. NEW (closed Bennett-0c8o claims
vector-lane sret support).

### F10 — CONFIRMED, S1
Separate process, `ulimit -c 0`: report input → `signal 11`, **EXIT=139**, top frames
`ConstantDataSequential::getElementAsInteger` ← `getElementAsConstant` ← `LLVMGetElementAsConstant`
← `_flatten_struct_to_bytes` (module_walk.jl:880) ← `_extract_const_globals` (module_walk.jl:1066).
The branch at module_walk.jl:877–880 admits `LLVM.ConstantArray` and calls the
ConstantDataSequential-only accessor. Second process: dense `{ [2 x i8] } { [2 x i8] [i8 1,i8 2] }`
control extracts fine; `{ [2 x i64] } { [2 x i64] [i64 ptrtoint (ptr @h to i64), i64 0] }` (no undef)
**also segfaults** — so any non-data ConstantArray field (undef, poison, or constexpr element)
crashes, and the global need not be referenced. Reachability: from_ll; C/Rust tables of pointer-
derived integers inside structs are plausible producers; not Julia. S1 correct (process crash on
valid input; not a silent wrong answer). NEW.

### F11 — CONFIRMED, S0
`cache_review(x::Int8)=x+Int8(1)` → sim(3)=4; redefine to `+Int8(2)`; `reversible_compile`
again → native 5, circuit 4, verify=true. DUPLICATE-OF Bennett-4ddk (open P1; its description is
exactly this witness).

### F12 — CONFIRMED, S0; Julia-reachable
Fixture `test/fixtures/heap_m2_cond_pair.ll`, inserting before `%3 = load i8` either
`call void @llvm.memset.p0.i64(ptr %memory_data,i8 7,i64 1,i1 false)` or
`%old = atomicrmw xchg ptr %memory_data, i8 7 monotonic`, compiled with
`_parsed_ir_from_ir_string(m; mem=:heap)`: both give sim(42)=42 (want 7), verify=true; unmodified
fixture control also 42 (correct for it). **Julia witness (ordinary code):**
`g12(x::Int8) = (m = Memory{Int8}(undef,2); m[1]=x; m[2]=-x; fill!(m,(x&Int8(3))+Int8(7));
m[((x>>7)&1)+1])` — optimized IR contains
`call void @llvm.memset.p0.i64(ptr … %memory_data, i8 %2, i64 2, i1 false)`;
`reversible_compile(g12, Int8; mem=:heap)` → **256/256 wrong** (x=0: 0 vs 7; x=42: 42 vs 9;
x=-5: 5 vs 10), verify=true. The data-region memset is classified as GC skeleton and erased. This is
the most user-reachable S0 in F1–F12. NEW (no bead; B-extract-vm has a separate dropped-write
finding in the `mem=:vm` recognisers — same bug class, different code).

## Dedup notes
- Beads confirmed present in `.beads/issues.jsonl`: zmry (open P3), 3wk7 (open P3), tfx (open P2),
  1la (closed), 0c8o (closed), jghk (closed), ej4n (closed), uiaq (closed), wh1p (open P2),
  4ddk (open P1), 9nwt (closed), 8su4 (closed), 6rqq (open). All match the report's descriptions.
- Keyword sweep of issues.jsonl (fshl/funnel, `<8 x i1>`, `__v`, pending sret, atomicrmw,
  bare-name registry) found no other matching open bead.
- Circuit-core / arith triage maps: only F11 (= circuit-core F1 → 4ddk) overlaps.
