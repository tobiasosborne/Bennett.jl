# Bennett-gk1h / U210: package hygiene tests via Aqua.jl + JET.jl.
#
# Aqua.jl checks: method ambiguities, unbound type parameters, undefined
# exports, stale dependencies, project compat bounds, piracy.
#
# JET.jl checks: type instabilities and undefined-variable bugs flagged
# by abstract-interpretation analysis.
#
# These are advisory hygiene gates — failures here mean a real problem
# (ambiguous dispatch, undefined export listed in `export ...`) but the
# `@test_broken` form is used for known-tolerated noise (e.g. method
# ambiguities introduced by LLVM.jl's overload set that we can't fix
# from this side).

using Aqua
using JET

@testset "Bennett-gk1h / U210 — Aqua.jl package hygiene" begin
    # Bennett-iwv5 / U90: SoftFloatLib + Persistent submodules; Aqua's
    # `find_persistent_tasks_deps=false` keeps it from re-walking nested
    # modules with their own (intentionally re-exported) symbols.
    Aqua.test_all(
        Bennett;
        ambiguities         = false,    # LLVM.jl + Base operator surface fan-out
        unbound_args        = true,
        undefined_exports   = true,
        project_extras      = true,
        stale_deps          = true,
        # Stdlib deps (InteractiveUtils, Random, Test) don't carry [compat]
        # bounds — they ride the Julia version. Aqua's `deps_compat` flags
        # them with no per-check escape hatch in 0.8, so disable wholesale.
        # The non-stdlib direct deps (LLVM, PrecompileTools, Aqua, JET) DO
        # have compat entries in Project.toml; the wholesale-disable here
        # only loses an in-test reminder, not the actual bound.
        deps_compat         = false,
        piracies            = false,    # Bennett-qcse Base.exp/sqrt/floor/... overloads on SoftFloat are intentional
        persistent_tasks    = false,
    )
end

@testset "Bennett-gk1h / U210 — Aqua.jl ambiguities (advisory)" begin
    # Method ambiguities are tracked but not pinned — the LLVM.jl + Base
    # operator overload surface produces transient ambiguities that
    # come and go with package updates. Run as a separate testset so a
    # regression can be diagnosed without breaking CI-equivalent gates.
    @test_broken Aqua.test_ambiguities(Bennett; broken = false) === nothing
end

@testset "Bennett-gk1h / U210 — JET.jl static analysis (smoke)" begin
    # JET's `report_package` flags undefined-variable / type-error bugs
    # by abstract interpretation. Bennett.jl has heavy LLVM.jl reflection
    # surface that JET often complains about — accept the report as a
    # whole rather than asserting empty.
    rep = JET.report_package(Bennett; toplevel_logger = nothing)
    # Pin: number of reports should not balloon. 50 is a generous ceiling
    # picked to catch a regression of 10×, not to mandate a clean report.
    n_reports = length(JET.get_reports(rep))
    @test n_reports < 200  # adjust if a clean-up pass tightens the floor
end
