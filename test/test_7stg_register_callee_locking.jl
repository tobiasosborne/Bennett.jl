using Test
using Bennett: register_callee!, reversible_compile

# Bennett-7stg / U26 — `register_callee!` / `_lookup_callee` mutated /
# read a module-global `Dict{String,Function}` without locking. Under
# a multi-threaded compile (parallel Pkg.test workers, batch compile,
# etc.) a concurrent register during another thread's lookup could
# race on Dict internals. Fix: wrap mutations and lookups in a
# `ReentrantLock`. This test spawns N threads that alternately register
# and compile, then asserts no exceptions escaped.

# Simple pure functions the extractor can compile.
hash_a(x::Int8) = x ⊻ Int8(0x55)
hash_b(x::Int8) = x + Int8(3)
hash_c(x::Int8) = (x >> 1) ⊻ x
hash_d(x::Int8) = x * Int8(3)

@testset "Bennett-7stg register_callee! is thread-safe" begin
    # T1 — repeated single-thread registers are idempotent.
    register_callee!(hash_a)
    register_callee!(hash_a)
    register_callee!(hash_a)
    @test reversible_compile(hash_a, Int8) !== nothing

    # T2 — concurrent register + compile across N threads. Use
    # @spawn for structured concurrency; join all tasks and ensure no
    # exception escaped.
    fns = (hash_a, hash_b, hash_c, hash_d)
    errs = Channel{Exception}(Inf)
    tasks = Task[]
    for _ in 1:8
        push!(tasks, Threads.@spawn begin
            try
                for f in fns
                    register_callee!(f)
                end
                for f in fns
                    reversible_compile(f, Int8)
                end
            catch e
                put!(errs, e)
            end
        end)
    end
    for t in tasks
        wait(t)
    end
    close(errs)
    caught = collect(errs)
    if !isempty(caught)
        @error "Concurrent register/compile threw" n=length(caught) first=sprint(showerror, caught[1])
    end
    @test isempty(caught)
end
