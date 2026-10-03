using Test
using Bennett
using Bennett: register_callee!, register_callee_name!, extract_parsed_ir

# Bennett-7q9z — a callee-registry change must invalidate both compile caches
# (`_parsed_ir_cache`, `_compile_cache`). Registration does not move Julia's
# world counter, so the Bennett-4ddk world gate never saw it: a ParsedIR (or
# circuit) built BEFORE `register_callee!` was served by identity AFTER it, with
# the callee lowered the old way. Witness: `f7q9z` calls `throw_7q9z`, whose
# `j_throw_` LLVM symbol the unregistered path drops as a benign throw helper
# (leaving the call's result undefined, so the compile fails in lowering). The
# failing compile still CACHED that ParsedIR, so after registering `throw_7q9z`
# the next compile reused it and failed again, until a manual cache clear.
# Fix: a registry generation counter, bumped on every registry mutation, is
# folded into the caches' world stamp.
#
# Gotcha (Julia 1.12, see test_4ddk): a closure literal reached at top level,
# including a comprehension or `do` block inside a `@testset`, moves the world
# and empties both caches — which would mask the bug. The witness therefore
# runs inside top-level functions, and asserts the world did not move.

@noinline throw_7q9z(x::Int8) = x * x + Int8(3)
f7q9z(x::Int8) = throw_7q9z(x) + Int8(1)
q7_plain(x::Int8) = x + Int8(1)
q7_dummy(x::Int8) = x - Int8(1)
@noinline q7_leaf(x::Int8) = x + Int8(2)
q7_setroot(x::Int8) = q7_leaf(x) * Int8(3)
struct Fn7q9z
    n::Int64
end
(a::Fn7q9z)(x::Int64) = x + a.n

function _q7_try_compile(f, T)
    try
        return reversible_compile(f, T)
    catch e
        e isa InterruptException && rethrow()
        return e
    end
end

function _q7_exhaustive(c, f)
    @test c isa Bennett.ReversibleCircuit
    c isa Bennett.ReversibleCircuit || return
    bad = Int8[]
    for x in typemin(Int8):typemax(Int8)
        simulate(c, x) == f(x) || push!(bad, x)
    end
    isempty(bad) || @info "Bennett-7q9z mismatches" f first(bad, 5)
    @test isempty(bad)
    @test verify_reversibility(c)
end

function _q7_unregister!(names...)
    lock(Bennett._known_callees_lock) do
        for n in names
            delete!(Bennett._known_callees, n)
            delete!(Bennett._known_callee_names, n)
        end
    end
    Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
end

function _q7_witness()
    Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
    w0 = Base.get_world_counter()
    try
        before = _q7_try_compile(f7q9z, Int8)
        @test before isa Exception          # unregistered: no circuit
        register_callee!(throw_7q9z)
        after = _q7_try_compile(f7q9z, Int8)
        @test Base.get_world_counter() == w0   # the 4ddk gate cannot have fired
        _q7_exhaustive(after, f7q9z)
    finally
        _q7_unregister!("throw_7q9z")
    end
end

# Cache-level: a hit before the registration, a fresh build after it.
function _q7_cache_identity(register!)
    Bennett._clear_parsed_ir_cache!(); Bennett._clear_compile_cache!()
    w0 = Base.get_world_counter()
    p1 = Bennett._extract_parsed_ir_cached(q7_plain, Tuple{Int8})
    @test Bennett._extract_parsed_ir_cached(q7_plain, Tuple{Int8}) === p1   # hit
    pir = extract_parsed_ir(q7_plain, Tuple{Int8})
    c1 = reversible_compile(pir)
    @test reversible_compile(pir) === c1
    register!()
    @test Base.get_world_counter() == w0
    parsed_rebuilt = Bennett._extract_parsed_ir_cached(q7_plain, Tuple{Int8}) !== p1
    @test parsed_rebuilt
    c2 = reversible_compile(pir)
    circuit_rebuilt = c2 !== c1
    @test circuit_rebuilt
    _q7_exhaustive(c2, q7_plain)
end

# An idempotent re-registration changes nothing, so it keeps the caches.
function _q7_idempotent_keeps_cache()
    register_callee!(q7_dummy)
    try
        Bennett._clear_parsed_ir_cache!()
        p1 = Bennett._extract_parsed_ir_cached(q7_plain, Tuple{Int8})
        register_callee!(q7_dummy)
        @test Bennett._extract_parsed_ir_cached(q7_plain, Tuple{Int8}) === p1
    finally
        _q7_unregister!("q7_dummy")
    end
end

@testset "Bennett-7q9z: callee registration invalidates the compile caches" begin
    @testset "compile before register_callee! is not served after it" begin
        _q7_witness()
    end
    @testset "register_callee! empties both caches" begin
        try
            _q7_cache_identity(() -> register_callee!(q7_dummy))
        finally
            _q7_unregister!("q7_dummy")
        end
    end
    @testset "register_callee_name! empties both caches" begin
        try
            _q7_cache_identity(() -> register_callee_name!("Fn7q9z", :Fn7q9z, Fn7q9z))
        finally
            _q7_unregister!("Fn7q9z")
        end
    end
    @testset "the closed-world set extractor (register + scoped restore) empties both caches" begin
        _q7_cache_identity(() -> Bennett.extract_parsed_ir_set_from_julia(q7_setroot, Tuple{Int8}))
        @test !haskey(Bennett._known_callees, "q7_leaf")   # restored: nothing leaked
    end
    @testset "idempotent re-registration keeps the caches" begin
        _q7_idempotent_keeps_cache()
    end
end
