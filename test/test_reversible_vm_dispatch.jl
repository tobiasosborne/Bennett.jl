using Test
using Bennett

# Bennett-33zr / BennettVM ADR 0003: the `target=:reversible_vm` dispatch arm.
#
# Bennett.jl MUST NOT depend on BennettVM (BennettVM depends on Bennett — a
# reverse hard-dep would be a forbidden cycle), so these tests CANNOT
# `using BennettVM`. Instead they drive the registration hook directly: assign
# an in-test stub into `Bennett._REVERSIBLE_VM_BACKEND[]`, exercise the
# dispatch, and restore the Ref in a `finally`. The stub returns a sentinel
# tuple `(:routed_to_vm, parsed)` whose type is NOT a `ReversibleCircuit`, so a
# circuit-path leak (the Rule-1 fail-silent the tabulate guards prevent) is
# caught by an `isa` assertion. The real end-to-end `lower_vm` integration lives
# in BennettVM's own suite (it owns the round-trip oracle).
#
# This pins:
#   1. Hook inert (Ref===nothing) → `target=:reversible_vm` errors clearly,
#      on BOTH the Julia-function and the ParsedIR overloads.
#   2. Hook set → both overloads route to it and return its value (a VMProgram
#      in production; the sentinel here), NOT a ReversibleCircuit.
#   3. The two tabulate short-circuits do NOT silently capture a VM compile:
#      explicit strategy=:tabulate AND the :auto cost-model pick (small width +
#      mul) both fall through to the hook when target=:reversible_vm. The
#      complementary circuit-target compiles still produce a ReversibleCircuit.
#   4. The circuit path (:gate_count / :depth) is byte-unchanged when the hook
#      is absent; a genuinely-unknown target still raises ArgumentError.
@testset "Bennett-33zr / ADR 0003: target=:reversible_vm dispatch" begin

    @testset "(1) hook inert → errors clearly, both overloads" begin
        @test Bennett._REVERSIBLE_VM_BACKEND[] === nothing   # clean baseline
        # Julia-function overload (x+1 is :add → no tabulate short-circuit;
        # extracts, delegates to the ParsedIR overload, intercept fires).
        e = try
            reversible_compile(x -> x + Int8(1), Int8; target=:reversible_vm)
            nothing
        catch err; err end
        @test e isa ErrorException
        @test occursin("using BennettVM", e.msg)
        # Direct ParsedIR overload (the .ll/.bc route) errors too.
        p = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
        @test_throws ErrorException reversible_compile(p; target=:reversible_vm)
    end

    @testset "(2) hook set → routes to it, returns its value (not a circuit)" begin
        old = Bennett._REVERSIBLE_VM_BACKEND[]
        try
            Bennett._REVERSIBLE_VM_BACKEND[] = parsed -> (:routed_to_vm, parsed)
            p = extract_parsed_ir(x -> x + Int8(1), Tuple{Int8})
            out = reversible_compile(p; target=:reversible_vm)          # ParsedIR route
            @test out isa Tuple && out[1] === :routed_to_vm
            @test out[2] === p                                          # exact parsed forwarded
            @test !(out isa ReversibleCircuit)
            tag, routed = reversible_compile(x -> x + Int8(1), Int8;    # Julia-fn route
                                             target=:reversible_vm)
            @test tag === :routed_to_vm
            @test routed isa Bennett.ParsedIR
        finally
            Bennett._REVERSIBLE_VM_BACKEND[] = old
        end
    end

    @testset "(3) tabulate short-circuits do NOT swallow a VM compile" begin
        old = Bennett._REVERSIBLE_VM_BACKEND[]
        try
            Bennett._REVERSIBLE_VM_BACKEND[] = parsed -> (:routed_to_vm, parsed)
            # (a) explicit strategy=:tabulate + VM target → must route to hook.
            r1 = reversible_compile((a, b) -> a & b, Tuple{Bool,Bool};
                                    strategy=:tabulate, target=:reversible_vm)
            @test r1 isa Tuple && r1[1] === :routed_to_vm
            @test !(r1 isa ReversibleCircuit)
            # (b) :auto cost-model picks tabulate (small width + mul) + VM target
            #     → must route to hook, NOT QROM. bit_width=2, x*x has :mul.
            r2 = reversible_compile(x -> x * x, Tuple{Int8};
                                    bit_width=2, target=:reversible_vm)
            @test r2 isa Tuple && r2[1] === :routed_to_vm
            @test !(r2 isa ReversibleCircuit)
        finally
            Bennett._REVERSIBLE_VM_BACKEND[] = old
        end
        # Complementary: WITHOUT the VM target, the same compiles ARE circuits
        # (proves the guards didn't disturb the circuit/QROM path). Hook inert.
        @test Bennett._REVERSIBLE_VM_BACKEND[] === nothing
        c1 = reversible_compile((a, b) -> a & b, Tuple{Bool,Bool}; strategy=:tabulate)
        @test c1 isa ReversibleCircuit && verify_reversibility(c1)
        c2 = reversible_compile(x -> x * x, Tuple{Int8}; bit_width=2)
        @test c2 isa ReversibleCircuit && verify_reversibility(c2)
    end

    @testset "(4) circuit path byte-unchanged; unknown target still rejected" begin
        @test Bennett._REVERSIBLE_VM_BACKEND[] === nothing
        c_gc = reversible_compile(x -> x + Int8(1), Int8)                 # :gate_count default
        @test c_gc isa ReversibleCircuit && verify_reversibility(c_gc)
        c_dep = reversible_compile((x, y) -> x * y, Int32, Int32; target=:depth,
                                   fold_constants=false)
        @test c_dep isa ReversibleCircuit && verify_reversibility(c_dep)
        # :reversible_vm is intercepted earlier, but a genuine typo still hits
        # lower()'s whitelist (driver.jl:34) and raises (defense in depth).
        @test_throws ArgumentError reversible_compile(x -> x + Int8(1), Int8;
                                                      target=:nonsense)
    end
end
