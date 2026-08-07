# The doubling law: gate counts for `x + 1` at every integer width, under the
# explicit regression-baseline strategy (`add=:ripple, fold_constants=true`,
# CLAUDE.md §6 / test/test_gate_count_regression.jl). The script recompiles
# all four circuits, verifies reversibility, and asserts the pinned baselines
# before drawing — the PNG is a passing test, drawn.
#
#   julia --project=docs/plots docs/plots/scaling.jl
#   -> docs/src/assets/scaling.png

include(joinpath(@__DIR__, "theme.jl"))
using Bennett

widths = [8, 16, 32, 64]
types  = [Int8, Int16, Int32, Int64]

counts = map(types) do T
    f = let T = T; x -> x + T(1); end
    c = reversible_compile(f, T; add = :ripple, fold_constants = true)
    @assert verify_reversibility(c)
    gate_count(c)
end

total   = [gc.total   for gc in counts]
cnot    = [gc.CNOT    for gc in counts]
toffoli = [gc.Toffoli for gc in counts]

# The pinned regression baselines — if these move, the plot must not quietly
# redraw; the baseline change has to be an explicit decision (CLAUDE.md §6).
@assert total   == [58, 114, 226, 450]
@assert toffoli == [12, 28, 60, 124]
@assert all(total[i+1] == 2total[i] - 2   for i in 1:3)  # total(2W) = 2·total(W) − 2
@assert all(toffoli[i+1] == 2toffoli[i] + 4 for i in 1:3) # T(2W) = 2·T(W) + 4

fig = Figure(size = (900, 520))
ax = Axis(fig[1, 1];
    title  = "Gate-count scaling of  x + 1   (add = :ripple, fold_constants = true)",
    xlabel = "bit width W",
    ylabel = "gates",
    xscale = log2, yscale = log2,
    xticks = (widths, string.(widths)),
    yticks = ([16, 32, 64, 128, 256, 512], ["16", "32", "64", "128", "256", "512"]),
)
xlims!(ax, 7, 120)   # right headroom for the direct labels
ylims!(ax, 9, 700)

series = [
    (total,   BLUE,   "total"),
    (cnot,    ORANGE, "CNOT"),
    (toffoli, AQUA,   "Toffoli"),
]
for (ys, col, lab) in series
    lines!(ax, widths, ys; color = col, linewidth = 2)
    scatter!(ax, widths, ys; color = col, markersize = 11,
             strokecolor = SURFACE, strokewidth = 1.5)
    text!(ax, widths[end], ys[end]; text = lab, color = col,
          align = (:left, :center), offset = (10, 0), fontsize = 14)
end

# The two recurrences, stated next to the lines they govern. Both are asserted
# above and pinned in test/test_gate_count_regression.jl.
text!(ax, 16, 340; text = "total(2W) = 2·total(W) − 2",
      color = INK2, fontsize = 13, align = (:left, :center))
text!(ax, 23, 22; text = "T(2W) = 2·T(W) + 4",
      color = INK2, fontsize = 13, align = (:left, :center))

axislegend(ax,
    [LineElement(color = c, linewidth = 2) for (_, c, _) in series],
    [lab for (_, _, lab) in series];
    position = :lt, framevisible = true)

out = joinpath(@__DIR__, "..", "src", "assets", "scaling.png")
save_png(out, fig)
println("wrote $(abspath(out))")
