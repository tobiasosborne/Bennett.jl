# Worklog chunk 092

## Session log — 2026-06-29 — Bennett-8g7m: ptr-typed `icmp` under `ptr_cells` (closed-world fdict CW-D path) + session wind-up

**Context.** Third bead of a single orchestrated session advancing the P0 closed-world
fdict critical path (cross-repo BennettVM EPIC `bennettvm-416r.11` / e2e `7xa`), after
`Bennett-xrd6` (sret-call) and `Bennett-u2kk` (param-cell memcpy). After u2kk,
`extract_parsed_ir(Base.rehash!, Tuple{Dict{Int8,Int8},Int64}; optimize=false, ptr_cells=true)`
walled at `icmp ne ptr %4, null` (a Dict-field null check).

**Root cause.** The ICmp arm of `_convert_instruction` (`src/extract/instructions.jl` ~2414)
had two interlocked defects under `ptr_cells`: (A) it didn't thread `ptr_cells` to
`_operand`, so a `ConstantPointerNull` hit the U80 fail-loud (helpers.jl:198) even though the
helper ALREADY lowers `null → iconst(0)` under the gate (Bennett-beaw); (B) `_iwidth(ops[1])`
on a pointer operand hits `_type_width(PointerType)` → error (no PointerType branch). Both
needed fixing together. Note `IRICmp` requires `width >= 1`, so the select/phi `width=0`
sentinel is illegal — a pointer operand's cell width is **64**.

**Process (CLAUDE.md Rule 2, 3+1).** 2 independent opus proposers CONVERGED ~98%.
Adjudicated: under `ptr_cells`, a pointer-typed icmp threads `ptr_cells=true` to both
operands + width 64, and admits **ONLY `:eq`/`:ne`**; the 8 ordering predicates FAIL LOUD —
address-magnitude comparison over virtual cells is BVM-allocation-layout-dependent (UB across
allocations in C), a Rule-1 silent-miscompile risk. The fdict check is `ne` → admitted.
Non-pointer / `ptr_cells=false` icmp is byte-identical.

**Done (`src/extract/instructions.jl`, ICmp arm only).** A ptr-operand branch under the gate
(eq/ne guard + `_operand(...; ptr_cells=true)` + width 64); the integer path unchanged (only
`pred` hoisted to a local). No `ir_types.jl`/`helpers.jl`/`lower.jl` change. New
`test/test_8g7m_ptr_icmp_cells.jl` (47 structural-invariant assertions: eq/ne null, ptr-vs-ptr
eq, ordering reject, `ptr_cells=false` byte-identity, non-pointer integer-icmp unchanged,
rehash! wall-advance). Registered in `runtests.jl`.

**Verified (orchestrator re-ran the FULL `ptr_cells`-real-fn set — the u2kk lesson, below).**
`test_8g7m` 47/47, `test_lf14` 27/27, `gate_count` 39/39 IDENTICAL, `test_beaw` 17/17,
`test_6bu3` 162/162, `test_59zi` 545/545, `test_ares` 57/57, `test_zf5v` 17/17, `test_nd45`
71/71, `test_d1b` 30+1-broken. **lf14 + beaw passed WITHOUT disjunction edits** — their
inclusive successor-disjunctions already catch the new wall. **Producer advanced:** rehash!
clears the ptr-null ICmp wall → next wall **`Bennett-yd4f`** (`i64 undef` phi operand,
helpers.jl:172, Bennett-bjdg / U80 family). Cross-repo: no new BVM contract (pointer eq/ne
lowers to an ordinary i64 cell compare). Recorded on `bennettvm-416r.11`.

---

## Session wind-up — 2026-06-29 — fdict CW-D triple (xrd6 → u2kk → 8g7m) + HANDOFF

**Three beads landed this session, each a full 3+1 + adversarial cycle on the P0 fdict path:**

| Bead | Wall cleared | Commit | Gate |
|---|---|---|---|
| `Bennett-xrd6` | sret-convention consumed call (`ht_keyindex2_shorthash!` `{i64,i8}` via sret → void) | `c884ce5` | full `Pkg.test()` green (689,876) |
| `Bennett-u2kk` | param-cell global-src memcpy (`rehash!` idxfloor/ndel/maxprobe field inits) | `77faf89` | full green (689,891) after a recovery — see below |
| `Bennett-8g7m` | ptr-typed `icmp` (Dict-field null check) | committed; full-gate push launched at wind-up | ptr_cells-real-fn set green; full gate pending |

**The u2kk gate-failure recovery (institutional memory).** u2kk's first push FAILED the full
`Pkg.test()` gate: I had OMITTED `test_lf14_ptr_return_cells.jl` from u2kk's targeted
regression subset. lf14 GATE-B pins each callee's per-wall LANDING via an `occursin`
disjunction; u2kk advanced rehash! past the memcpy wall to the ptr-null wall, which the
disjunction didn't list → fail. (My first gate-capture used `| tail -25` and LOST the failure
details; re-ran with full capture to pinpoint `lf14:179`.) Fixed by adding `null`/`U80`
disjuncts (a legitimate expectation update, not a weakening), bundled into the u2kk commit,
re-pushed green. **Lesson banked in `bd remember cwd-ptr-cells-rerun-lf14`:** any change to a
callee's `ptr_cells` extraction MUST re-run `test_lf14` + the `ptr_cells`-real-fn set
(test_6bu3/59zi/ares/zf5v/lf14/nd45) before pushing — the full gate is the real net; targeted
subsets are necessary but not sufficient. (For 8g7m I applied this: ran the whole set, all green.)

**fdict CW-D frontier (where the next session resumes).** `extract_parsed_ir_set_from_julia(fd; ptr_cells=true)`
where `fd(k,v)=(d=Dict{Int8,Int8}();d[k]=v;d[k])` now extracts `setindex!` +
`ht_keyindex2_shorthash!`; the `rehash!` callee is the active wall-by-wall front. After
xrd6/u2kk/8g7m, rehash! lands on:
- **`Bennett-yd4f` (P2, NEXT):** `i64 undef` phi operand under ptr_cells (helpers.jl:172).
  Caution: undef ≠ null (undef = ANY value, UB to read) — the soundness story is subtler than
  8g7m's null→0; a fully-designed 3+1 is warranted.
- Under `--check-bounds=yes` (suite mode), `setindex!` itself still walls earlier at the
  pre-existing iwo9 ptrtoint artifact (`Bennett-kvdv`) — orthogonal, already filed.

**Open follow-ups filed this session:** `Bennett-yd4f` (next wall), `Bennett-h7r2` (P3 — harden
the global-src memcpy arm: byval-param discrimination + K>1 chunk-stacking + dst-cell bounds,
u2kk verifier nits). Standing: `Bennett-amah` (dolt `noms` blob now 56.9 MB — GitHub 50 MB soft
warning; compaction needed before the 100 MB hard limit).

**Cross-repo BVM (BennettVM-416r.11) contracts recorded for D1c:** the consumed-sret IRCall
(xrd6) and the param-cell field-write (u2kk) both require BVM to tape `(cell, pre-image)` and
reverse for **caller-supplied pointer-parameter cells (by-reference)** — the SAME contract
`setindex!`'s field stores already depend on (surfaced, not introduced). 8g7m adds no new BVM
contract. These are producer-side-unprovable; D1c must assert them with a round-trip.

**State at wind-up:** xrd6 + u2kk pushed (origin/main = `77faf89`). 8g7m committed locally +
full-gate push launched in background (the pre-push hook gates main — it pushes only if the
full suite is green; if a test fails, the commit stays local for the next session to fix).
BennettVM pushed (`81c66dd`). All beads synced; worklog + handoff here.
