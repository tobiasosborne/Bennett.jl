function gate_count(c::ReversibleCircuit)
    n  = count(g -> g isa NOTGate, c.gates)
    cn = count(g -> g isa CNOTGate, c.gates)
    tf = count(g -> g isa ToffoliGate, c.gates)
    return (total=length(c.gates), NOT=n, CNOT=cn, Toffoli=tf)
end

ancilla_count(c::ReversibleCircuit) = length(c.ancilla_wires)

gate_wires(g::NOTGate)     = (g.target,)
gate_wires(g::CNOTGate)    = (g.control, g.target)
gate_wires(g::ToffoliGate) = (g.control1, g.control2, g.target)

function depth(c::ReversibleCircuit)
    wd = zeros(Int, c.n_wires)
    md = 0
    for gate in c.gates
        ws = gate_wires(gate)
        d = maximum(wd[w] for w in ws) + 1
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    return md
end

function print_circuit(io::IO, c::ReversibleCircuit)
    gc = gate_count(c)
    println(io, "ReversibleCircuit:")
    println(io, "  Wires:    $(c.n_wires)")
    println(io, "  Input:    $(length(c.input_wires)) wires $(c.input_widths)")
    println(io, "  Output:   $(length(c.output_wires)) wires")
    println(io, "  Ancillae: $(ancilla_count(c))")
    println(io, "  Gates:    $(gc.total) (NOT=$(gc.NOT), CNOT=$(gc.CNOT), Toffoli=$(gc.Toffoli))")
    println(io, "  Depth:    $(depth(c))")
end
print_circuit(c::ReversibleCircuit) = print_circuit(stdout, c)
Base.show(io::IO, ::MIME"text/plain", c::ReversibleCircuit) = print_circuit(io, c)

"""
    t_count(c::ReversibleCircuit) -> Int

Count T-gates in fault-tolerant decomposition. Each Toffoli decomposes to 7 T-gates.
NOT and CNOT are Clifford gates (0 T-gates).
"""
t_count(c::ReversibleCircuit) = 7 * count(g -> g isa ToffoliGate, c.gates)

"""
    toffoli_depth(c::ReversibleCircuit) -> Int

Longest chain of Toffoli gates along a data-dependence path. NOT/CNOT gates
do not advance the count. This is the raw circuit-level metric; `t_depth`
converts it to a Clifford+T T-depth estimate via a Toffoli decomposition.
"""
function toffoli_depth(c::ReversibleCircuit)
    wd = zeros(Int, c.n_wires)
    md = 0
    for gate in c.gates
        gate isa ToffoliGate || continue
        ws = gate_wires(gate)
        d = maximum(wd[w] for w in ws) + 1
        for w in ws; wd[w] = d; end
        md = max(md, d)
    end
    return md
end

const _T_LAYERS_PER_TOFFOLI = Dict{Symbol,Int}(
    :ammr  => 1,  # Amy/Maslov/Mosca/Roetteler 2013, with ancilla. Matches Sun-Borissov 2026.
    :nc_7t => 3,  # Nielsen-Chuang classical 7-T Toffoli decomposition.
)

"""
    t_depth(c::ReversibleCircuit; decomp::Symbol=:ammr) -> Int

Clifford+T T-depth for `c` under a chosen Toffoli decomposition. Returns
`toffoli_depth(c) * k` where `k` is the decomposition's per-Toffoli T-layer
cost. Supported: `:ammr` (k=1, default), `:nc_7t` (k=3).
"""
function t_depth(c::ReversibleCircuit; decomp::Symbol=:ammr)
    haskey(_T_LAYERS_PER_TOFFOLI, decomp) ||
        error("unknown Toffoli decomposition :$decomp; supported: $(sort(collect(keys(_T_LAYERS_PER_TOFFOLI))))")
    return _T_LAYERS_PER_TOFFOLI[decomp] * toffoli_depth(c)
end

"""
    constant_wire_count(circuit::ReversibleCircuit) -> Int

Count wires that carry compile-time constant values (independent of input).
A wire is constant if it is never targeted by a gate whose controls are
data-dependent. Uses forward dataflow analysis on the first half of gates.
"""
function constant_wire_count(c::ReversibleCircuit)
    input_set = Set(c.input_wires)
    n_forward = (length(c.gates) - length(c.output_wires)) ÷ 2

    # Forward dataflow: track data-dependent wires
    data_dep = copy(input_set)
    for i in 1:n_forward
        gate = c.gates[i]
        if gate isa CNOTGate
            gate.control in data_dep && push!(data_dep, gate.target)
        elseif gate isa ToffoliGate
            (gate.control1 in data_dep || gate.control2 in data_dep) && push!(data_dep, gate.target)
        end
        # NOTGate: target stays constant (or stays data-dep if already marked)
    end

    # Constant = used (targeted by at least one gate) but not data-dependent
    targeted = Set{Int}()
    for i in 1:n_forward
        gate = c.gates[i]
        if gate isa NOTGate; push!(targeted, gate.target)
        elseif gate isa CNOTGate; push!(targeted, gate.target)
        elseif gate isa ToffoliGate; push!(targeted, gate.target)
        end
    end

    constant = setdiff(targeted, data_dep)
    return length(constant)
end

"""
    peak_live_wires(circuit::ReversibleCircuit) -> Int

Count the peak number of simultaneously non-zero wires during simulation.
This is the metric that EAGER cleanup optimizes — fewer simultaneously
live wires means smaller physical qubit requirements.
"""
function peak_live_wires(c::ReversibleCircuit)
    count_nonzero = 0
    peak = 0
    bits = zeros(Bool, c.n_wires)
    for g in c.gates
        t = _gate_target(g)
        was_nonzero = bits[t]
        apply!(bits, g)
        is_nonzero = bits[t]
        # Track count change: only the target wire can change
        count_nonzero += Int(is_nonzero) - Int(was_nonzero)
        peak = max(peak, count_nonzero)
    end
    return peak
end

"""
    verify_reversibility(c::ReversibleCircuit; n_tests::Int=100) -> true

Verify Bennett's invariants on `c` across `n_tests` random inputs. For each
input, asserts after running `c.gates` forward:
  (1) every wire in `c.ancilla_wires` is zero (Bennett ancilla-clean invariant);
  (2) every wire in `c.input_wires` holds its initial value (Bennett
      input-preservation — the forward pass must leave inputs untouched);
  (3) `Iterators.reverse(c.gates)` restores the bit vector to the initial
      state (self-consistency — tautological for self-inverse gates but cheap
      and catches harness bugs).

Returns `true` on success; raises `ErrorException` with context on any
violation. Replaces an earlier version that only checked (3), which was a
mathematical tautology for any sequence of self-inverse gates and therefore
missed every ancilla-leak and input-corruption bug. See Bennett-asw2 / U01.
"""
function verify_reversibility(c::ReversibleCircuit; n_tests::Int=100)
    for t in 1:n_tests
        bits = zeros(Bool, c.n_wires)
        offset = 0
        for w in c.input_widths
            for i in 1:w
                bits[c.input_wires[offset + i]] = rand(Bool)
            end
            offset += w
        end
        orig_input_values = [bits[w] for w in c.input_wires]
        orig = copy(bits)

        for g in c.gates; apply!(bits, g); end

        for w in c.ancilla_wires
            bits[w] && error("verify_reversibility (test $t): ancilla wire $w not zero after forward pass — Bennett ancilla-clean invariant violated")
        end

        for (k, w) in pairs(c.input_wires)
            bits[w] == orig_input_values[k] ||
                error("verify_reversibility (test $t): input wire $w changed from $(orig_input_values[k]) to $(bits[w]) — Bennett input-preservation violated")
        end

        for g in Iterators.reverse(c.gates); apply!(bits, g); end
        bits == orig || error("verify_reversibility (test $t): $(sum(bits .!= orig)) wires differ after forward+reverse — self-consistency check failed")
    end
    return true
end
