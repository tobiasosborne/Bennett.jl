using Test
using Bennett
using InteractiveUtils

# T5-P5a equivalence: extract_parsed_ir(f, T) and extract_parsed_ir_from_ll
# on the same `code_llvm`-emitted IR must produce ParsedIR with identical
# ret_width / args / block structure / gate count.

# Helper: capture code_llvm(...; dump_module=true, optimize=true) to a temp
# .ll file and ingest via the new entry.
function _ingest_via_ll(f, arg_types::Type{<:Tuple}; optimize=true)
    ir_string = sprint(io -> InteractiveUtils.code_llvm(io, f, arg_types;
                                                          debuginfo=:none,
                                                          optimize=optimize,
                                                          dump_module=true))
    path = tempname() * ".ll"
    write(path, ir_string)
    try
        # The Julia-emitted module contains one `julia_*_NNN` function.
        # Find its name and pass explicitly — new path requires a name.
        # Julia-mangled names like `julia_#5_144` are quoted in LLVM IR:
        # `@"julia_#5_144"`. Match both quoted and bare forms.
        m = match(r"@\"(julia_[^\"]+)\"\(|@(julia_[\w\.]+)\("m, ir_string)
        entry = m === nothing ? nothing :
                (m.captures[1] !== nothing ? m.captures[1] : m.captures[2])
        entry === nothing && error("no julia_* define in captured .ll")
        return Bennett.extract_parsed_ir_from_ll(path; entry_function=entry)
    finally
        rm(path; force=true)
    end
end

@testset "Bennett-T5-P5a extract_parsed_ir_from_ll ≡ extract_parsed_ir" begin
    programs = [
        ("x+3 :: Int8",   x::Int8    -> x + Int8(3),        Tuple{Int8}),
        ("x*x :: Int8",   x::Int8    -> x * x,              Tuple{Int8}),
        ("x&y :: UInt8",  (x::UInt8, y::UInt8) -> x & y,    Tuple{UInt8,UInt8}),
        ("add16",         (x::Int16, y::Int16) -> x + y,    Tuple{Int16,Int16}),
    ]

    for (label, f, T) in programs
        @testset "equivalence — $label" begin
            pr_julia = extract_parsed_ir(f, T; optimize=true)
            pr_file  = _ingest_via_ll(f, T; optimize=true)

            @test pr_file isa Bennett.ParsedIR
            @test pr_julia.ret_width == pr_file.ret_width
            @test length(pr_julia.args) == length(pr_file.args)
            for (a, b) in zip(pr_julia.args, pr_file.args)
                @test a[2] == b[2]
            end
            @test length(pr_julia.blocks) == length(pr_file.blocks)
            # Gate counts should match byte-for-byte — same ParsedIR in,
            # same gates out.
            c_julia = reversible_compile(pr_julia)
            c_file  = reversible_compile(pr_file)
            @test gate_count(c_julia).total == gate_count(c_file).total
            @test verify_reversibility(c_file; n_tests=3)
        end
    end
end
