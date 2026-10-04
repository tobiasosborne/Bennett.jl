using Test, Bennett

# Bennett-uiqq: the reserved extent of every alloca equals count × (cells per
# allocated type) under LLVM semantics — `alloca [K x iM], i32 N` reserves K·N
# cells, never K. Bennett-1zow: an alloca whose allocated type is not modelled
# is refused loudly unless provably dead (then its SSA name is un-registered);
# no SSA name is left registered without a definition.

const _UZ_DIR = mktempdir()

function _uz_parse(ir::String; ptr_cells::Bool=false)
    path = joinpath(_UZ_DIR, "f_$(hash(ir)).ll")
    write(path, ir)
    return Bennett.extract_parsed_ir_from_ll(path; entry_function="f",
                                             ptr_cells=ptr_cells)
end

_uz_msg(f) = try
    f(); ""
catch e
    e isa InterruptException && rethrow()
    sprint(showerror, e)
end

_uz_allocas(p) = [i for b in p.blocks for i in b.instructions if i isa Bennett.IRAlloca]

# (allocated type, cell width, cells per object)
const _UZ_TYPES = [("i8", 8, 1), ("i64", 64, 1), ("[1 x i64]", 64, 1),
                   ("[4 x i8]", 8, 4)]
# count spelling => static multiplier (nothing = runtime)
const _UZ_COUNTS = [("", 1), (", i32 1", 1), (", i32 4", 4), (", i64 %n", nothing)]

function _uz_ir(ty, w, cnt, idx)
    conv_in  = w == 8 ? "%v = add i8 %x, 0" : "%v = zext i8 %x to i$w"
    conv_out = w == 8 ? "%r = add i8 %l, 0" : "%r = trunc i$w %l to i8"
    """
    define i8 @f(i8 %x) {
    entry:
      %n = zext i8 %x to i64
      %p = alloca $ty$cnt
      $conv_in
      %g = getelementptr i$w, ptr %p, i64 $idx
      store i$w %v, ptr %g
      %l = load i$w, ptr %g
      $conv_out
      ret i8 %r
    }
    """
end

@testset "Bennett-uiqq: alloca reserves count × allocated-type cells" begin
    for (ty, w, k) in _UZ_TYPES, (cnt, c) in _UZ_COUNTS
        is_arr = startswith(ty, "[")
        if c === nothing
            # Runtime count. Expressible as `%n` cells only when one cell per
            # object (scalar or [1 x iM]); [K x iM] with K > 1 is refused at
            # extraction instead of silently reserving K cells.
            ir = _uz_ir(ty, w, cnt, 0)
            if k == 1
                a = only(_uz_allocas(_uz_parse(ir)))
                @test a.elem_width == w
                @test a.n_elems == Bennett.ssa(:n)
                # the circuit path cannot size a runtime reservation: loud
                @test !isempty(_uz_msg(() -> reversible_compile(_uz_parse(ir))))
            else
                msg = _uz_msg(() -> _uz_parse(ir))
                @test occursin("Bennett-uiqq", msg)
                @test occursin("count", msg)
                @test occursin("`f`", msg)
            end
            continue
        end
        ext = k * c
        for idx in (0, ext - 1)
            ir = _uz_ir(ty, w, cnt, idx)
            p = _uz_parse(ir)
            a = only(_uz_allocas(p))
            @test a.elem_width == w
            @test a.n_elems == Bennett.iconst(ext)
            circ = reversible_compile(p)
            ok = true
            for x in typemin(Int8):typemax(Int8)
                ok &= simulate(circ, x) == x
            end
            @test ok
            @test verify_reversibility(circ)
        end
        # one past the extent: refused at lowering (not a silent clobber)
        msg = _uz_msg(() -> reversible_compile(_uz_parse(_uz_ir(ty, w, cnt, ext))))
        @test occursin("out of range", msg)
    end

    @testset "the bead witness: [1 x i64], i32 4 reserves FOUR cells" begin
        p = _uz_parse(_uz_ir("[1 x i64]", 64, ", i32 4", 3))
        @test only(_uz_allocas(p)).n_elems == Bennett.iconst(4)
    end

    @testset "negative / overflowing counts are refused, not wrapped" begin
        msg = _uz_msg(() -> _uz_parse(_uz_ir("[2 x i8]", 8, ", i32 -1", 0)))
        @test occursin("Bennett-uiqq", msg)
        msg = _uz_msg(() -> _uz_parse(_uz_ir("[4611686018427387904 x i8]", 8,
                                             ", i64 4", 0)))
        @test occursin("Bennett-uiqq", msg)
        @test occursin("overflow", msg)
    end
end

# unmodelled allocated type × use kind. Only a USE-LESS alloca is skipped; a
# dead GEP chain is still a use (its GEP would reference the dropped name).
const _UZ_UNMODELLED = [("{ i32, i64 }", false), ("double", false),
                        ("[2 x ptr]", false), ("ptr", false),
                        ("{ ptr, ptr }", true), ("[2 x [2 x i8]]", true)]

function _uz_use_ir(ty, use)
    body = if use == :dead
        ""
    elseif use == :dead_gep
        "%g = getelementptr i8, ptr %p, i64 1"
    elseif use == :load
        "%l = load i8, ptr %p"
    elseif use == :store
        "store i8 %x, ptr %p"
    elseif use == :call
        "call void @use(ptr %p)"
    end
    """
    declare void @use(ptr)
    define i8 @f(i8 %x) {
    entry:
      %p = alloca $ty
      $body
      ret i8 %x
    }
    """
end

@testset "Bennett-1zow: unmodelled alloca is refused unless provably dead" begin
    for (ty, pc) in _UZ_UNMODELLED
        for use in (:dead,)
            p = _uz_parse(_uz_use_ir(ty, use); ptr_cells=pc)
            @test isempty(_uz_allocas(p))
            # the dead alloca's name is not left behind for any consumer
            @test !occursin(":p", sprint(show, p.blocks))
            circ = reversible_compile(p)
            ok = true
            for x in typemin(Int8):typemax(Int8)
                ok &= simulate(circ, x) == x
            end
            @test ok
            @test verify_reversibility(circ)
        end
        for use in (:dead_gep, :load, :store, :call)
            msg = _uz_msg(() -> _uz_parse(_uz_use_ir(ty, use); ptr_cells=pc))
            @test occursin("Bennett-1zow", msg)
            @test occursin("`%p`", msg)
            @test occursin("`f`", msg)
            @test occursin(ty, msg)
        end
    end
    # positive control: a modelled pointer slot under ptr_cells still emits
    p = _uz_parse(_uz_use_ir("ptr", :store); ptr_cells=true)
    @test length(_uz_allocas(p)) == 1
end
