# Bennett-uhk3: checkpoint / pebbled-group replay permuted a group's result
# bits (Astra 2026-09-26 B-circuit-core F5).
#
# `_replay_forward!` (src/pebble/pebbled_groups.jl) rebuilt the replayed
# group's result vector by walking `wire_start:wire_end` and keeping wires
# found in `Set(group.result_wires)`. That returned the owned result wires in
# ALLOCATION order, not the logical bit order of `group.result_wires`.
# Downstream code (checkpoint copy, dependency wmap, output copy) zips the
# replayed vector with the ORIGINAL ordered `result_wires`, so a group whose
# result is `[3,2]` silently became `[2,3]`: wrong output bits, clean
# ancillae, `verify_reversibility` green. Duplicated result positions lost
# their multiplicity the same way.
#
# Post-fix contract: every strategy agrees with DefaultStrategy on every
# input for permuted, duplicated and non-contiguous `result_wires`, and every
# produced circuit passes `verify_reversibility`.

using Test
using Bennett
using Bennett: LoweringResult, GateGroup, ReversibleGate, NOTGate, CNOTGate,
               ToffoliGate, bennett, simulate, verify_reversibility,
               DefaultStrategy, EagerStrategy, ValueEagerStrategy,
               CheckpointStrategy, PebbledStrategy, PebbledGroupStrategy

const _UHK3_STRATEGIES = (EagerStrategy(), ValueEagerStrategy(),
                          CheckpointStrategy(), PebbledStrategy(),
                          PebbledGroupStrategy(), PebbledGroupStrategy(1))

# (name, lr-builder, input width, expected(x))
const _UHK3_FIXTURES = [
    # Report reproducer: one group, result [3,2] (descending). out = x << 1.
    ("permuted single group",
     () -> LoweringResult(ReversibleGate[CNOTGate(1, 2)], 3, [1], [3, 2], [1], [2],
                          [GateGroup(:a, 1, 1, [3, 2], Symbol[], 2, 3)], false),
     1, x -> 2x),

    # Two groups; a's permuted result [4,3] feeds b through the dependency
    # wmap. a = (x1, x0) logically; b copies wire 4 → 5 and wire 3 → 6.
    # out = bits(5,6) = (x1, x0) → bit-swap of x.
    ("permuted result feeding a dependency",
     () -> LoweringResult(
         ReversibleGate[CNOTGate(1, 3), CNOTGate(2, 4),
                        CNOTGate(4, 5), CNOTGate(3, 6)],
         6, [1, 2], [5, 6], [2], [2],
         [GateGroup(:a, 1, 2, [4, 3], Symbol[], 3, 4),
          GateGroup(:b, 3, 4, [5, 6], [:a], 5, 6)], false),
     2, x -> ((x >> 1) & 1) | ((x & 1) << 1)),

    # Duplicated positions: a's result is [3,2,3] (wire 3 = 1, wire 2 = x).
    # b reads it into [4,5,6] = (w3, w2, w3) = (1, x, 1). out = 5 + 2x.
    ("duplicated result positions",
     () -> LoweringResult(
         ReversibleGate[CNOTGate(1, 2), NOTGate(3),
                        CNOTGate(3, 4), CNOTGate(2, 5), CNOTGate(3, 6)],
         6, [1], [4, 5, 6], [1], [3],
         [GateGroup(:a, 1, 2, [3, 2, 3], Symbol[], 2, 3),
          GateGroup(:b, 3, 5, [4, 5, 6], [:a], 4, 6)], false),
     1, x -> 5 + 2x),

    # Non-contiguous, permuted result [6,4] inside range 3:6 with internal
    # scratch wires 3 and 5. w3 = x0&x1, w6 = w3, w5 = x0, w4 = ¬x0.
    # out = (x0&x1) + 2·¬x0.
    ("non-contiguous permuted result with internals",
     () -> LoweringResult(
         ReversibleGate[ToffoliGate(1, 2, 3), CNOTGate(3, 6), CNOTGate(1, 5),
                        CNOTGate(5, 4), NOTGate(4)],
         6, [1, 2], [6, 4], [2], [2],
         [GateGroup(:a, 1, 5, [6, 4], Symbol[], 3, 6)], false),
     2, x -> ((x & 1) & ((x >> 1) & 1)) + 2 * (1 - (x & 1))),

    # Non-contiguous permuted result consumed by a second group, and output
    # of both groups' bits: b = (a1, a0) re-permuted back.
    ("non-contiguous result feeding a dependency",
     () -> LoweringResult(
         ReversibleGate[ToffoliGate(1, 2, 3), CNOTGate(3, 6), CNOTGate(1, 5),
                        CNOTGate(5, 4), NOTGate(4),
                        CNOTGate(4, 7), CNOTGate(6, 8)],
         8, [1, 2], [7, 8], [2], [2],
         [GateGroup(:a, 1, 5, [6, 4], Symbol[], 3, 6),
          GateGroup(:b, 6, 7, [7, 8], [:a], 7, 8)], false),
     2, x -> (1 - (x & 1)) + 2 * ((x & 1) & ((x >> 1) & 1))),
]

@testset "Bennett-uhk3: group replay preserves result bit order" begin
    for (name, mk, w, expected) in _UHK3_FIXTURES
        @testset "$name" begin
            cdef = bennett(mk(); strategy=DefaultStrategy())
            @test verify_reversibility(cdef; n_tests=64)
            ref = Dict(x => simulate(cdef, x) for x in 0:(2^w - 1))
            for x in 0:(2^w - 1)
                @test ref[x] == expected(x)   # fixture sanity
            end
            for s in _UHK3_STRATEGIES
                c = bennett(mk(); strategy=s)
                for x in 0:(2^w - 1)
                    @test simulate(c, x) == ref[x]
                end
                @test verify_reversibility(c; n_tests=64)
            end
        end
    end
end
