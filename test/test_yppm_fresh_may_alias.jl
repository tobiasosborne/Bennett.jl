using Test, Bennett

# Bennett-yppm: `_alloca_is_fresh(a, at)` certified an alloca as unwritten
# when an earlier bulk write (llvm.memset / llvm.memmove / llvm.memcpy) went
# through a pointer the root walk cannot resolve — a `select` of `%p`, a GEP
# of such a select, a pointer loaded back after `%p`'s address was stored.
# Since Bennett-ni9i the certificate lets a zero-fill memset be DROPPED, so
#
#     %q = select i1 %c, ptr %p, ptr %p
#     memset(%q, 42, %n)     ; variable length: IRCall(:memset) under ptr_cells
#     memset(%p, 0, 4)       ; dropped as "fresh"
#     %v = load i8, ptr %p   ; native 0, emitted memory semantics 42
#
# extracted to ParsedIR with the zero-fill deleted (Sol review 2A finding 3).
#
# Invariant: `_alloca_is_fresh(a, at)` holds only if no instruction between
# `a` and `at` may write memory derived from `a`. Every SSA value derived from
# `a` (GEP / select / phi / bitcast / addrspacecast / freeze of a derived
# operand) is tracked; a store / memory-intrinsic destination / unknown-call
# argument that is derived counts as a write, and any other use of a derived
# pointer that is not a pure read (storing it as a value, ptrtoint, ...) is an
# escape — not fresh. Writes through pointers NOT derived from `a` (another
# alloca, a select of two other allocas) leave it fresh.

const _YPPM_DECLS = """
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)
"""

_yppm_err(f) = try
    f(); nothing
catch e
    e isa InterruptException && rethrow()
    sprint(showerror, e)
end

# How the may-alias pointer %q is derived from %p.
const _YPPM_ALIAS = Dict(
    :select_pp   => "  %q = select i1 %c, ptr %p, ptr %p\n",
    :select_po   => "  %o = alloca i8, i32 4\n  %q = select i1 %c, ptr %p, ptr %o\n",
    :select_op   => "  %o = alloca i8, i32 4\n  %q = select i1 %c, ptr %o, ptr %p\n",
    :gep_select  => "  %s = select i1 %c, ptr %p, ptr %p\n  %q = getelementptr i8, ptr %s, i64 1\n",
    :escape_load => "  %slot = alloca ptr\n  store ptr %p, ptr %slot\n  %q = load ptr, ptr %slot\n",
)
# The write through %q before the zero-fill.
const _YPPM_PRIOR = Dict(
    :store      => "  store i8 42, ptr %q\n",
    :memset_c   => "  call void @llvm.memset.p0.i64(ptr %q, i8 42, i64 2, i1 false)\n",
    :memset_var => "  %n = zext i8 %x to i64\n  call void @llvm.memset.p0.i64(ptr %q, i8 42, i64 %n, i1 false)\n",
    :memcpy     => "  %src = alloca i8, i32 4\n  store i8 42, ptr %src\n  call void @llvm.memcpy.p0.p0.i64(ptr %q, ptr %src, i64 1, i1 false)\n",
    :memmove    => "  %src = alloca i8, i32 4\n  store i8 42, ptr %src\n  call void @llvm.memmove.p0.p0.i64(ptr %q, ptr %src, i64 1, i1 false)\n",
)

function _yppm_ir(pre::String)
    return _YPPM_DECLS *
        "define i8 @julia_f(i8 %x) {\nentry:\n  %p = alloca i8, i32 4\n" *
        "  %c = icmp sgt i8 %x, 0\n" * pre *
        "  call void @llvm.memset.p0.i64(ptr %p, i8 0, i64 4, i1 false)\n" *
        "  %v = load i8, ptr %p\n  ret i8 %v\n}\n"
end

# The zero-fill on %p must survive extraction: either the whole compile is
# refused, or ParsedIR still carries it. Today no extraction path emits a
# zero-fill on a non-fresh alloca, so "survives" == "refused".
_yppm_zero_fill_kept(msg) = msg !== nothing

@testset "Bennett-yppm: freshness rejects may-alias writes" begin

    @testset "Sol 2A witness: select alias + variable memset; zero-fill not dropped" begin
        ir = _yppm_ir(_YPPM_ALIAS[:select_pp] * _YPPM_PRIOR[:memset_var])
        for pc in (false, true)
            msg = _yppm_err(() -> Bennett._parsed_ir_from_ir_string(ir; ptr_cells=pc))
            @test msg !== nothing
        end
        # Under ptr_cells the 42-fill extracts (IRCall(:memset)); the refusal
        # must come from the zero-fill certificate, not from elsewhere.
        msg = something(_yppm_err(() -> Bennett._parsed_ir_from_ir_string(ir; ptr_cells=true)), "")
        @test occursin("not certified already-zero", msg)
        @test occursin("Bennett-ni9i", msg)
        @test occursin("may-alias", msg)
    end

    # Grid: alias derivation × prior write kind × ptr_cells. No combination
    # may extract with the zero-fill silently deleted.
    for a in sort!(collect(keys(_YPPM_ALIAS))), w in sort!(collect(keys(_YPPM_PRIOR))),
            pc in (false, true)
        ir = _yppm_ir(_YPPM_ALIAS[a] * _YPPM_PRIOR[w])
        msg = _yppm_err(() -> Bennett._parsed_ir_from_ir_string(ir; ptr_cells=pc))
        ok = _yppm_zero_fill_kept(msg)
        ok || @info "yppm grid: zero-fill silently dropped" a w pc
        @test ok
        # The combinations whose prior write extracts (the Symbol-callee
        # variable memset / memmove under ptr_cells) must be refused by the
        # zero-fill certificate itself.
        if pc && w in (:memset_var, :memmove)
            @test msg !== nothing && occursin("not certified already-zero", msg)
        end
    end

    @testset "controls that stay fresh" begin
        # (1) variable memset through a select of two OTHER allocas: %p is
        # untouched, so the zero-fill on %p is still a certified no-op.
        ir = _yppm_ir("  %o1 = alloca i8, i32 4\n  %o2 = alloca i8, i32 4\n" *
                      "  %q = select i1 %c, ptr %o1, ptr %o2\n" * _YPPM_PRIOR[:memset_var])
        @test _yppm_err(() -> Bennett._parsed_ir_from_ir_string(ir; ptr_cells=true)) === nothing

        # Gate-backend controls: each returns load(%p) + load(%o) where %o
        # holds 42 and %p is zero-filled → native 42 for every x.
        ctl = Dict(
            :store_other => "  %o = alloca i8, i32 4\n  store i8 42, ptr %o\n",
            :load_p      => "  %o = alloca i8, i32 4\n  %pre = load i8, ptr %p\n" *
                            "  %o42 = add i8 %pre, 42\n  store i8 42, ptr %o\n",
            :gep_p_read  => "  %o = alloca i8, i32 4\n  %g = getelementptr i8, ptr %p, i64 2\n" *
                            "  %pre = load i8, ptr %g\n  store i8 42, ptr %o\n",
            :memcpy_from_p => "  %o = alloca i8, i32 4\n" *
                            "  call void @llvm.memcpy.p0.p0.i64(ptr %o, ptr %p, i64 1, i1 false)\n" *
                            "  store i8 42, ptr %o\n",
        )
        for (k, pre) in sort!(collect(ctl); by=first)
            ir = _YPPM_DECLS *
                "define i8 @julia_f(i8 %x) {\nentry:\n  %p = alloca i8, i32 4\n" * pre *
                "  call void @llvm.memset.p0.i64(ptr %p, i8 0, i64 4, i1 false)\n" *
                "  %v = load i8, ptr %p\n  %w = load i8, ptr %o\n" *
                "  %r0 = add i8 %v, %w\n  %r = add i8 %r0, %x\n  ret i8 %r\n}\n"
            msg = _yppm_err(() -> Bennett._parsed_ir_from_ir_string(ir))
            msg === nothing || @info "yppm control refused" k msg
            @test msg === nothing
            msg === nothing || continue
            c = reversible_compile(Bennett._parsed_ir_from_ir_string(ir))
            @test verify_reversibility(c)
            native = @eval x -> Base.llvmcall(($ir, "julia_f"), Int8, Tuple{Int8}, x)
            @test all((simulate(c, x) % Int8) == Base.invokelatest(native, x)
                      for x in typemin(Int8):typemax(Int8))
        end
    end
end
