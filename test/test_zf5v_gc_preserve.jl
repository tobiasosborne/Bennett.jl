# Bennett-zf5v — CW-D2: gc_preserve token drop + get_pgcstack allowlist.
#
# 3+1 adjudication (docs/design/Bennett-zf5v-gc_preserve-consensus.md):
# Proposer B re-probed at optimize=FALSE — the closed-world producer's body
# level — and OVERTURNED the bead's get_pgcstack-inline-asm premise. At
# optimize=false the ROOT `fdict_d1b` walls at `llvm.julia.gc_preserve_begin`
# (return type `token` → the ptr_cells C-call arm's TokenType wall), NOT at
# get_pgcstack: the named intrinsic `@julia.get_pgcstack()` ALREADY lowers
# cleanly to a 64-bit cell IRCall here (the `movq %fs:0` inline-asm form is an
# optimize=TRUE artifact, off the real path).
#
# Two surgical, additive, ptr_cells-gated edits:
#   1. src/extract/instructions.jl — in the ptr_cells C-call arm, at the TOP
#      (before the variadic-arg loop AND before the return-type check), drop
#      `llvm.julia.gc_preserve_begin` (token return) and `gc_preserve_end`
#      (void; consumes only the token) → `return nothing`. Pure GC-rooting
#      bookkeeping; no value semantics in the deterministic VM cell model. The
#      preserved-pointer args live independently (only the rooting token is
#      dropped; the token SSA is consumed ONLY by gc_preserve_end, also dropped,
#      so no dangling SSA reference). Placement at the top is REQUIRED:
#      gc_preserve_begin is variadic (`call token (...)`), so a lower placement
#      would hit the arg-carry / TokenType error first.
#   2. src/extract/julia_set.jl — add `"julia.get_pgcstack"` to
#      `_D1B_BENIGN_INTRINSIC_PREFIXES` so the emitted get_pgcstack cell IRCall
#      survives `_closed_world_check!` (the cell is MODELED — it feeds the
#      `gep -152` current_task chain — NOT dropped).
#
# Gate map (per the consensus doc's test plan):
#   (a) hand-built .ll: gc_preserve_begin(token)+gc_preserve_end(void) DROPPED
#       under ptr_cells=true; the surrounding chain lowers intact (positive
#       node shape — Rule 4, not just no-throw). RED today (TokenType wall).
#   (b) ptr_cells=false: the SAME fixture still walls (byte-identity — the drop
#       is inside the ptr_cells C-call arm, which is gate-off skipped).
#   (c) fail-loud (Rule 1): a DIFFERENT token-returning callee still walls at the
#       TokenType error (the drop is exact-name-scoped); a non-allowlisted inline
#       asm still walls at U15. The band is NOT broadened.
#   (d) real `fdict_d1b` root wall-ADVANCE (optimize=false, ptr_cells=true):
#       NEGATIVE (no longer gc_preserve/TokenType) + POSITIVE inclusive
#       disjunction of plausible successors (gc_alloc_obj / genericmemory /
#       memcpy / insertvalue / unregistered-callee …). Registry snapshot/restore
#       (Rule 7 — no _known_callees leak).

using Test
using Bennett
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir,
               register_callee!, ParsedIR, IRCall, IRPtrOffset, IRLoad

# ---------------------------------------------------------------------------
# Hand-built .ll fixtures (Rule 5: hermetic, version-independent). The
# gc_preserve intrinsics are VARIADIC — `declare token @...(...)` /
# `declare void @...(...)` with the `call token (...)` / `call void (...)`
# call syntax (probe-confirmed LLVM accepts this exact shape).
# ---------------------------------------------------------------------------

# The real-path shape in miniature: get_pgcstack lowers to a 64-bit cell IRCall;
# gc_preserve_begin's token + gc_preserve_end are pure rooting bookkeeping that
# must be DROPPED; the surrounding ptr chain (gep + load) lowers as cells.
# Returns the loaded `ptr` directly (a 64-bit cell return under ptr_cells) — no
# trailing `ptrtoint`, which is its OWN separate opcode wall (the next CW-D
# lever, observed on the real fdict_d1b root) and would mask this drop proof.
const GCP_CHAIN = """
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(...)
declare ptr @julia.get_pgcstack()

define ptr @gcp_chain(ptr %g) {
top:
  %pgc = call ptr @julia.get_pgcstack()
  %t = call token (...) @llvm.julia.gc_preserve_begin(ptr %g)
  %task = getelementptr i8, ptr %pgc, i64 -152
  %slot = getelementptr i8, ptr %task, i64 168
  %loaded = load ptr, ptr %slot, align 8
  call void (...) @llvm.julia.gc_preserve_end(token %t)
  ret ptr %loaded
}
"""

# A MINIMAL gc_preserve fixture (no get_pgcstack), so under cells=false the
# gc_preserve_begin call is the FIRST wall reached — the focused byte-identity
# witness that the circuit path does NOT silently drop gc_preserve. Under
# cells=true this also exercises the drop in isolation: both intrinsics vanish
# and only the surrounding ptr→i64 lowering survives.
const GCP_MINIMAL = """
declare token @llvm.julia.gc_preserve_begin(...)
declare void @llvm.julia.gc_preserve_end(...)

define i64 @gcp_minimal(ptr %g) {
top:
  %t = call token (...) @llvm.julia.gc_preserve_begin(ptr %g)
  call void (...) @llvm.julia.gc_preserve_end(token %t)
  %v = ptrtoint ptr %g to i64
  ret i64 %v
}
"""

# A DIFFERENT token-returning call (NOT gc_preserve) — must STILL wall at the
# TokenType error (exact-name scoping; the drop must not broaden to all tokens).
const OTHER_TOKEN = """
declare token @some.other.token.intrinsic(...)

define i64 @other_token_root(ptr %g) {
top:
  %t = call token (...) @some.other.token.intrinsic(ptr %g)
  %v = ptrtoint ptr %g to i64
  ret i64 %v
}
"""

# A non-allowlisted inline-asm call — must STILL wall at U15.
const INLINE_ASM = """
define i64 @asm_root() {
top:
  %v = call i64 asm "movq %fs:0, \$0", "=r"()
  ret i64 %v
}
"""

# Extract a hand-built .ll fixture, returning (:ok, pir) or (:err, message).
function _extract_ll(name, ir, entry; cells)
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

# Collect all instructions across blocks.
_all_insts(pir) = [ins for b in pir.blocks for ins in b.instructions]

# Is `msg` the ptr_cells C-call-arm TokenType wall?
_is_token_wall(msg) =
    occursin("unsupported return type", msg) && occursin("TokenType", msg)

@testset "Bennett-zf5v gc_preserve token drop + get_pgcstack allowlist" begin

    # =======================================================================
    # GATE (a) — cells=true: gc_preserve_begin/_end DROPPED; chain lowers.
    # Positive node-shape assertions (Rule 4: no-throw is not a pass).
    # =======================================================================
    @testset "GATE (a) — gc_preserve dropped under ptr_cells, chain lowers intact" begin
        (st, pir) = _extract_ll("gcp_chain", GCP_CHAIN, "gcp_chain"; cells=true)
        @test st === :ok
        if st === :ok
            insts = _all_insts(pir)
            # The two gc_preserve intrinsics are ABSENT from the lowered stream
            # (dropped). No IRCall whose callee mentions gc_preserve survives.
            calls = filter(x -> x isa IRCall, insts)
            preserve_calls = filter(calls) do c
                occursin("gc_preserve", lowercase(string(c.callee)))
            end
            @test isempty(preserve_calls)

            # The surrounding chain DID lower: get_pgcstack survives as a cell
            # IRCall (it is MODELED, not dropped — it feeds the current_task
            # chain); the gep -152 / +168 lowers as IRPtrOffset; the load as a
            # 64-bit cell IRLoad.
            pgc_calls = filter(c -> occursin("get_pgcstack", lowercase(string(c.callee))), calls)
            @test length(pgc_calls) == 1
            @test pgc_calls[1].ret_width == 64                 # one Int64 VM cell

            offsets = filter(x -> x isa IRPtrOffset, insts)
            @test length(offsets) >= 1                          # the gep -152/+168 chain
            loads = filter(x -> x isa IRLoad, insts)
            @test length(loads) == 1
            @test loads[1].width == 64
        end
    end

    # =======================================================================
    # GATE (b) — cells=false: SAME fixture still walls (byte-identity). The
    # drop lives inside the ptr_cells C-call arm (gate-off skipped); a
    # gc_preserve call is then an unregistered callee → U15 fail-loud. NO
    # gc_preserve IRCall is silently created on the circuit path.
    # =======================================================================
    @testset "GATE (b) — cells=false still walls (byte-identity, no drop)" begin
        # Minimal fixture (no get_pgcstack): gc_preserve_begin is the FIRST wall
        # under cells=false. The drop lives inside the ptr_cells C-call arm
        # (gate-off skipped), so gc_preserve_begin is an unregistered callee →
        # U15 fail-loud — it is NOT silently dropped on the circuit path.
        (st, msg) = _extract_ll("gcp_minimal_off", GCP_MINIMAL, "gcp_minimal"; cells=false)
        @test st === :err
        if st === :err
            @test occursin("gc_preserve_begin", msg)
            @test occursin("Bennett-5oyt / U15", msg)
        end
    end

    # =======================================================================
    # GATE (c) — fail-loud (Rule 1): the drop is EXACT-NAME-scoped. A different
    # token-returning callee still walls at TokenType; a non-allowlisted inline
    # asm still walls at U15. The accepted band is NOT broadened.
    # =======================================================================
    @testset "GATE (c) — other token call + inline asm still fail loud" begin
        (sto, msgo) = _extract_ll("other_token", OTHER_TOKEN, "other_token_root"; cells=true)
        @test sto === :err
        sto === :err && @test _is_token_wall(msgo)

        (sta, msga) = _extract_ll("asm_root", INLINE_ASM, "asm_root"; cells=true)
        @test sta === :err
        sta === :err && @test occursin("inline-asm call is not supported", msga) &&
                              occursin("Bennett-5oyt / U15", msga)
    end

    # =======================================================================
    # GATE (d) — real fdict_d1b root wall-ADVANCE under cells=true. The root
    # `fdict_d1b(a,b) = (d=Dict{Int8,Int8}(); d[a]=b; d[a])` walls at the
    # gc_preserve_begin TokenType pre-fix; post-fix the drop fires and a LATER
    # wall surfaces. Assert NEGATIVELY (no longer gc_preserve/TokenType) plus an
    # inclusive disjunction of plausible successors (Rule 5 — order-dependent).
    # Registry snapshot/restore (Rule 7 — no _known_callees leak).
    # =======================================================================
    @testset "GATE (d) — fdict_d1b root advances past the gc_preserve TokenType wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        added = String[]
        try
            at = Tuple{Int8,Int8}

            # cells=true: the gc_preserve_begin TokenType wall must be GONE.
            # Either it extracts, or it advances to a DIFFERENT (later) wall.
            on_msg = try
                extract_parsed_ir(fdict_d1b, at; optimize=false, ptr_cells=true)
                nothing
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            if on_msg === nothing
                @test true  # fully extracted — even stronger than wall-advance
            else
                # NEGATIVE: no longer the gc_preserve TokenType wall.
                @test !(occursin("gc_preserve", lowercase(on_msg)) && _is_token_wall(on_msg))
                # POSITIVE inclusive disjunction of plausible CW-D successors.
                # OBSERVED successor (2026-06-20, optimize=false, this machine):
                # `ptrtoint ... unsupported LLVM opcode` — the root casts the
                # freshly-allocated `Dict` ptr to i64 (`%Dict = ptrtoint ptr
                # %"+Main.Base.Dict#..." to i64`) right after the (now-dropped)
                # gc_preserve_begin. THIS is the next CW-D lever. (Rule 5: keep
                # the disjunction inclusive of all plausible successors so an IR
                # shuffle does not falsely red this wall-advance proof.)
                #
                # UPDATED (2026-06-23, Bennett-iwo9 / CW-D3 Lever 1): the
                # type-tag round-trip is now modelled, so the `ptrtoint`/
                # `inttoptr` wall is CLEARED and the root advances further into
                # the Dict body — the NEW observed successor on this machine is
                # `ConstantPointerNull operand: ptr null … (Bennett-bjdg / U80)`
                # (a `ptr null` operand deeper in the inlined setindex!/getindex
                # path). Added `null` / `U80` to the disjunction so the
                # wall-advance proof stays green; this is the EXPECTED Lever-1
                # advance, not a regression.
                @test occursin("ptrtoint", lowercase(on_msg))        ||
                      occursin("null", lowercase(on_msg))            ||
                      occursin("U80", on_msg)                        ||
                      occursin("unsupported llvm opcode", lowercase(on_msg)) ||
                      occursin("gc_alloc_obj", lowercase(on_msg))    ||
                      occursin("genericmemory", lowercase(on_msg))   ||
                      occursin("memcpy", lowercase(on_msg))          ||
                      occursin("insertvalue", lowercase(on_msg))     ||
                      occursin("aggregate", lowercase(on_msg))       ||
                      occursin("structtype", lowercase(on_msg))      ||
                      occursin("atomic", lowercase(on_msg))          ||
                      occursin("U14", on_msg)                        ||
                      occursin("VoidType", on_msg)                   ||
                      occursin("U81", on_msg)                        ||
                      occursin("sret", lowercase(on_msg))            ||
                      occursin("U15", on_msg)                        ||
                      occursin("no registered callee", on_msg)       ||
                      occursin("closed-world", on_msg)               ||
                      occursin("PointerType", on_msg)
            end
        finally
            lock(Bennett._known_callees_lock) do
                for k in added
                    if haskey(before, k)
                        Bennett._known_callees[k] = before[k]
                    else
                        delete!(Bennett._known_callees, k)
                    end
                end
            end
        end

        # No registry leak.
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before
    end

end
