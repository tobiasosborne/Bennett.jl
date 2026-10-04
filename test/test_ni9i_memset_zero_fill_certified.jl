using Test, Bennett

# Bennett-ni9i: a zero-fill `llvm.memset` used to be deleted from ParsedIR
# unconditionally (`_handle_memset_arm` predicate 8: `c == 0 → IRInst[]`),
# even when the destination held live data. `store x; memset(0); load`
# then returned x where native code returns 0 (Astra review F2).
#
# Invariant: a c == 0, N > 0 memset is dropped ONLY when its destination is
# certified already-zero — an alloca that is fresh per `_alloca_is_fresh`
# (same block, no IR-visible write between the alloca and the memset; the
# wire model zero-initialises allocas). Every other destination is refused
# loud. N == 0 stays a LangRef no-op for every destination. Volatility does
# not change the c == 0 verdict (Bennett-8su4 GC-frame zero-init still drops).

const _NI9I_DECLS = """
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
"""

_ni9i_err(f) = try
    f(); nothing
catch e
    e isa InterruptException && rethrow()
    sprint(showerror, e)
end

# Body for a destination kind. Every program returns `load(byte 0) + x`, so
# a dropped-but-live memset shows up as `2x` instead of the native `x`.
# The alloca is 4 bytes; `prior` stores x into byte 0 before the memset.
function _ni9i_ir(kind::Symbol, prior::Bool, N::Int, vol::Bool)
    v = vol ? "true" : "false"
    st(p) = prior ? "  store i8 %x, ptr $p\n" : ""
    ms(p) = "  call void @llvm.memset.p0.i64(ptr $p, i8 0, i64 $N, i1 $v)\n"
    tail(p) = "  %y = load i8, ptr $p\n  %r = add i8 %y, %x\n  ret i8 %r\n}\n"
    if kind === :alloca          # flat i8 array alloca, memset on the root
        body = "define i8 @julia_f(i8 %x) {\nentry:\n  %p = alloca i8, i32 4\n" *
               st("%p") * ms("%p") * tail("%p")
    elseif kind === :alloca_gep  # memset through a const-offset GEP of the alloca
        body = "define i8 @julia_f(i8 %x) {\nentry:\n  %p = alloca i8, i32 4\n" *
               "  %q = getelementptr i8, ptr %p, i64 0\n" *
               st("%p") * ms("%q") * tail("%p")
    elseif kind === :alloca_crossblock  # alloca in entry, memset in a later block
        body = "define i8 @julia_f(i8 %x) {\nentry:\n  %p = alloca i8, i32 4\n" *
               st("%p") * "  br label %b1\nb1:\n" * ms("%p") * tail("%p")
    elseif kind === :argument    # caller-owned memory: never certified zero
        body = "define i8 @julia_f(i8 %x, ptr %a) {\nentry:\n" *
               st("%a") * ms("%a") * tail("%a")
    elseif kind === :global
        body = "define i8 @julia_f(i8 %x) {\nentry:\n" *
               st("@g") * ms("@g") * tail("@g")
    else
        error("unknown kind $kind")
    end
    # The global is only declared for the :global kind (a module global in
    # the `Base.llvmcall` native oracle crashes the JIT).
    gdecl = kind === :global ? "@g = global [4 x i8] zeroinitializer\n" : ""
    return _NI9I_DECLS * gdecl * body
end

@testset "Bennett-ni9i: zero-fill memset dropped only on certified-zero dst" begin

    @testset "F2 witness: store 42; memset(0); load is refused, not 42" begin
        ir = """
        declare void @llvm.memset.p0.i64(ptr,i8,i64,i1)
        define i8 @julia_zero(i8 %x) {
        entry:
          %p = alloca i8
          store i8 %x, ptr %p
          call void @llvm.memset.p0.i64(ptr %p,i8 0,i64 1,i1 false)
          %r = load i8, ptr %p
          ret i8 %r
        }"""
        msg = _ni9i_err(() -> Bennett._parsed_ir_from_ir_string(ir))
        @test msg !== nothing
        @test occursin("not certified already-zero", msg)
        @test occursin("julia_zero", msg)          # names the function
        @test occursin("llvm.memset", msg)         # names the memset
        @test occursin("Bennett-ni9i", msg)
    end

    @testset "fresh-alloca zero memset still drops; program correct" begin
        ir = _ni9i_ir(:alloca, false, 4, false)
        p = Bennett._parsed_ir_from_ir_string(ir)
        c = reversible_compile(p)
        @test verify_reversibility(c)
        # alloca is fresh (zero) and the memset zeroes byte 0 → native r == x
        @test all(Int(simulate(c, x)) == Int(x) for x in typemin(Int8):typemax(Int8))
    end

    # Grid: destination kind × prior store × N ∈ {0, partial, full} × volatile.
    kinds = (:alloca, :alloca_gep, :alloca_crossblock, :argument, :global)
    for kind in kinds, prior in (false, true), N in (0, 2, 4), vol in (false, true)
        # A prior store through an argument / global pointer is refused by
        # its own (earlier) store arm, so those kinds only run prior=false.
        prior && kind in (:argument, :global) && continue
        ir = _ni9i_ir(kind, prior, N, vol)
        label = "kind=$kind prior=$prior N=$N vol=$vol"
        certified = kind in (:alloca, :alloca_gep) && !prior
        if N == 0 || certified
            if kind in (:alloca, :alloca_gep, :alloca_crossblock)
                p = Bennett._parsed_ir_from_ir_string(ir)
                c = reversible_compile(p)
                @test verify_reversibility(c)
                # N==0 && !prior reads an uninitialised byte (undef
                # natively) — no oracle for that cell.
                if N > 0 || prior
                    native = eval(:(x -> Base.llvmcall(($ir, "julia_f"), Int8, Tuple{Int8}, x)))
                    ok = all((simulate(c, x) % Int8) == Base.invokelatest(native, x)
                             for x in typemin(Int8):typemax(Int8))
                    ok || @info "ni9i grid mismatch vs native" label
                    @test ok
                end
            else
                # argument / global with N == 0: the memset arm is a no-op;
                # whatever else the extractor says about the program, it
                # must not be a memset certification refusal.
                msg = _ni9i_err(() -> Bennett._parsed_ir_from_ir_string(ir))
                @test msg === nothing || !occursin("not certified already-zero", msg)
            end
        else
            msg = _ni9i_err(() -> Bennett._parsed_ir_from_ir_string(ir))
            ok = msg !== nothing && occursin("not certified already-zero", msg)
            ok || @info "ni9i grid: expected refusal" label msg
            @test ok
        end
    end
end
