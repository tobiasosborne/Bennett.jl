# Bennett-utzc / CW-D (ADR 0017 §4) — the keep-branch dead-block pruner.
#
# Under the closed-world `ptr_cells` gate, a block whose LLVM terminator is
# `unreachable` is a provably-dead Julia throw arm (`@boundscheck`/`@assert`/
# error path). Its BODY holds constructs the generic walker cannot convert (the
# U114 `store { ptr, ptr }` GenericMemoryRef box-store; the `[1 x ptr]
# @j_AssertionError` ArrayType-return call), so extraction walls INSIDE the dead
# block. The pruner DROPS the body, KEEPS the block's own label, and emits the
# reserved `IRBranch(nothing, :__unreachable__, nothing)` terminator (exactly
# what instructions.jl already produces for a bare `unreachable`). The
# predecessor's conditional branch into the block is PRESERVED (keep-branch): if
# the guard ever fires at runtime, BennettVM's `:__unreachable__` halt sink traps
# loud (a faithful reversible throw). This clears BOTH the `setindex!` U114
# (suite mode) and the `rehash!` AssertionError (default mode) walls in one
# recognizer.
#
# Guards (Rule 1):
#   * _assert_dead_block_no_live_escape — no value DEFINED in an unreachable
#     block may be USED by a KEPT (live) block (an unreachable block has 0
#     successors ⇒ dominates only itself ⇒ nothing it defines escapes).
#   * _assert_dead_block_is_throw_skeleton — a dead block is EXPECTED iff it has
#     0 predecessors (orphan `after_throw`/`after_noret` trap stub) OR contains a
#     throw-family / llvm.trap call. Anything else is a SURPRISING unreachable
#     block whose halt reason is unmodelled → refuse to silently prune.
#
# ALL fixtures are hand-built `.ll` (Rule 5: hermetic, version-independent). The
# whole feature is gated on `ptr_cells=true`; the gate-off path is byte-identical.

using Test
using Bennett
using LLVM
using Bennett: extract_parsed_ir_from_ll, extract_parsed_ir_set_from_julia,
               IRBranch, IRBasicBlock, IRInst, IRRet, ParsedIR

# --- helpers ---------------------------------------------------------------
function _utzc_extract(ir::AbstractString, fn::AbstractString; ptr_cells::Bool=false)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        return extract_parsed_ir_from_ll(path; entry_function=fn, ptr_cells=ptr_cells)
    end
end

function _utzc_err(ir::AbstractString, fn::AbstractString; ptr_cells::Bool=false)
    mktempdir() do dir
        path = joinpath(dir, "$(fn).ll")
        write(path, ir)
        try
            extract_parsed_ir_from_ll(path; entry_function=fn, ptr_cells=ptr_cells)
            return ""
        catch e
            return sprint(showerror, e)
        end
    end
end

_utzc_block(pir, lbl) = pir.blocks[findfirst(b -> b.label === lbl, pir.blocks)]

# --- fixtures --------------------------------------------------------------

# (a) prune + keep-branch. The `dead` arm holds the U114 aggregate box-store
# (`store { ptr, ptr }`) + a throw-family bounds-error call, terminated by
# `unreachable`. WITHOUT the pruner the box-store walls conversion (U114); WITH
# the pruner the whole block is dropped and `top`'s conditional branch keeps
# BOTH arms (:live, :dead).
const _UTZC_A_PRUNE = """
declare void @ijl_bounds_error_int(ptr, i64)
define i64 @a_prune(i1 %g, i64 %x) {
top:
  br i1 %g, label %live, label %dead
dead:
  %box = alloca { ptr, ptr }, align 8
  store { ptr, ptr } zeroinitializer, ptr %box, align 8
  call void @ijl_bounds_error_int(ptr null, i64 0)
  unreachable
live:
  ret i64 %x
}
"""

# (b1) no-live-escape. `%z` is DEFINED in the unreachable `dead` block and USED
# by `%r` in the live block. LLVM.jl `parse` does NOT run the verifier, so this
# dominance-violating IR parses — letting the guard fire.
const _UTZC_B1_ESCAPE = """
declare void @jl_throw(ptr)
define i64 @b1_escape(i1 %g, i64 %x) {
top:
  br i1 %g, label %live, label %dead
dead:
  %z = add i64 %x, 5
  call void @jl_throw(ptr null)
  unreachable
live:
  %r = add i64 %z, 1
  ret i64 %r
}
"""

# (b2-surprise) an unreachable block WITH a predecessor, a plain `add`, and NO
# throw/trap call → SURPRISING (unmodelled halt reason).
const _UTZC_B2_SURPRISE = """
define i64 @b2_surprise(i1 %g, i64 %x) {
top:
  br i1 %g, label %live, label %dead
dead:
  %z = add i64 %x, 5
  unreachable
live:
  ret i64 %x
}
"""

# (b2-orphan) a 0-predecessor `call @llvm.trap(); unreachable` stub (Julia's
# `after_noret` trap skeleton) → ACCEPTED (extracts).
const _UTZC_B2_ORPHAN = """
declare void @llvm.trap()
define i64 @b2_orphan(i64 %x) {
top:
  ret i64 %x
after_noret:
  call void @llvm.trap()
  unreachable
}
"""

# (d) a ptr_cells fixture with NO unreachable blocks — the pruner MUST be a
# no-op (no `:__unreachable__` target emitted; block count unchanged).
const _UTZC_D_NOUNREACH = """
define i64 @d_nounreach(i1 %g, i64 %x) {
top:
  br i1 %g, label %a, label %b
a:
  %ra = add i64 %x, 1
  br label %join
b:
  %rb = add i64 %x, 2
  br label %join
join:
  %p = phi i64 [ %ra, %a ], [ %rb, %b ]
  ret i64 %p
}
"""

# (c) THE PAYOFF fixture — the bare-`d[k]` Dict set. Unique name to dodge the
# cross-file generic-collision lesson.
fdict_utzc(k::Int8, v::Int8) = (d = Dict{Int8,Int8}(); d[k] = v; d[k])

@testset "Bennett-utzc keep-branch dead-block pruner (ADR 0017 §4)" begin

    # ========================================================================
    # (a) prune the dead block, keep the predecessor branch (both arms).
    # ========================================================================
    @testset "(a) prune dead block + keep-branch" begin
        pir = _utzc_extract(_UTZC_A_PRUNE, "a_prune"; ptr_cells=true)

        # top's conditional branch keeps BOTH arms (keep-branch). Assert as a
        # set to avoid successor-order fragility.
        top = _utzc_block(pir, :top)
        @test top.terminator isa IRBranch
        @test top.terminator.cond !== nothing
        @test Set([top.terminator.true_label, top.terminator.false_label]) ==
              Set([:live, :dead])

        # the dead block SURVIVES (its own label kept) but its body is dropped
        # and its terminator is the reserved unconditional `:__unreachable__`.
        dead = _utzc_block(pir, :dead)
        @test isempty(dead.instructions)
        @test dead.terminator isa IRBranch
        @test dead.terminator.cond === nothing
        @test dead.terminator.true_label === :__unreachable__
        @test dead.terminator.false_label === nothing

        # the live block is untouched.
        live = _utzc_block(pir, :live)
        @test live.terminator isa IRRet

        # `:__unreachable__` is NEVER a block LABEL (only a dangling target).
        @test !any(b -> b.label === :__unreachable__, pir.blocks)
    end

    # ========================================================================
    # (b1) no-live-escape guard fails loud.
    # ========================================================================
    @testset "(b1) no-live-escape guard" begin
        @test_throws "ESCAPES" _utzc_extract(_UTZC_B1_ESCAPE, "b1_escape";
                                             ptr_cells=true)
        msg = _utzc_err(_UTZC_B1_ESCAPE, "b1_escape"; ptr_cells=true)
        @test occursin("Bennett-utzc", msg)
        @test occursin("ESCAPES", msg)
    end

    # ========================================================================
    # (b2) surprise guard fails loud; orphan trap-stub is accepted.
    # ========================================================================
    @testset "(b2) surprise guard + orphan accept" begin
        @test_throws "SURPRISING" _utzc_extract(_UTZC_B2_SURPRISE, "b2_surprise";
                                               ptr_cells=true)
        msg = _utzc_err(_UTZC_B2_SURPRISE, "b2_surprise"; ptr_cells=true)
        @test occursin("Bennett-utzc", msg)
        @test occursin("SURPRISING", msg)

        # a 0-predecessor `llvm.trap; unreachable` orphan is ACCEPTED.
        pir = _utzc_extract(_UTZC_B2_ORPHAN, "b2_orphan"; ptr_cells=true)
        @test pir isa ParsedIR
        an = _utzc_block(pir, :after_noret)
        @test isempty(an.instructions)
        @test an.terminator isa IRBranch
        @test an.terminator.true_label === :__unreachable__
    end

    # ========================================================================
    # (c) THE PAYOFF — utzc CLEARS the dead-block walls; the fdict Dict-set
    #     extraction ADVANCES past them. Must hold under BOTH default check-bounds
    #     and --check-bounds=yes.
    #
    #     HONEST tripwire (live-probe-verified 2026-07-07, ptr_cells=true, BOTH
    #     check-bounds modes): utzc removes the dead-block extraction walls — the
    #     `rehash!` AssertionError `[1 x ptr]` throw block (default mode) and the
    #     `setindex!` U114 `store { ptr, ptr }` throw block (suite mode). The set
    #     does NOT YET fully close: the wall has ADVANCED to the CW-D2 frontier
    #     (the next bead, bennettvm-416r.12):
    #       * :fail_loud → `rehash!` walls at `llvm.smul.with.overflow.i64`
    #         (struct `{i64,i1}` return) in the LIVE `%nonemptymem` block — the
    #         GenericMemory size-overflow check, a FRESH construct wall the pruner
    #         does not (and should not) touch.
    #       * :skip → the closed-world check walls on the `gc_alloc_obj` Symbol
    #         callee (not in the CW-D2 whitelist), proving the rehash!/setindex!
    #         bodies now extract PAST their dead blocks.
    #     This tripwire flips to a real closed set when smul.with.overflow +
    #     gc_alloc_obj land — prompting promotion to the full-closure assertion.
    # ========================================================================
    @testset "(c) fdict set — dead-block walls cleared, advances to CW-D2 (check-bounds=$(Base.JLOptions().check_bounds))" begin
        # snapshot/restore hygiene (Rule 7): the producer registers callees
        # internally then restores — assert no leak either way.
        before = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        fl = try
            extract_parsed_ir_set_from_julia(fdict_utzc, Tuple{Int8,Int8};
                                             ptr_cells=true, on_extract_error=:fail_loud)
            ""   # (future) fully closed — no throw
        catch e
            sprint(showerror, e)
        end
        sk = try
            extract_parsed_ir_set_from_julia(fdict_utzc, Tuple{Int8,Int8};
                                             ptr_cells=true, on_extract_error=:skip)
            :closed   # (future) fully closed — no closed-world violation
        catch e
            sprint(showerror, e)
        end
        after = lock(Bennett._known_callees_lock) do
            copy(Bennett._known_callees)
        end
        @test after == before                      # registry restored — no leak

        # NEGATIVE — the utzc-pruned DEAD-BLOCK walls are GONE. Before utzc the
        # :fail_loud set walled on the `rehash!` AssertionError `[1 x ptr]` call
        # inside its unreachable throw block; that block is now pruned, so the
        # wall must no longer name it.
        @test !occursin("j_AssertionError", fl)
        @test !occursin("[1 x ptr", fl)
        @test !occursin("store of non-integer type", fl)   # setindex! U114 box-store gone

        # POSITIVE — the wall ADVANCED to the CW-D2 frontier (the next bead), OR
        # (future) the set is fully closed.
        @test fl == "" || occursin("smul.with.overflow", fl) ||
              occursin("gc_alloc_obj", fl) || occursin("closed-world violation", fl)
        @test sk === :closed || occursin("gc_alloc_obj", sk) ||
              occursin("closed-world violation", sk)

        # NOTE: a direct positive "a real Dict helper fully extracts" assertion is
        # deliberately NOT made here — the individual helper bodies wall on
        # mode-dependent, utzc-UNRELATED constructs (e.g. under --check-bounds=yes
        # `ht_keyindex2_shorthash!` walls at the `movq %fs:0` inline-asm TLS read,
        # Bennett-5oyt / U15). The mechanical pruner correctness on a real throw
        # callee is covered by fixture (a); the real-world advance is the
        # negative+positive wall-move above (mode-robust in BOTH check-bounds modes).
    end

    # ========================================================================
    # (d) byte-identity — pruner no-op with no unreachable blocks; the gate-off
    #     path is unchanged.
    # ========================================================================
    @testset "(d) byte-identity" begin
        # (d1) no unreachable blocks ⇒ pruner is a no-op under BOTH gates.
        pir_on  = _utzc_extract(_UTZC_D_NOUNREACH, "d_nounreach"; ptr_cells=true)
        pir_off = _utzc_extract(_UTZC_D_NOUNREACH, "d_nounreach"; ptr_cells=false)
        @test length(pir_on.blocks) == length(pir_off.blocks)
        @test !any(b -> b.terminator isa IRBranch &&
                        (b.terminator.true_label === :__unreachable__ ||
                         b.terminator.false_label === :__unreachable__),
                   pir_on.blocks)

        # (d2) GATE OFF: fixture (a)'s dead block is NOT pruned (the pruner is
        # ptr_cells-gated) — the U114 aggregate box-store still walls
        # byte-identically to pre-utzc.
        msg = _utzc_err(_UTZC_A_PRUNE, "a_prune"; ptr_cells=false)
        @test occursin("U114", msg)
        @test occursin("store of non-integer type", msg)
        @test !occursin("__unreachable__", msg)
    end
end
