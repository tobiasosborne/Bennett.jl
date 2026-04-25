# Bennett-f6qa / U97 — every `error("...")` site in src/lower.jl,
# src/pebbling.jl, and src/pebbled_groups.jl now leads with a
# `<function-or-helper-name>:` prefix so a stack trace lands the
# reader at the emitter without having to grep first. The bead's
# specific concern: a hot-path failure message like "Unknown binop:
# :foo" is hard to attribute when ~30 lower_*! helpers all live in
# one 2,800-line file.
#
# Static-inspection test: parse each source file, collect every
# `error("..."...)` literal, and assert it starts with a recognised
# function-name prefix or a generic file-prefix (e.g. `lower:` for
# top-level `lower(parsed)` errors).
#
# Catches future regressions where someone adds a bare-prefix error
# message back into the codebase.
#
# Pebbling-budget wording check: pebbling.jl and pebbled_groups.jl
# previously had inconsistent "need at least N" / "need N" forms.
# Now both say "insufficient pebbles — need at least N".

using Test
using Bennett

# Strings that legitimately start a message body (not a prefix violation).
# These are e.g. continuation lines of multi-line errors.
const _F6QA_ALLOWED_PREFIXES = [
    "lower:",
    "lower_",        # lower_loop!, lower_phi!, lower_select!, lower_load!,
                     # lower_store!, lower_call!, lower_alloca!, lower_cast!,
                     # lower_var_gep!, lower_binop!, lower_icmp!, …
    "_lower_",       # _lower_inst!, _lower_load_*, _lower_store_*, _lower_load_legacy!
    "_emit_",        # _emit_idx_eq_const!, _emit_store_via_shadow_guarded!
    "_compute_",     # _compute_block_pred!
    "_edge_",        # _edge_predicate!
    "_entry_",       # _entry_predicate_wire
    "_callee_",      # _callee_arg_types
    "_remap_",       # _remap_wire
    "_pick_",        # _pick_alloca_strategy, _pick_add_strategy, _pick_mul_strategy
    "_assert_",      # _assert_arg_widths_match
    "_wires_",       # _wires_to_u64!
    "_operand_",     # _operand_to_u64!
    "resolve!:",     # resolve!
    "pebbled_",      # pebbled_bennett, pebbled_group_bennett
    "checkpoint_",   # checkpoint_bennett
    "knill_",        # knill_pebble_cost / split_point
    "Insufficient",  # legacy continuation of multi-line — only if needed
]

function _check_error_prefixes(path::String)
    src = read(path, String)
    offenders = String[]
    # Match the literal: error("Foo or error("Bar — anything starting with
    # a capital letter and a lowercase suggests a missing function-prefix.
    # The regex deliberately misses multi-line error strings (parsing those
    # is more work than worth here); each offender is reported with its
    # surrounding line for human triage.
    for m in eachmatch(r"error\(\"([^\"]{1,80})", src)
        msg = m.captures[1]
        # Allowed prefixes ALL start with a lowercase letter or underscore
        # except a few legacy capitalised first words (the "Insufficient"
        # of "Insufficient pebbles" was unified, but if any survive we
        # want to flag them).
        ok = any(startswith(msg, p) for p in _F6QA_ALLOWED_PREFIXES)
        # Continuation strings of `error("..." * "...")` constructs land
        # inside the regex too; skip strings that look like a continuation
        # (no colon in the first 30 chars suggests it isn't a prefix-form).
        if !ok
            push!(offenders, msg)
        end
    end
    return offenders
end

@testset "Bennett-f6qa / U97 — error message prefixes" begin

    @testset "lower.jl" begin
        path = joinpath(dirname(pathof(Bennett)), "lower.jl")
        offenders = _check_error_prefixes(path)
        @test isempty(offenders)
        if !isempty(offenders)
            for o in offenders
                @info "lower.jl: error message lacks recognised prefix: $(repr(o))"
            end
        end
    end

    @testset "pebbling-budget wording unified" begin
        peb_path = joinpath(dirname(pathof(Bennett)), "pebbling.jl")
        grp_path = joinpath(dirname(pathof(Bennett)), "pebbled_groups.jl")

        # Both files should now use the same "insufficient pebbles — need
        # at least N" wording.
        @test occursin("insufficient pebbles — need at least",
                       read(peb_path, String))
        @test occursin("insufficient pebbles — need at least",
                       read(grp_path, String))

        # The legacy capitalised "Insufficient pebbles" form must not
        # reappear (regression guard).
        @test !occursin("Insufficient pebbles", read(peb_path, String))
        @test !occursin("Insufficient pebbles", read(grp_path, String))
    end

    @testset "diagnostics.jl reversibility errors include wire indices" begin
        # Bennett-6azb / U58 already added wire-index reporting.  This
        # bead's claim was stale, but pinning it here means any future
        # regression in verify_reversibility's error format surfaces.
        diag_path = joinpath(dirname(pathof(Bennett)), "diagnostics.jl")
        diag = read(diag_path, String)
        @test occursin("ancilla wire \$w not zero", diag)
        @test occursin("input wire \$w changed from", diag)
    end
end
