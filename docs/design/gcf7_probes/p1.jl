using InteractiveUtils
struct S; a::Int; b::Int; end
const R = Ref(S(3,4))
const A = [10, 20, 30]
const T = Ref((5,6))
const M = Memory{Int}([7,8,9])
g1(x::Int) = (s = R[]; s.a + s.b + x)
g2(i::Int) = @inbounds A[i]
g3(x::Int) = (t = T[]; t[1] + t[2] + x)
g4(x::Int) = length(A) + x
g5(x::Int) = length(M) + x
for (f,t) in ((g1,Tuple{Int}),(g2,Tuple{Int}),(g3,Tuple{Int}),(g4,Tuple{Int}),(g5,Tuple{Int}))
  s = sprint(io->code_llvm(io, f, t; debuginfo=:none, optimize=false, dump_module=true))
  println("=== ", f)
  for l in split(s, '\n')
    if occursin("jl_global", l) || occursin("memcpy", l) || occursin("define", l)
      println(l)
    end
  end
end
