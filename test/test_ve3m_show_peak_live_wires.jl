using Test
using Bennett

@testset "U165 / Bennett-ve3m — peak_live_wires in show" begin
    c = reversible_compile(x -> x + Int8(1), Int8)
    buf = IOBuffer()
    show(buf, MIME"text/plain"(), c)
    s = String(take!(buf))

    # The summary must include the peak-live-wire count.
    @test occursin("Peak live", s)
    @test occursin(string(peak_live_wires(c)), s)

    # Existing fields must still be present (regression).
    @test occursin("Wires:", s)
    @test occursin("Gates:", s)
    @test occursin("Depth:", s)
end
