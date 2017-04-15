module Fdtd

import SIT.Grid
import SIT.Models
import SIT.F90libs
import SIT.Acquisition
import SIT.Data
import SIT.Gallery
import SIT.DSP


"""
As forward modeling method, the 
finite-difference method is employed. 
It uses a discrete version of the two-dimensional isotropic acoustic wave equation.
As shown in  
Figure~ef{fdshmesh_acou}, a staggered-grid mesh is used 
# Keyword Arguments
* `jobname` : dominant frequency
* `npropwav` : number of wavefields propagating independently in the same medium time-domain grid
* `model` : Seismic Model
* `model0` : Background Seismic Model used for Born modeling 
* `tgridmod` : time grid for modeling
* `tgrid` : time grid for data output
* `recv_nfield::Int64=1` : number of fields that receivers record 
* `prop_flags`: flags that combine propagating wavefields
* `boundary_save_flag::Bool=false` : save final state variables and the boundary conditions for later use
* `boundary_in::Any=nothing` : input final state variables and boundary

# Example
```julia
julia> records, boundary_save  = fdtd_mod();
```
Credits: Pawan Bharadwaj, 2017
"""
function fdtd_mod(;
		  jobname::AbstractString = "Hello",
		  npropwav::Int64 = 1, 
		  model::Models.Seismic = Gallery.Seismic(:acou_homo1),
		  model0::Models.Seismic = Gallery.Seismic(:acou_homo1),
		  tgridmod::Grid.M1D = Gallery.M1D(:acou_homo1),
		  tgrid::Grid.M1D = tgridmod,
		  acqgeom::Array{Acquisition.Geom} = [Gallery.Geom(:acou_homo1)],
		  acqsrc::Array{Acquisition.Src} = [Gallery.Src(:acou_homo1)],
		  src_flags::Vector{Float64}=fill(2.0,npropwav), # bilinear for all
		  recv_flags::Vector{Float64}=fill(2.0,npropwav), # bilinear for all
		  recv_nfield::Int64=1, 
		  prop_flags = "[BILINEAR]",
		  boundary_save_flag::Bool=false,  
		  boundary_in::Any=nothing,
		  abs_trbl::AbstractString = "[T][R][B][L]",
		  born_flag::Bool=false,
		  grad_out_flag=false,
		  verbose::Bool=false
		 )

maximum(tgridmod.x) < maximum(acqsrc[1].tgrid.x) ? error("modeling time is less than source time") :

tgridmod.δx > tgrid.δx ? error("output time grid sampling finer than modeling") :

# find maximum and minimum frequencies in the source wavelets
freqmin = DSP.findfreq(acqsrc[1].wav[:,1,1],acqsrc[1].tgrid,attrib=:min) 
freqmax = DSP.findfreq(acqsrc[1].wav[:,1,1],acqsrc[1].tgrid,attrib=:max) 

# check spatial sampling
ds_temp=Models.χ([minimum(model.χvp)],model.vp0,-1)[1]/5.0/freqmax;
ds_max = maximum([model.mgrid.δx, model.mgrid.δz])
all(ds_max .> ds_temp) ? 
		error(string("spatial sampling\t",ds_max,"\ndecrease spatial sampling below:\t",ds_temp)) :
		verbose ? println("spatial sampling can be as high as:\t",ds_temp) : nothing 

# check time sampling
ds_min = minimum([model.mgrid.δx, model.mgrid.δz])
dt_temp=0.5*ds_min/Models.χ([(maximum(model.χvp))],model.vp0,-1)[1]
all(tgridmod.δx .> dt_temp) ? 
		error(string("time sampling\t",tgridmod.δx,"\ndecrease time sampling below:\t",dt_temp)) :
		verbose ? println("time sampling can be as high as:\t",dt_temp) : nothing



#! no modeling if source wavelet is zero
#if(maxval(abs(src_wavelets)) .lt. tiny(rzero_de)) then
#        return
#endif

# all the propagating wavefield should have same sources, receivers, ? check that?

# check dimension of model and model0

# check if all sources are receivers are inside model

length(acqgeom) != npropwav ? error("acqgeom size") : nothing
length(acqsrc) != npropwav ? error("acqsrc size") : nothing
any([getfield(acqgeom[ip],:nss) != getfield(acqsrc[ip],:nss) for ip=1:npropwav])  ? error("different supersources") : nothing
any([getfield(acqgeom[ip],:ns) != getfield(acqsrc[ip],:ns) for ip=1:npropwav])  ? error("different sources") : nothing

# same values of these of all nprop, but values can be diff
src_nsmul = maximum(acqgeom[1].ns);
src_nseq = acqgeom[1].nss;
src_nfield = acqsrc[1].nfield

# create acquisition geometry with each source shooting 
# at every unique receiver position
acqgeom_urpos = [Acquisition.Geom_get(acqgeom[i],:geomurpos) for i=1:npropwav];
recv_n = acqgeom_urpos[1].nr[1] # same for all sources

if(verbose)
	println(string("number of receivers:\t",recv_n))	
	println(string("number of sources:\t",src_nsmul))	
	println(string("number of super sources:\t",src_nseq))	
end

recv_out = zeros(tgridmod.nx*recv_n*recv_nfield*npropwav*src_nseq)

# extend models in the PML layers
exmodel = Models.Seismic_pad_trun(model);
exmodel0 = Models.Seismic_pad_trun(model0);

# gradient outputs
grad_modtt = zeros(exmodel.mgrid.nz, exmodel.mgrid.nx,src_nseq) 
grad_modrr = zeros(exmodel.mgrid.nz, exmodel.mgrid.nx,src_nseq) 

# border coordinates
border_z, border_x, border_n = Grid.M2D_border(model.mgrid, 3, :outer)
border_out = zeros(border_n,tgridmod.nx,src_nseq) 
p_out = zeros(exmodel.mgrid.nz+2,exmodel.mgrid.nx+2,3,src_nseq,2)

border_out_flag = boundary_save_flag;

# saving 3 fields on the border
if(boundary_in == nothing) 
	border_in_flag = false
	boundary_in = (zeros(border_n,tgridmod.nx,src_nseq), 
	      zeros(exmodel.mgrid.nz+2,exmodel.mgrid.nx+2,3,src_nseq,2))
else	
	border_in_flag = true
end

ccall( (:fdtd_mod, F90libs.fdtd), Void,
      (Ptr{UInt8}, Ref{Int64},       
       Ptr{Float64}, Ptr{Float64},
       Ptr{Float64}, Ptr{Float64},
       Ref{Int64}, Ref{Int64},       Ref{Float64}, Ref{Float64},
       Ref{Float64}, Ref{Float64},   Ref{Int64}, Ptr{UInt8},
       Ref{Int64}, Ref{Float64},     Ref{Int64}, Ptr{Float64},
       Ref{Int64}, Ref{Int64}, Ref{Int64},
       Ptr{Float64}, Ptr{Float64},
       Ptr{Float64},
       Ref{Int64},  Ref{Int64},
       Ptr{Float64}, Ptr{Float64},
       Ptr{Float64}, Ptr{Float64}, Ptr{UInt8},
       Ref{Int64}, Ptr{Float64}, Ptr{Float64},
       Ref{Int64}, Ptr{Float64}, 
       Ref{Int64}, Ptr{Float64},
       Ptr{Float64}, Ptr{Float64},
       Ref{Int64},
       Ptr{Float64}, Ptr{Float64},
       Ref{Int64}
       ),
      jobname, npropwav,     
      Models.Seismic_get(exmodel, :KI), Models.Seismic_get(exmodel, :ρI),
      Models.Seismic_get(exmodel0, :KI), Models.Seismic_get(exmodel0, :ρI),
      exmodel.mgrid.nx, exmodel.mgrid.nz,    exmodel.mgrid.δx, exmodel.mgrid.δz,
      exmodel.mgrid.x, exmodel.mgrid.z,      model.mgrid.npml-5, # reduce npml by one, see fdtd.f90
      abs_trbl, 
      tgridmod.nx, tgridmod.δx,    acqsrc[1].tgrid.nx, Acquisition.Src_getvec(acqsrc,:wav),
      src_nseq, src_nsmul, src_nfield,
      Acquisition.Geom_getvec(acqgeom,:sx), Acquisition.Geom_getvec(acqgeom,:sz),
      src_flags, 
      recv_n, recv_nfield,
      Acquisition.Geom_getvec(acqgeom_urpos,:rx), Acquisition.Geom_getvec(acqgeom_urpos,:rz),
      recv_out, recv_flags,  prop_flags,
      border_n, border_x, border_z,
      border_in_flag,boundary_in[1], 
      border_out_flag,border_out,
      boundary_in[2], p_out, 
      grad_out_flag,
      grad_modtt, grad_modrr,
      born_flag
     )

# check if ccall return zeros
isapprox(maximum(abs(recv_out)),0.0) && warn("recv_out are zeros")

# summing over all the sources
grad_modtt = Models.pad_trun(squeeze(sum(grad_modtt,3),3),model.mgrid.npml,-1);
grad_modrr = Models.pad_trun(squeeze(sum(grad_modrr,3),3),model.mgrid.npml,-1);

# for gradient model
gmodel = Models.Seismic(model.vp0, model.vs0, model.ρ0,
			Models.χg(grad_modtt,Models.Seismic_get(model, :K0I)),
			zeros(grad_modtt),
			Models.χg(grad_modrr,Models.Seismic_get(model, :ρ0I)),
			model.mgrid
			) 

# return after forming a vector and resampling
nd = src_nseq*tgridmod.nx*recv_n*recv_nfield; # number of samples for each iprop
return [Data.TD_resamp(
		       Data.TD_urpos(
		       reshape(recv_out[1+(iprop-1)*nd : iprop*nd],
		 	tgridmod.nx,recv_n,src_nseq,recv_nfield),
			recv_nfield,
			tgridmod, acqgeom[iprop],
			acqgeom_urpos[iprop].nr[1],
			(acqgeom_urpos[iprop].rz[1], acqgeom_urpos[iprop].rx[1])
			), tgrid) for iprop in 1:npropwav], 
		(border_out[:,end:-1:1,:], p_out[:,:,:,:,end:-1:1]),
		gmodel

# return without resampling for testing
#return [Data.TD(reshape(recv_out[1+(iprop-1)*nd : iprop*nd],tgridmod.nx,recv_n,src_nseq),
#		       tgridmod, acqgeom[1]) for iprop in 1:npropwav]
end

end # module
