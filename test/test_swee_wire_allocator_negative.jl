using Test
using Bennett: WireAllocator, allocate!, free!, wire_count

# Bennett-swee / U24 — `WireAllocator.allocate!(wa, n)` silently returned
# an empty Vector{Int} for n ≤ 0 (the `for _ in 1:n` loop is simply
# zero-trip when n is 0 or negative). An empty wire vector then
# propagated downstream into the Bennett construction, where it blew up
# later as a BoundsError far from the root cause. `free!` had no
# double-free check either — re-freeing an already-freed wire silently
# duplicated it in the free list.
#
# Fix: `allocate!` rejects n < 0 with an ArgumentError naming the call
# site. `allocate!(wa, 0)` stays a no-op (legitimate request for zero
# wires). `free!` gains a best-effort double-free detector that scans
# the existing free list for each wire being freed.

@testset "Bennett-swee WireAllocator negative / double-free guards" begin
    # T1 — n < 0 must raise.
    wa = WireAllocator()
    @test_throws ArgumentError allocate!(wa, -1)
    @test_throws ArgumentError allocate!(wa, -100)

    # T2 — n == 0 is a legitimate no-op.
    @test allocate!(wa, 0) == Int[]
    @test wire_count(wa) == 0   # no wires allocated

    # T3 — positive n works as before.
    ws = allocate!(wa, 3)
    @test length(ws) == 3
    @test ws == [1, 2, 3]
    @test wire_count(wa) == 3

    # T4 — free! followed by double-free must raise.
    free!(wa, [2])
    @test_throws ArgumentError free!(wa, [2])   # already in free list
    @test_throws ArgumentError free!(wa, [2, 3])  # 2 is a double-free

    # T5 — free! of a wire that was never allocated is suspect but
    # currently allowed (harness tests free arbitrary ints); not
    # strengthened in U24 to stay within the catalogue's scope.
    wa2 = WireAllocator()
    allocate!(wa2, 3)  # wires 1, 2, 3 allocated
    @test_nowarn free!(wa2, [3])   # legitimate free
end
