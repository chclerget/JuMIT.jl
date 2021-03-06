
"""
Return functional and gradient of the LS objective 
* `last_x::Vector{Float64}` : buffer is only updated when x!=last_x, and modified such that last_x=x
"""
function func(x::Vector{Float64}, last_x::Vector{Float64}, pa::Param, attrib_mod)
	global to

	if(!isequal(x, last_x))
		copyto!(last_x, x)
		# do forward modelling, apply F x
		@timeit to "F!" F!(pa, x, attrib_mod)
	end

	# compute misfit 
	f = Data.func_grad!(pa.paTD)
	return f
end

function grad!(storage, x::Vector{Float64}, last_x::Vector{Float64}, pa::Param, attrib_mod)
	global to

	# (inactive when applied on same model)
	if(!isequal(x, last_x))
		copyto!(last_x, x)
		# do forward modelling, apply F x 
		@timeit to "F!" F!(pa, x, attrib_mod)
	end

	# compute functional and get ∇_d J (adjoint sources)
	f = Data.func_grad!(pa.paTD, :dJx);

	# update adjoint sources after time reversal
	update_adjsrc!(pa.adjsrc, pa.paTD.dJx, pa.adjacqgeom)

	# do adjoint modelling here with adjoint sources Fᵀ F P x
	@timeit to "Fadj!" Fadj!(pa)	

	# adjoint of interpolation
        spray_gradient!(storage,  pa, attrib_mod)

	return storage
end 



function ζfunc(x, last_x, pa::Param, ::LS, attrib_mod)
	return func(x, last_x, pa, attrib_mod)
end


function ζgrad!(storage, x, last_x, pa::Param, ::LS, attrib_mod)
	return grad!(storage, x, last_x, pa, attrib_mod)
end


function ζfunc(x, last_x, pa::Param, obj::LS_prior, attrib_mod)
	f1=func(x, last_x, pa, attrib_mod)

	# calculate the generalized least-squares error
	# note: change the inverse model covariance matrix `pmgls.Q` accordingly
	f2=Misfits.func_grad!(nothing, x, pa.mx.prior, obj.pmgls)

	return f1*obj.pdgls+f2
end

function ζgrad!(storage, x, last_x, pa::Param, obj::LS_prior, attrib_mod)
	g1=pa.mx.gm[1]
	grad!(g1, x, last_x, pa, attrib_mod)

	g2=pa.mx.gm[2]
	Misfits.func_grad!(g2, x, pa.mx.prior, obj.pmgls)

	rmul!(g1, obj.pdgls)

	for i in eachindex(storage)
		@inbounds storage[i]=g1[i]+g2[i]
	end
	return storage
end


"""
Perform a forward simulation.
Update `pa.paTD.x`. 
This simulation is common for both functional and gradient calculation.
During the computation of the gradient, we need an adjoint simulation.
Update the buffer, which consists of the modelled data
and boundary values for adjoint calculation.

# Arguments

* `x::Vector{Float64}` : inversion variable
* `pa::Param` : parameters that are constant during the inversion 
* if x is absent, using `pa.modm` for modeling
"""
function F!(pa::Param, x, ::ModFdtd)

	# switch off born scattering
	pa.paf.c.born_flag=false

	# initialize boundary, as we will record them now
	Fdtd.initialize_boundary!(pa.paf)

	if(!(x===nothing))
		# project x, which lives in modi, on to model space (modm)
		x_to_modm!(pa, x)
	end

	# update model in the forward engine
	Fdtd.update_model!(pa.paf.c, pa.modm)

	pa.paf.c.activepw=[1,]
	pa.paf.c.illum_flag=false
	pa.paf.c.sflags=[2, 0]
	pa.paf.c.rflags=[1, 0] # record only after first scattering
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])
	pa.paf.c.backprop_flag=1
	pa.paf.c.gmodel_flag=false

	Fdtd.mod!(pa.paf);

	# copy data to evaluate misfit
	dcal=pa.paf.c.data[1]
	copyto!(pa.paTD.x,dcal)
end


"""
Born modeling with `modm` as the perturbed model and `modm0` as the background model.
"""
function F!(pa::Param, x, ::ModFdtdBorn)

	# update background model in the forward engine 
	Fdtd.update_model!(pa.paf.c, pa.modm0)
	if(!(x===nothing))
		# project x, which lives in modi, on to model space (modm)
		x_to_modm!(pa, x)
	end
	# update perturbed models in the forward engine
	Fdtd.update_δmods!(pa.paf.c, pa.modm)

	Fbornmod!(pa::Param)
end

function Fbornmod!(pa::Param) 

	# switch on born scattering
	pa.paf.c.born_flag=true

	pa.paf.c.activepw=[1,2] # two wavefields are active
	pa.paf.c.illum_flag=false 
	pa.paf.c.sflags=[2, 0] # no sources on second wavefield
	pa.paf.c.rflags=[0, 1] # record only after first scattering

	# source wavelets (for second wavefield, they are dummy)
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])

	# actually, should record only when background field is changed
	pa.paf.c.backprop_flag=1 # store boundary values for gradient later

	pa.paf.c.gmodel_flag=false # no gradient

	Fdtd.mod!(pa.paf);
	dcal=pa.paf.c.data[2]
	copyto!(pa.paTD.x,dcal)

	# switch off born scattering once done
	pa.paf.c.born_flag=false
end


"""
Perform adjoint modelling in `paf` using adjoint sources `adjsrc`.
"""
function Fadj!(pa::Param)

	# need to explicitly turn off the born flag for adjoint modelling
	pa.paf.c.born_flag=false

	# require gradient, switch on the flag
	pa.paf.c.gmodel_flag=true

	# both wavefields are active
	pa.paf.c.activepw=[1,2]

	# no need of illum during adjoint modeling
	pa.paf.c.illum_flag=false

	# force boundaries in first pw and back propagation for second pw
	pa.paf.c.sflags=[-2,2] 
	pa.paf.c.backprop_flag=-1

	# update source wavelets in paf using adjoint sources
	Fdtd.update_acqsrc!(pa.paf,[pa.acqsrc,pa.adjsrc])

	# no need to record data during adjoint propagation
	pa.paf.c.rflags=[0,0]

	# adjoint modelling
	Fdtd.mod!(pa.paf);

	# put rflags back
	pa.paf.c.rflags=[1,1]

	return pa.paf.c.gradient
end


function operator_Born(pa)
	fw=(y,x)->Fborn_map!(y, x, pa)
	bk=(y,x)->Fadj_map!(y, x, pa)

	return LinearMap(fw, bk, 
		  length(pa.paTD.dJx),  # length of output
		  xfwi_ninv(pa), # length of input
		  ismutating=true)
end

function Fborn_map!(δy, δx, pa)
	δx_to_δmods!(pa, δx)
	Fbornmod!(pa)
	copyto!(δy, pa.paTD.x)
end

function Fadj_map!(δy, δx, pa)
	copyto!(pa.paTD.dJx, δx)

	# adjoint sources
	update_adjsrc!(pa.adjsrc, pa.paTD.dJx, pa.adjacqgeom)

	# adjoint simulation
	Fadj!(pa)

	# chain rule corresponding to reparameterization
	Models.pert_gradient_chainrule!(pa.mxm.gx, pa.paf.c.gradient, pa.modm0, pa.parameterization)

	# finally, adjoint of interpolation
	Interpolation.interp_spray!(δy, 
			     pa.mxm.gx, pa.paminterp, :spray, 
			     count(pa.parameterization.≠:null))
end



