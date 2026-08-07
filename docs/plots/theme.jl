# Shared look for the README plots. Matches docs/src/assets/pipeline.svg:
# opaque near-white surface (readable on GitHub dark AND light), GitHub-light
# ink colors, recessive grid. Series colors are the first three slots of a
# CVD-validated categorical palette (adjacent + all-pairs safe).
#
# Every plot script here recomputes its data by running the compiler and
# asserts the expected values, so a committed PNG is a re-rendered passing
# test, never a transcribed number.

using CairoMakie

const SURFACE   = colorant"#fbfbfe"
const INK       = colorant"#1f2328"   # primary text
const INK2      = colorant"#57606a"   # secondary text / annotations
const GRID      = colorant"#e6e8eb"
const BLUE      = colorant"#2a78d6"   # series slot 1
const ORANGE    = colorant"#eb6834"   # series slot 2
const AQUA      = colorant"#1baf7a"   # series slot 3

set_theme!(
    backgroundcolor = SURFACE,
    textcolor = INK,
    fontsize = 15,
    Axis = (
        backgroundcolor = SURFACE,
        xgridcolor = GRID, ygridcolor = GRID,
        xtickcolor = INK2, ytickcolor = INK2,
        xticklabelcolor = INK2, yticklabelcolor = INK2,
        xlabelcolor = INK, ylabelcolor = INK,
        titlecolor = INK,
        spinewidth = 0.8,
        leftspinecolor = INK2, bottomspinecolor = INK2,
        rightspinevisible = false, topspinevisible = false,
        titlealign = :left,
        titlesize = 16,
        xlabelsize = 14, ylabelsize = 14,
    ),
    Legend = (
        backgroundcolor = SURFACE,
        framecolor = GRID,
        labelcolor = INK,
        labelsize = 13,
    ),
)

save_png(path, fig) = save(path, fig; px_per_unit = 2)
