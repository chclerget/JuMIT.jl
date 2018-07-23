using JuMIT
using Base.Test
using BenchmarkTools
using Calculus



fields=[:P]
# testing misfit and gradient calculation for TD objects
tgrid1=Grid.M1D(0.,1.,5);

tgrid2=Grid.M1D(0.,1.,10);

acqgeom=JuMIT.Acquisition.Geom_fixed(10,10,10,10,10,10,10,10)

x=JuMIT.Data.TD_ones(fields,tgrid1,acqgeom)

@testset "simple LS error: x and y same time grid" begin
	y=JuMIT.Data.TD_ones(fields,tgrid1,acqgeom)

	randn!(x)
	randn!(y)

	pa=JuMIT.Data.P_misfit(x,y);
	@time JuMIT.Data.func_grad!(pa,:dJx);
	gg1=vec(pa.dJx)

	function err(x)
		copy!(pa.x, x)
		return JuMIT.Data.func_grad!(pa)
	end

	xvec=vec(pa.x)
	gg2=Calculus.gradient(x -> err(x), xvec)

	# check gradient with Finite Differencing
	@test gg1 ≈ gg2
end

#=


rrrrrr




# loop over same time grid and different time grid (interp_flag on/off)
for y in [JuMIT.Data.TD_ones(fields,tgrid2,acqgeom), JuMIT.Data.TD_ones(fields,tgrid1,acqgeom)]
	println("#########################################")


	# generate some random data
	randn!(y.d[1,1])
	randn!(x.d[1,1])

	for func_attrib in [:cls]
		coup=JuMIT.Coupling.TD_delta(y.tgrid, [0.1,0.1], 0.0,  x.fields, x.acqgeom)
		randn!(coup.ssf[1,1])
		pa=JuMIT.Data.P_misfit(x,y, func_attrib=func_attrib, coup=coup);



		xvec=vec(pa.x.d[1,1])
		gg2=Calculus.gradient(x -> err(x), xvec)

		@time JuMIT.Data.func_grad!(pa,:dJx);
		gg1=vec(pa.dJx.d[1,1])
		# check gradient with Finite Differencing
		@test gg1 ≈ gg2

		function errw(xvec)

			for i in eachindex(pa.coup.ssf[1,1])
				pa.coup.ssf[1,1][i]=xvec[i]
			end

			return JuMIT.Data.func_grad!(pa)
		end

		xvec=vec(pa.coup.ssf[1,1])
		gg2=Calculus.gradient(x -> errw(x), xvec)

		@time JuMIT.Data.func_grad!(pa,:dJssf);
		gg1=vec(pa.dJssf[1,1])
		# check gradient with Finite Differencing
		@test gg1 ≈ gg2


	end
end



=#