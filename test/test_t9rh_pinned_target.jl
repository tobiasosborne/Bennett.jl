# Bennett-t9rh (commit 2): host-independent `optimize=true` IR.
#
# `code_llvm(optimize=true)` runs Julia's O-pipeline under the HOST JIT
# TargetMachine and the session `-O` level, so before this bead the IR Bennett
# compiled — and every gate count derived from it — silently depended on the
# host CPU (AVX-512 hosts even crashed on soft_fmul / soft_fma via SLP poison
# lanes) and on `julia -O`. `src/extract/target_pin.jl` now re-runs Julia's
# own `julia<level=2>` pipeline in-process under a pinned TargetMachine
# (`x86-64-v3` on x86_64 — maintainer decision; `generic` elsewhere).
#
# This file pins:
#   (1) the bead repro (fneg∘fmul) + soft_fmul / soft_fma / soft_fcmp_olt —
#       bit-exact AND gate totals, identical on every host;
#   (2) the pinned constants and the single-routing of every optimize=true
#       entry (extract_parsed_ir / extract_ir / _code_llvm_by_sig);
#   (3) real AVX-512 SLP IR (test hook `cpu="skylake-avx512"`) compiles
#       bit-exactly through the poison-lane propagation of commit 1;
#   (4) host independence: `julia -C x86-64 -O1` and `julia -C znver3`
#       subprocesses reproduce the in-process gate counts for
#       vector/unroll-sensitive fixtures;
#   (5) a fidelity canary: the pinned path equals `code_llvm(optimize=true)`
#       from a `julia -C x86-64-v3` subprocess (normalised), so a Julia
#       upgrade that changes what code_llvm does beyond the pipeline is caught.

using Test
using Bennett
using InteractiveUtils: code_llvm
using Random

include(joinpath(@__DIR__, "..", "benchmark", "cc07_repro_n16.jl"))   # ls_demo_16

# `k` idiom: AVX2 loop vectoriser emits a splat with poison mask lanes.
# (Used by the fidelity canary only: under --check-bounds=yes its bounds-error
# path keeps a GC frame whose thread-pointer inline asm Bennett rejects.)
t9rh_k(x::Int64) = (a = zeros(Int64, 4); for i in 1:4; a[i] = x * i; end; a[2] + a[4])

const _T9RH_F64_EDGES = UInt64[
    0x0000000000000000, 0x8000000000000000,          # ±0
    0x7ff0000000000000, 0xfff0000000000000,          # ±Inf
    0x7ff8000000000000, 0x7ff4000000000000,          # qNaN, sNaN
    0x0000000000000001, 0x000fffffffffffff,          # subnormals
    0x0010000000000000, 0x7fefffffffffffff,          # min normal, max finite
    reinterpret(UInt64, 1.0), reinterpret(UInt64, -2.5),
    reinterpret(UInt64, 1e-310), reinterpret(UInt64, 1e308),
    reinterpret(UInt64, 3.0), reinterpret(UInt64, -0.1)]

function _t9rh_f64_pairs(n_random; seed=0x79b3)
    rng = Random.MersenneTwister(seed)
    pairs = [(a, b) for a in _T9RH_F64_EDGES for b in _T9RH_F64_EDGES]
    append!(pairs, [(rand(rng, UInt64), rand(rng, UInt64)) for _ in 1:n_random])
    return pairs
end

# Normalise LLVM IR text so two emissions of the same function compare equal:
# Julia's per-emission mangling counters, LLVM value-name / block-label
# uniquing suffixes, attribute-group / metadata ids, process-specific JIT
# pointer literals (type tags) and comment lines are the only differences
# between two faithful emissions.
function _t9rh_norm_ir(s::AbstractString)
    out = String[]
    for l in split(s, '\n')
        l = rstrip(l)
        (isempty(l) || startswith(l, ";") || startswith(l, "!")) && continue
        l = replace(l, r"(julia|j|jlplt|jfptr|jl_global|jl_sym|ccall|ijl|jl|\+|Core|Main)([A-Za-z0-9_.#!\"]*?)_\d+\b" => s"\1\2_N")
        l = replace(l, r"#\d+" => "#N")
        l = replace(l, r"%([A-Za-z._][A-Za-z0-9._]*?)\d+\b" => s"%\1N")
        l = replace(l, r"^([A-Za-z._][A-Za-z0-9._]*?)\d+:" => s"\1N:")     # block labels
        l = replace(l, r"!\d+" => "!N")
        l = replace(l, r"i64 \d{9,} to ptr" => "i64 ADDR to ptr")
        # process-specific JIT type-tag / heap addresses (14-15 decimal digits)
        l = replace(l, r"\b\d{14,15}\b" => "ADDR")
        push!(out, l)
    end
    return out
end

# A `julia` command for a subprocess that loads THIS Bennett (works both
# standalone and under Pkg.test's temporary environment). The trailing `-C`
# overrides `julia_cmd()`'s `-C native` (last one wins).
function _t9rh_subjulia(flags::Vector{String}, script::AbstractString)
    cmd = `$(Base.julia_cmd()) $flags --startup-file=no --project=$(Base.active_project()) -e $script`
    return addenv(cmd, "JULIA_LOAD_PATH" => join(LOAD_PATH, Sys.iswindows() ? ';' : ':'))
end

@testset "Bennett-t9rh: pinned, host-independent optimize=true IR" begin

    @testset "(1) bead repro + soft-float pins, bit-exact on every host" begin
        f_nm = (a, b) -> soft_fneg(soft_fmul(a, b))
        c = reversible_compile(f_nm, UInt64, UInt64)
        @test gate_count(c).total == 149_588
        @test verify_reversibility(c; n_tests=3)
        ok = true
        for (a, b) in _t9rh_f64_pairs(60)
            ok &= (simulate(c, (a, b)) % UInt64) == f_nm(a, b)
        end
        @test ok

        cm = reversible_compile(soft_fmul, UInt64, UInt64)
        @test gate_count(cm).total == 149_198
        ok = true
        for (a, b) in _t9rh_f64_pairs(20; seed=0x1)
            ok &= (simulate(cm, (a, b)) % UInt64) == soft_fmul(a, b)
        end
        @test ok

        cf = reversible_compile(soft_fma, UInt64, UInt64, UInt64)
        @test gate_count(cf).total == 247_398       # = BENCHMARKS / regression_baselines
        rng = Random.MersenneTwister(0xfa)
        ok = true
        for a in _T9RH_F64_EDGES[1:6], b in _T9RH_F64_EDGES[9:14], e in _T9RH_F64_EDGES[[1, 3, 11, 12]]
            ok &= (simulate(cf, (a, b, e)) % UInt64) == soft_fma(a, b, e)
        end
        for _ in 1:20
            a, b, e = rand(rng, UInt64), rand(rng, UInt64), rand(rng, UInt64)
            ok &= (simulate(cf, (a, b, e)) % UInt64) == soft_fma(a, b, e)
        end
        @test ok

        cc = reversible_compile(soft_fcmp_olt, UInt64, UInt64)
        @test gate_count(cc).total == 6_248
        ok = true
        for (a, b) in _t9rh_f64_pairs(100; seed=0x2)
            ok &= (simulate(cc, (a, b)) % UInt64) == soft_fcmp_olt(a, b)
        end
        @test ok
    end

    @testset "(2) pinned constants + one routing for every optimize=true entry" begin
        @test Bennett._PINNED_CPU_X86_64 == "x86-64-v3"      # MAINTAINER DECISION
        @test Bennett._PINNED_CPU_OTHER == "generic"
        @test Bennett._PINNED_OPT_LEVEL == 2
        @test Bennett._PINNED_FEATURES == ""
        @test Bennett._pinned_target_cpu("x86_64-unknown-linux-gnu") == "x86-64-v3"
        @test Bennett._pinned_target_cpu("aarch64-unknown-linux-gnu") == "generic"
        @test Bennett._pinned_target_cpu("aarch64-apple-darwin") == "generic"

        T = Tuple{UInt64, UInt64}
        pinned = _t9rh_norm_ir(Bennett._julia_ir_string(soft_fmul, T; optimize=true))
        # extract_parsed_ir_by_sig(optimize=true)'s source is the same pinned IR.
        @test _t9rh_norm_ir(Bennett._code_llvm_by_sig(
                  Base.signature_type(soft_fmul, T); optimize=true)) == pinned
        # extract_ir (debug printer) shows what is compiled: the entry function
        # of the pinned module.
        fn_only = _t9rh_norm_ir(extract_ir(soft_fmul, T))
        @test !isempty(fn_only) && startswith(fn_only[1], "define ")
        @test issubset(fn_only, pinned)
        # optimize=false stays exactly code_llvm(optimize=false).
        @test _t9rh_norm_ir(extract_ir(soft_fmul, T; optimize=false)) ==
              _t9rh_norm_ir(sprint(io -> code_llvm(io, soft_fmul, T; debuginfo=:none,
                                                   optimize=false)))
        @test _t9rh_norm_ir(Bennett._julia_ir_string(soft_fmul, T; optimize=false)) ==
              _t9rh_norm_ir(sprint(io -> code_llvm(io, soft_fmul, T; debuginfo=:none,
                                                   optimize=false, dump_module=true)))
        # the pinned path has no raw / source-debuginfo variant: fail loud.
        @test_throws ArgumentError Bennett._code_llvm_by_sig(
            Base.signature_type(soft_fmul, T); optimize=true, raw=true)
        @test_throws ArgumentError Bennett._code_llvm_by_sig(
            Base.signature_type(soft_fmul, T); optimize=true, debuginfo=:source)
        @test_throws ArgumentError Bennett._code_llvm_by_sig(
            Base.signature_type(soft_fmul, T); optimize=false, cpu="x86-64")
    end

    @testset "(3) real AVX-512 SLP IR (test hook) compiles bit-exactly" begin
        sig = Base.signature_type(soft_fmul, Tuple{UInt64, UInt64})
        ir = Bennett._code_llvm_by_sig(sig; optimize=true, cpu="skylake-avx512")
        # The SLP horizontal-add idiom with a poison mask lane is present ...
        @test occursin(r"shufflevector <\d+ x i64> .*<i32 1, i32 poison>", ir)
        # ... and the scalariser propagates it soundly (commit 1).
        c = reversible_compile(Bennett._parsed_ir_from_ir_string(ir))
        @test verify_reversibility(c; n_tests=3)
        ok = true
        for (a, b) in _t9rh_f64_pairs(200; seed=0x3)
            ok &= (simulate(c, (a, b)) % UInt64) == soft_fmul(a, b)
        end
        @test ok
    end

    if Sys.ARCH === :x86_64
        @testset "(4) host independence: -C x86-64 -O1 and -C znver3 subprocesses" begin
            # Fixtures chosen because their host `code_llvm(optimize=true)`
            # differs across CPUs (measured 2026-09-24): ls_demo_16 is
            # SLP-vectorised on x86-64-v2+ but not on x86-64; soft_fcmp_olt is
            # vectorised on AVX-512; soft_fsqrt's loop is unrolled differently
            # on x86-64 / Intel AVX2 / Zen3.
            in_proc = (gate_count(reversible_compile(ls_demo_16, Int8, Int8)).total,
                       gate_count(reversible_compile(soft_fcmp_olt, UInt64, UInt64)).total,
                       gate_count(reversible_compile(soft_fsqrt, UInt64;
                                                     max_loop_iterations=4)).total)
            # Pinned under x86-64-v3: ls_demo_16 stays SLP-vectorised (cc0.7
            # coverage).
            @test in_proc == (3_944, 6_248, 70_487)

            script = """
            using Bennett
            include($(repr(joinpath(@__DIR__, "..", "benchmark", "cc07_repro_n16.jl"))))
            println("T9RH_COUNTS ",
                    gate_count(reversible_compile(ls_demo_16, Int8, Int8)).total, " ",
                    gate_count(reversible_compile(soft_fcmp_olt, UInt64, UInt64)).total, " ",
                    gate_count(reversible_compile(soft_fsqrt, UInt64;
                                                  max_loop_iterations=4)).total)
            """
            flagsets = (["-C", "x86-64", "-O1"], ["-C", "znver3"])
            tasks = [Threads.@spawn read(_t9rh_subjulia(fl, script), String) for fl in flagsets]
            for (fl, t) in zip(flagsets, tasks)
                out = fetch(t)
                m = match(r"T9RH_COUNTS (\d+) (\d+) (\d+)", out)
                @test m !== nothing
                m === nothing && (@info "subprocess output" fl out; continue)
                sub = Tuple(parse.(Int, m.captures))
                sub == in_proc || @info "host-dependent gate counts" fl sub in_proc
                @test sub == in_proc
            end
        end

        @testset "(5) fidelity canary vs `julia -C x86-64-v3` code_llvm(optimize=true)" begin
            # SoftFloatLib is self-contained: the subprocess includes it
            # directly, so it needs no Bennett precompile.
            sfsrc = joinpath(pkgdir(Bennett), "src", "softfloat", "softfloat.jl")
            script = """
            include($(repr(sfsrc)))
            using InteractiveUtils
            t9rh_k(x::Int64) = (a = zeros(Int64, 4); for i in 1:4; a[i] = x * i; end; a[2] + a[4])
            code_llvm(stdout, SoftFloatLib.soft_fmul, Tuple{UInt64,UInt64}; optimize=true, dump_module=true, debuginfo=:none)
            print("\\n=====T9RH_SPLIT=====\\n")
            code_llvm(stdout, t9rh_k, Tuple{Int64}; optimize=true, dump_module=true, debuginfo=:none)
            """
            cmd = `$(Base.julia_cmd()) -C $(Bennett._PINNED_CPU_X86_64) -O2 --startup-file=no -e $script`
            sub_fmul, sub_k = split(read(cmd, String), "=====T9RH_SPLIT=====")
            in_fmul = Bennett._julia_ir_string(soft_fmul, Tuple{UInt64, UInt64}; optimize=true)
            in_k = Bennett._julia_ir_string(t9rh_k, Tuple{Int64}; optimize=true)
            @test _t9rh_norm_ir(sub_fmul) == _t9rh_norm_ir(in_fmul)
            @test _t9rh_norm_ir(sub_k) == _t9rh_norm_ir(in_k)
        end
    else
        @info "Bennett-t9rh: host-independence / fidelity subprocess tests are " *
              "x86_64-only (pinned CPU elsewhere is \"generic\", untested); " *
              "skipped on $(Sys.ARCH)."
    end
end
