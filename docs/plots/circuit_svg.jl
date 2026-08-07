# Gate art + animated Bennett construction, generated from the real compiler
# output — never drawn from memory. Subject: the 23-gate, 16-wire circuit for
#
#   reversible_compile(x -> x + UInt8(1), UInt8;
#                      bit_width = 3, add = :ripple, fold_constants = true)
#
# The script recompiles the circuit, asserts the exact gate sequence (fail
# loud on drift), replays it bit-by-bit for x = 3, asserts the Bennett
# invariants on the replayed state, then emits:
#
#   docs/src/assets/circuit_x_plus_1.svg      static gate art, phase bands
#   docs/src/assets/bennett_construction.svg  SMIL-animated forward/copy/uncompute
#
#   julia --project=docs/plots docs/plots/circuit_svg.jl
#
# Both SVGs are opaque-background (readable on GitHub dark AND light) and
# animate without JavaScript (GitHub <img> sandboxing allows SMIL/CSS only).
#
# Wire roles (ground-truthed against src/, see worklog):
#   1-3   input x, LSB first                     (lowering/driver.jl arg alloc)
#   4     entry-block predicate wire, set to 1   (lowering/driver.jl)
#   5-7   the folded constant UInt8(1), LSB set  (lowering/operand.jl resolve!)
#   8-10  sum bits — the lowered result          (adder.jl lower_add!)
#   11-13 carry chain, 11 = carry-in             (adder.jl lower_add!)
#   14-16 output register, allocated at bennett() copy-out (bennett_transform.jl)
# Wires 6, 7, 11 are allocated but appear in no gate: every gate that read
# them had a known-false control and folded to a no-op.

using Bennett

c = reversible_compile(x -> x + UInt8(1), UInt8;
                       bit_width = 3, add = :ripple, fold_constants = true)
@assert verify_reversibility(c)
@assert simulate(c, UInt8(3)) == UInt8(4)
@assert c.input_wires == [1, 2, 3] && c.output_wires == [14, 15, 16]

gates = c.gates
expect(g, s) = string(g) == s || error("gate drift: got $(g), expected $(s) — re-derive the diagram")
const EXPECTED = [
    "CNOTGate(1, 8)", "NOTGate(8)", "CNOTGate(1, 12)", "CNOTGate(2, 9)",
    "ToffoliGate(9, 12, 13)", "CNOTGate(12, 9)", "CNOTGate(3, 10)",
    "CNOTGate(13, 10)", "NOTGate(5)", "NOTGate(4)",
    "CNOTGate(8, 14)", "CNOTGate(9, 15)", "CNOTGate(10, 16)",
    "NOTGate(4)", "NOTGate(5)", "CNOTGate(13, 10)", "CNOTGate(3, 10)",
    "CNOTGate(12, 9)", "ToffoliGate(9, 12, 13)", "CNOTGate(2, 9)",
    "CNOTGate(1, 12)", "NOTGate(8)", "CNOTGate(1, 8)",
]
@assert length(gates) == 23
foreach(expect, gates, EXPECTED)

# ---- bit-level replay for x = 3 (LSB first: wires 1,2,3 = 1,1,0) ----------
nw = 16
state = falses(nw)
state[1] = true; state[2] = true
timeline = [copy(state)]                     # timeline[k+1] = state after gate k
for g in gates
    if g isa Bennett.NOTGate
        state[g.target] = !state[g.target]
    elseif g isa Bennett.CNOTGate
        state[g.control] && (state[g.target] = !state[g.target])
    elseif g isa Bennett.ToffoliGate
        state[g.control1] && state[g.control2] && (state[g.target] = !state[g.target])
    else
        error("unknown gate $(g)")
    end
    push!(timeline, copy(state))
end
final = timeline[end]
@assert final[1:3] == [true, true, false]            # input preserved
@assert !any(final[4:13])                            # every ancilla back to 0
@assert final[14:16] == [false, false, true]         # 4 = 0b100, LSB first
@assert timeline[14][14:16] == [false, false, true]  # answer present right after copy

# ---- geometry --------------------------------------------------------------
const ROWH  = 26                 # wire pitch
const COLW  = 30                 # gate pitch
const XL    = 168.0              # first gate column left edge
const Y0    = 96.0               # wire 1 y
const NG    = 23
wy(w) = Y0 + (w - 1) * ROWH
gx(i) = XL + (i - 0.5) * COLW
const XEND  = XL + NG * COLW + 8
const WIDTH = round(Int, XEND + 46)
const HEIGHT = round(Int, wy(nw) + 48)

# phases (gate index ranges) and their pastel band fills (pipeline.svg family)
const PHASES = [
    (1:10,  "#e9effb", "#2a78d6", "1 · forward — compute"),
    (11:13, "#fff3e0", "#b26a00", "2 · copy the answer"),
    (14:23, "#e7f6ec", "#1a7f4b", "3 · reverse — uncompute"),
]

const INK   = "#1f2328"
const INK2  = "#57606a"
const WIRE  = "#b6bcc4"
const BLUE  = "#2a78d6"
const ORANGE = "#eb6834"

# (base, subscript) pairs; rendered with a <tspan> subscript (entity subscript
# digits are missing from some raster fonts).
const LABELS = [
    ("x", "0"), ("x", "1"), ("x", "2"), ("pred", ""), ("const", "0"),
    ("const", "1"), ("const", "2"), ("s", "0"), ("s", "1"), ("s", "2"),
    ("carry-in", ""), ("carry", "1"), ("carry", "2"),
    ("out", "0"), ("out", "1"), ("out", "2"),
]
label_svg((base, sub); suffix = "") =
    base * (isempty(sub) ? "" : """<tspan font-size="9" dy="3">$sub</tspan><tspan dy="-3">&#8203;</tspan>""") * suffix

# CIRCUIT_SVG_DEBUG=1: emit the animated file's final frame statically (trails
# visible, no <animate>) to scratch, for rasterizers that drop animated nodes.
const DEBUG = get(ENV, "CIRCUIT_SVG_DEBUG", "0") == "1"
const GROUP_SEP = [3, 4, 7, 10, 13]          # draw a separator below these wires

svg_open(io) = print(io, """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $WIDTH $HEIGHT" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
  <rect x="1" y="1" width="$(WIDTH-2)" height="$(HEIGHT-2)" rx="14" fill="#fbfbfe" stroke="#e6e8eb"/>
""")

function draw_bands!(io)
    for (rng, fill, _, _) in PHASES
        x0 = XL + (first(rng) - 1) * COLW
        x1 = XL + last(rng) * COLW
        print(io, """  <rect x="$(x0)" y="$(Y0-16)" width="$(x1-x0)" height="$(wy(nw)-Y0+30)" fill="$fill" rx="6"/>\n""")
    end
    for (rng, _, col, lab) in PHASES
        xm = XL + (first(rng) - 1 + length(rng) / 2) * COLW
        print(io, """  <text x="$xm" y="$(Y0-26)" text-anchor="middle" font-size="13" font-weight="600" fill="$col">$lab</text>\n""")
    end
end

function draw_wires!(io; labels = [label_svg(l) for l in LABELS])
    for w in 1:nw
        y = wy(w)
        print(io, """  <line x1="$(XL-10)" y1="$y" x2="$XEND" y2="$y" stroke="$WIRE" stroke-width="1"/>\n""")
        print(io, """  <text x="$(XL-16)" y="$(y+4)" text-anchor="end" font-size="12" fill="$INK">$(labels[w])</text>\n""")
    end
    for w in GROUP_SEP   # group separators, label gutter only (not over the circuit)
        y = wy(w) + ROWH / 2
        print(io, """  <line x1="20" y1="$y" x2="$(XL-14)" y2="$y" stroke="#d8dce1" stroke-width="1" stroke-dasharray="3 5"/>\n""")
    end
end

function draw_gate!(io, i, g)
    x = gx(i)
    dot(w)  = print(io, """  <circle cx="$x" cy="$(wy(w))" r="3.6" fill="$INK"/>\n""")
    function target(w)
        y = wy(w)
        print(io, """  <circle cx="$x" cy="$y" r="7" fill="none" stroke="$INK" stroke-width="1.6"/>\n""")
        print(io, """  <line x1="$(x-7)" y1="$y" x2="$(x+7)" y2="$y" stroke="$INK" stroke-width="1.6"/>\n""")
        print(io, """  <line x1="$x" y1="$(y-7)" x2="$x" y2="$(y+7)" stroke="$INK" stroke-width="1.6"/>\n""")
    end
    link(w1, w2) = print(io, """  <line x1="$x" y1="$(wy(w1))" x2="$x" y2="$(wy(w2))" stroke="$INK" stroke-width="1.6"/>\n""")
    if g isa Bennett.NOTGate
        target(g.target)
    elseif g isa Bennett.CNOTGate
        a, b = minmax(g.control, g.target)
        link(a, b); dot(g.control); target(g.target)
    elseif g isa Bennett.ToffoliGate
        ws = (g.control1, g.control2, g.target)
        link(minimum(ws), maximum(ws)); dot(g.control1); dot(g.control2); target(g.target)
    end
end

# ---- static gate art -------------------------------------------------------
open(joinpath(@__DIR__, "..", "src", "assets", "circuit_x_plus_1.svg"), "w") do io
    svg_open(io)
    print(io, """  <text x="$(WIDTH ÷ 2)" y="30" text-anchor="middle" font-size="15" font-weight="600" fill="$INK">Every gate of  x + 1  at 3 bits &#8212; add = :ripple, fold_constants = true</text>\n""")
    print(io, """  <text x="$(WIDTH ÷ 2)" y="50" text-anchor="middle" font-size="12" fill="$INK2">23 gates, 16 wires &#183; wires 4&#8211;13 are ancillae and provably end at 0 &#183; wires 6, 7, 11 folded to silence</text>\n""")
    draw_bands!(io)
    draw_wires!(io)
    foreach(i -> draw_gate!(io, i, gates[i]), 1:NG)
    print(io, "</svg>\n")
end
println("wrote circuit_x_plus_1.svg")

# ---- animated Bennett construction -----------------------------------------
# One SMIL clock of T seconds, looped. Gate i fires at TFIRE[i]; the value
# trail (thick blue overlay where a wire holds 1) is revealed left-to-right
# as the cursor passes; captions swap per phase; everything resets each loop.
const INTRO, DT_F, DT_C, DT_R, HOLD = 1.2, 0.55, 0.85, 0.42, 3.4
TFIRE = Float64[]
let t = INTRO
    for i in 1:NG
        t += i <= 10 ? DT_F : i <= 13 ? DT_C : DT_R
        push!(TFIRE, t)
    end
end
const T = TFIRE[end] + HOLD
frac(t) = round(clamp(t, 0, T) / T; digits = 4)

# opacity animation: 0 until t_on, 1 until t_off, then 0 (looped, ~40ms ramps)
function fade(io, t_on, t_off)
    DEBUG && return
    ks = [0.0, frac(t_on), frac(t_on + 0.04), frac(t_off), frac(t_off + 0.04), 1.0]
    vs = [0, 0, 1, 1, 0, 0]
    keep = unique(i -> ks[i], eachindex(ks))       # guard against duplicate keyTimes
    print(io, """<animate attributeName="opacity" dur="$(T)s" repeatCount="indefinite" values="$(join(vs[keep], ';'))" keyTimes="$(join(ks[keep], ';'))"/>""")
end
const HIDDEN = DEBUG ? "0.75" : "0"     # initial opacity of animated elements

const TFADE = T - 0.25                     # trail + captions fade just before loop

anim_path = DEBUG ? joinpath(tempdir(), "bennett_construction_debug.svg") :
                    joinpath(@__DIR__, "..", "src", "assets", "bennett_construction.svg")
open(anim_path, "w") do io
    svg_open(io)
    print(io, """  <text x="$(WIDTH ÷ 2)" y="30" text-anchor="middle" font-size="15" font-weight="600" fill="$INK">Bennett&#8217;s construction:  compute &#8594; copy &#8594; uncompute&#8194;(x + 1 at 3 bits, x = 3)</text>\n""")
    print(io, """  <text x="$(WIDTH ÷ 2)" y="50" text-anchor="middle" font-size="12" fill="$INK2">thick blue = wire holds 1 &#183; ten ancillae rise in the forward pass and are all provably 0 again at the end</text>\n""")
    draw_bands!(io)
    draw_wires!(io; labels = [label_svg(l; suffix = " = $(Int(timeline[1][w]))") for (w, l) in enumerate(LABELS)])

    # value trail: for each wire, each inter-gate interval where it holds 1
    for w in 1:nw, k in 0:NG
        timeline[k+1][w] || continue
        x0 = k == 0 ? XL - 10 : gx(k)
        x1 = k == NG ? XEND : gx(k + 1)
        t_on = k == 0 ? 0.3 : TFIRE[k]
        y = wy(w)
        print(io, """  <line x1="$x0" y1="$y" x2="$x1" y2="$y" stroke="$BLUE" stroke-width="4" stroke-linecap="round" opacity="$HIDDEN">""")
        fade(io, t_on, TFADE)
        print(io, "</line>\n")
    end

    foreach(i -> draw_gate!(io, i, gates[i]), 1:NG)

    # sweeping cursor: parks left, visits each gate at its firing time, parks right
    if !DEBUG
        xs = vcat([XL - 14], [gx(i) for i in 1:NG], [XEND + 6])
        ts = vcat([0.0], TFIRE, [TFIRE[end] + 0.4])
        ks = vcat([frac(t) for t in ts], [1.0])
        vs = vcat([round(x; digits = 1) for x in xs], [xs[end]])
        print(io, """  <g opacity="0.85"><line x1="0" y1="$(Y0-14)" x2="0" y2="$(wy(nw)+12)" stroke="$ORANGE" stroke-width="2">""")
        print(io, """<animate attributeName="x1" dur="$(T)s" repeatCount="indefinite" values="$(join(vs, ';'))" keyTimes="$(join(ks, ';'))"/>""")
        print(io, """<animate attributeName="x2" dur="$(T)s" repeatCount="indefinite" values="$(join(vs, ';'))" keyTimes="$(join(ks, ';'))"/>""")
        print(io, "</line></g>\n")
    end

    # phase captions + the closing claim, at the bottom
    yc = HEIGHT - 16
    caps = [
        (0.3,                "run the computation forward on ancilla wires", INK2),
        (TFIRE[11] - 0.4,    "CNOT-copy the 3 answer bits to the output register", "#b26a00"),
        (TFIRE[14] - 0.3,    "replay every forward gate in reverse order", "#1a7f4b"),
        (TFIRE[end] + 0.4,   "inputs intact &#183; answer = 4 &#183; every ancilla back to 0 &#8212; verify_reversibility(c) == true", INK),
    ]
    for (i, (t_on, txt, col)) in enumerate(caps)
        t_off = i < length(caps) ? caps[i+1][1] : TFADE
        DEBUG && i < length(caps) && continue     # debug frame: only the closing caption
        print(io, """  <text x="$(WIDTH ÷ 2)" y="$yc" text-anchor="middle" font-size="13" fill="$col" opacity="$(DEBUG ? "1" : "0")">$txt""")
        fade(io, t_on, t_off)
        print(io, "</text>\n")
    end
    print(io, "</svg>\n")
end
println("wrote bennett_construction.svg")
