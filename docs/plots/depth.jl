# The depth trade-off: Toffoli-depth (the FTQC-relevant metric) versus width
# for the adder strategies (`add = :ripple / :cuccaro / :qcla`) and the
# multiplier strategies (`mul = :shift_add / :qcla_tree`). Carry-lookahead
# buys O(log W) depth by spending more Toffolis; the QCLA-tree multiplier
# reaches depth 56 vs schoolbook's 180 at W = 32 (the README head-to-head).
# All circuits are recompiled and verified before drawing.
#
#   julia --project=docs/plots docs/plots/depth.jl
#   -> docs/src/assets/depth.png

include(joinpath(@__DIR__, "theme.jl"))
using Bennett

add_widths = [8, 16, 32, 64]
add_types  = [Int8, Int16, Int32, Int64]
mul_widths = [8, 16, 32]
mul_types  = [Int8, Int16, Int32]

function depths(op, types, kw)
    map(types) do T
        c = reversible_compile(op, T, T; kw...)
        @assert verify_reversibility(c)
        toffoli_depth(c)
    end
end

ripple  = depths(+, add_types, (add = :ripple,))
cuccaro = depths(+, add_types, (add = :cuccaro,))
qcla    = depths(+, add_types, (add = :qcla,))

shift_add = depths(*, mul_types, (mul = :shift_add,))
qcla_tree = depths(*, mul_types, (mul = :qcla_tree,))

# Measured 2026-08-07 (this file, run against the tree). QCLA's +4 per
# doubling is the O(log W) signature; the multiplier head-to-head is the
# README claim "depth 56 vs 180 at Int32".
@assert ripple    == [14, 30, 62, 126]
@assert cuccaro   == [26, 58, 122, 250]
@assert qcla      == [16, 20, 24, 28]
@assert shift_add == [36, 84, 180]
@assert qcla_tree == [40, 48, 56]

fig = Figure(size = (1100, 500))

ax1 = Axis(fig[1, 1];
    title  = "Adders:  x + y",
    xlabel = "bit width W", ylabel = "Toffoli-depth",
    xscale = log2, xticks = (add_widths, string.(add_widths)),
)
xlims!(ax1, 7, 120)
adders = [
    (ripple,  BLUE,   ":ripple    O(W)"),
    (cuccaro, ORANGE, ":cuccaro  O(W)"),
    (qcla,    AQUA,   ":qcla      O(log W)"),
]
for (ys, col, lab) in adders
    lines!(ax1, add_widths, ys; color = col, linewidth = 2)
    scatter!(ax1, add_widths, ys; color = col, markersize = 11,
             strokecolor = SURFACE, strokewidth = 1.5)
    text!(ax1, add_widths[end], ys[end]; text = first(split(lab)), color = col,
          align = (:left, :center), offset = (10, 0), fontsize = 14)
end
axislegend(ax1,
    [LineElement(color = c, linewidth = 2) for (_, c, _) in adders],
    [lab for (_, _, lab) in adders];
    position = :lt, framevisible = true)

ax2 = Axis(fig[1, 2];
    title  = "Multipliers:  x × y",
    xlabel = "bit width W", ylabel = "Toffoli-depth",
    xscale = log2, xticks = (mul_widths, string.(mul_widths)),
)
xlims!(ax2, 7, 60)
muls = [
    (shift_add, BLUE, ":shift_add  O(W²) gates, O(W) depth"),
    (qcla_tree, AQUA, ":qcla_tree  O(log² W) depth"),
]
for (ys, col, lab) in muls
    lines!(ax2, mul_widths, ys; color = col, linewidth = 2)
    scatter!(ax2, mul_widths, ys; color = col, markersize = 11,
             strokecolor = SURFACE, strokewidth = 1.5)
    text!(ax2, mul_widths[end], ys[end]; text = first(split(lab)), color = col,
          align = (:left, :center), offset = (10, 0), fontsize = 14)
end
axislegend(ax2,
    [LineElement(color = c, linewidth = 2) for (_, c, _) in muls],
    [lab for (_, _, lab) in muls];
    position = :lt, framevisible = true)

out = joinpath(@__DIR__, "..", "src", "assets", "depth.png")
save_png(out, fig)
println("wrote $(abspath(out))")
