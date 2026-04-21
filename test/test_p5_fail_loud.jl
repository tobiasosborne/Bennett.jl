using Test
using Bennett

# T5-P5 fail-loud contracts for extract_parsed_ir_from_ll / _from_bc.

const P5_LL_FIXTURE = joinpath(@__DIR__, "fixtures", "ll", "p5a_add3.ll")

@testset "Bennett-T5-P5 fail-loud contracts" begin
    @testset "file not found — .ll" begin
        path = tempname() * "_does_not_exist.ll"
        err = nothing
        try
            Bennett.extract_parsed_ir_from_ll(path; entry_function="foo")
        catch e
            err = e
        end
        @test err isa ErrorException
        @test occursin("file not found", sprint(showerror, err))
    end

    @testset "file not found — .bc" begin
        path = tempname() * "_does_not_exist.bc"
        err = nothing
        try
            Bennett.extract_parsed_ir_from_bc(path; entry_function="foo")
        catch e
            err = e
        end
        @test err isa ErrorException
        @test occursin("file not found", sprint(showerror, err))
    end

    @testset "entry function name absent" begin
        err = nothing
        try
            Bennett.extract_parsed_ir_from_ll(P5_LL_FIXTURE;
                                               entry_function="nonexistent")
        catch e
            err = e
        end
        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("not found", msg)
        @test occursin("foo", msg)   # hints at the real function name
    end

    @testset "entry function is declaration-only" begin
        # Construct a .ll with only a declaration (no body).
        path = tempname() * ".ll"
        write(path, "declare i8 @decl_only(i8)\n")
        try
            err = nothing
            try
                Bennett.extract_parsed_ir_from_ll(path;
                                                   entry_function="decl_only")
            catch e
                err = e
            end
            @test err isa ErrorException
            @test occursin("declaration", sprint(showerror, err))
        finally
            rm(path; force=true)
        end
    end
end
