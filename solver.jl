using MPI
using WriteVTK
using Lux, LuxCUDA
using LinearAlgebra, CUDA
using JLD2, JSON, HDF5

CUDA.allowscalar(false)
include("split.jl")
include("schemes.jl")
include("viscous.jl")
include("boundary.jl")
include("utils.jl")
include("div.jl")
include("reaction.jl")
include("ML.jl")
include("mpi.jl")

function flowAdvance(U, Q, Fp, Fm, Fx, Fy, Fz, Fv_x, Fv_y, Fv_z, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, dt, ϕ, λ, μ, Fh, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock fluxSplit(Q, Fp, Fm, dξdx, dξdy, dξdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_x(Fx, ϕ, Fp, Fm, Ncons, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock fluxSplit(Q, Fp, Fm, dηdx, dηdy, dηdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_y(Fy, ϕ, Fp, Fm, Ncons, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock fluxSplit(Q, Fp, Fm, dζdx, dζdy, dζdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_z(Fz, ϕ, Fp, Fm, Ncons, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock viscousFlux(Fv_x, Fv_y, Fv_z, Q, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, λ, μ, Fh, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock div(U, Fx, Fy, Fz, Fv_x, Fv_y, Fv_z, dt, J, consts)
end

function specAdvance(ρi, Q, Yi, Fp_i, Fm_i, Fx_i, Fy_i, Fz_i, Fd_x, Fd_y, Fd_z, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, dt, ϕ, D, Fh, thermo, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock split(ρi, Q, Fp_i, Fm_i, dξdx, dξdy, dξdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_x(Fx_i, ϕ, Fp_i, Fm_i, Nspecs, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock split(ρi, Q, Fp_i, Fm_i, dηdx, dηdy, dηdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_y(Fy_i, ϕ, Fp_i, Fm_i, Nspecs, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock split(ρi, Q, Fp_i, Fm_i, dζdx, dζdy, dζdz)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock WENO_z(Fz_i, ϕ, Fp_i, Fm_i, Nspecs, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock specViscousFlux(Fd_x, Fd_y, Fd_z, Q, Yi, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, D, Fh, thermo, consts)

    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock divSpecs(ρi, Fx_i, Fy_i, Fz_i, Fd_x, Fd_y, Fd_z, dt, J, consts)
end

function time_step(thermo, consts)
    MPI.Init()

    comm = MPI.COMM_WORLD
    rank = MPI.Comm_rank(comm)
    nGPU = MPI.Comm_size(comm)
    if nGPU != Nprocs && rank == 0
        printstyled("Oops, nGPU ≠ $Nprocs\n", color=:red)
        flush(stdout)
        return
    end

    Nx_tot = Nxp+2*NG
    Ny_tot = Ny+2*NG
    Nz_tot = Nz+2*NG

    # global indices
    lo = rank*Nxp+1
    hi = (rank+1)*Nxp+2*NG
    # lo_ng = rank*Nxp+NG+1
    # hi_ng = (rank+1)*Nxp+NG

    if restart[1:3] == "chk"
        if rank == 0
            printstyled("Restart\n", color=:red)
        end
        fid = h5open(restart, "r", comm, MPI.Info())
        Q_h = fid["Q_h"][:, :, :, :, rank+1]
        ρi_h = fid["ρi_h"][:, :, :, :, rank+1]
        close(fid)
    else
        Q_h = zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nprim)
        ρi_h = zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)
        initialize(Q_h, ρi_h, consts)
    end
    
    # load mesh metrics
    fid = h5open("metrics.h5", "r", comm, MPI.Info())
    dξdx_h = fid["dξdx"][lo:hi, :, :]
    dξdy_h = fid["dξdy"][lo:hi, :, :]
    dξdz_h = fid["dξdz"][lo:hi, :, :]
    dηdx_h = fid["dηdx"][lo:hi, :, :]
    dηdy_h = fid["dηdy"][lo:hi, :, :]
    dηdz_h = fid["dηdz"][lo:hi, :, :]
    dζdx_h = fid["dζdx"][lo:hi, :, :]
    dζdy_h = fid["dζdy"][lo:hi, :, :]
    dζdz_h = fid["dζdz"][lo:hi, :, :]

    J_h = fid["J"][lo:hi, :, :] 
    x_h = fid["x"][lo:hi, :, :] 
    y_h = fid["y"][lo:hi, :, :] 
    z_h = fid["z"][lo:hi, :, :]
    close(fid)

    # move to device memory
    dξdx = CuArray(dξdx_h)
    dξdy = CuArray(dξdy_h)
    dξdz = CuArray(dξdz_h)
    dηdx = CuArray(dηdx_h)
    dηdy = CuArray(dηdy_h)
    dηdz = CuArray(dηdz_h)
    dζdx = CuArray(dζdx_h)
    dζdy = CuArray(dζdy_h)
    dζdz = CuArray(dζdz_h)
    J = CuArray(J_h)

    # allocate on device
    Q  =   CuArray(Q_h)
    ρi =   CuArray(ρi_h)
    Yi =   CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)
    ϕ  =   CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot) # Shock sensor
    U  =   CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Ncons)
    Fp =   CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Ncons)
    Fm =   CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Ncons)
    Fx =   CUDA.zeros(Float64, Nxp+1, Ny, Nz, Ncons)
    Fy =   CUDA.zeros(Float64, Nxp, Ny+1, Nz, Ncons)
    Fz =   CUDA.zeros(Float64, Nxp, Ny, Nz+1, Ncons)
    Fv_x = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, 4)
    Fv_y = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, 4)
    Fv_z = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, 4)

    Fp_i = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)
    Fm_i = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)
    Fx_i = CUDA.zeros(Float64, Nxp+1, Ny, Nz, Nspecs) # species advection
    Fy_i = CUDA.zeros(Float64, Nxp, Ny+1, Nz, Nspecs) # species advection
    Fz_i = CUDA.zeros(Float64, Nxp, Ny, Nz+1, Nspecs) # species advection
    Fd_x = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, Nspecs) # species diffusion
    Fd_y = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, Nspecs) # species diffusion
    Fd_z = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, Nspecs) # species diffusion
    Fh = CUDA.zeros(Float64, Nxp+4, Ny+4, Nz+4, 3) # enthalpy diffusion

    μ = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot)
    λ = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot)
    D = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)

    μi = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs) # tmp for both μ and λ
    Xi = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs)
    Dij = CUDA.zeros(Float64, Nx_tot, Ny_tot, Nz_tot, Nspecs*Nspecs) # tmp for N*N matricies
    
    Un = copy(U)
    ρn = copy(ρi)

    # initial
    @cuda threads=nthreads blocks=nblock prim2c(U, Q)
    fillGhost(Q, U, ρi, Yi, thermo, rank)
    fillSpec(ρi)
    exchange_ghost(Q, Nprim, rank, comm)
    exchange_ghost(ρi, Nspecs, rank, comm)
    MPI.Barrier(comm)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock getY(Yi, ρi, Q)
    @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock prim2c(U, Q)

    if reaction
        @load "./NN/Air/luxmodel.jld2" model ps st

        ps = ps |> gpu_device()

        w1 = ps[1].weight
        b1 = ps[1].bias
        w2 = ps[2].weight
        b2 = ps[2].bias
        w3 = ps[3].weight
        b3 = ps[3].bias

        Y1 = CUDA.ones(Float32, 64, Nxp*Ny*Nz)
        Y2 = CUDA.ones(Float32, 256, Nxp*Ny*Nz)
        yt_pred = CUDA.ones(Float32, Nspecs+1, Nxp*Ny*Nz)

        j = JSON.parsefile("./NN/Air/norm.json")
        lambda = j["lambda"]
        inputs_mean = CuArray(convert(Vector{Float32}, j["inputs_mean"]))
        inputs_std =  CuArray(convert(Vector{Float32}, j["inputs_std"]))
        labels_mean = CuArray(convert(Vector{Float32}, j["labels_mean"]))
        labels_std =  CuArray(convert(Vector{Float32}, j["labels_std"]))

        inputs = CUDA.zeros(Float32, Nspecs+2, Nxp*Ny*Nz)
        inputs_norm = CUDA.zeros(Float32, Nspecs+2, Nxp*Ny*Nz)

        dt2 = dt/2
    end

    for tt = 1:ceil(Int, Time/dt)
        if tt % 10 == 0
            if rank == 0
                printstyled("Step: ", color=:cyan)
                print("$tt")
                printstyled("\tTime: ", color=:blue)
                println("$(tt*dt)")
                flush(stdout)
            end
            if any(isnan, U)
                printstyled("Oops, NaN detected\n", color=:red)
                return
            end
        end

        if reaction
            # Reaction Step
            @cuda threads=nthreads blocks=nblock pre_input(inputs, inputs_norm, Q, Yi, lambda, inputs_mean, inputs_std)
            evalModel(Y1, Y2, yt_pred, w1, w2, w3, b1, b2, b3, inputs_norm)
            @. yt_pred = yt_pred * labels_std + labels_mean
            @cuda threads=nthreads blocks=nblock post_predict(yt_pred, inputs, U, Q, ρi, dt2, lambda, thermo)
            @cuda threads=nthreads blocks=nblock c2Prim(U, Q, ρi, thermo)
            fillGhost(Q, U, ρi, Yi, thermo, rank)
            fillSpec(ρi)
            exchange_ghost(Q, Nprim, rank, comm)
            exchange_ghost(ρi, Nspecs, rank, comm)
            MPI.Barrier(comm)
            @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock getY(Yi, ρi, Q)
        end

        # RK3
        for KRK = 1:3
            if KRK == 1
                @cuda threads=nthreads blocks=nblock copyOld(Un, U, Ncons)
                @cuda threads=nthreads blocks=nblock copyOld(ρn, ρi, Nspecs)
            end

            @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock mixture(Q, Yi, Xi, μi, Dij, λ, μ, D, thermo)
            @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock shockSensor(ϕ, Q)
            specAdvance(ρi, Q, Yi, Fp_i, Fm_i, Fx_i, Fy_i, Fz_i, Fd_x, Fd_y, Fd_z, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, dt, ϕ, D, Fh, thermo, consts)
            flowAdvance(U, Q, Fp, Fm, Fx, Fy, Fz, Fv_x, Fv_y, Fv_z, dξdx, dξdy, dξdz, dηdx, dηdy, dηdz, dζdx, dζdy, dζdz, J, dt, ϕ, λ, μ, Fh, consts)

            if KRK == 2
                @cuda threads=nthreads blocks=nblock linComb(U, Un, Ncons, 0.25, 0.75)
                @cuda threads=nthreads blocks=nblock linComb(ρi, ρn, Nspecs, 0.25, 0.75)
            elseif KRK == 3
                @cuda threads=nthreads blocks=nblock linComb(U, Un, Ncons, 2/3, 1/3)
                @cuda threads=nthreads blocks=nblock linComb(ρi, ρn, Nspecs, 2/3, 1/3)
            end

            @cuda threads=nthreads blocks=nblock c2Prim(U, Q, ρi, thermo)
            fillGhost(Q, U, ρi, Yi, thermo, rank)
            fillSpec(ρi)
            exchange_ghost(Q, Nprim, rank, comm)
            exchange_ghost(ρi, Nspecs, rank, comm)
            MPI.Barrier(comm)
            @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock getY(Yi, ρi, Q)
        end

        if reaction
            # Reaction Step
            @cuda threads=nthreads blocks=nblock pre_input(inputs, inputs_norm, Q, Yi, lambda, inputs_mean, inputs_std)
            evalModel(Y1, Y2, yt_pred, w1, w2, w3, b1, b2, b3, inputs_norm)
            @. yt_pred = yt_pred * labels_std + labels_mean
            @cuda threads=nthreads blocks=nblock post_predict(yt_pred, inputs, U, Q, ρi, dt2, lambda, thermo)
            @cuda threads=nthreads blocks=nblock c2Prim(U, Q, ρi, thermo)
            fillGhost(Q, U, ρi, Yi, thermo, rank)
            fillSpec(ρi)
            exchange_ghost(Q, Nprim, rank, comm)
            exchange_ghost(ρi, Nspecs, rank, comm)
            MPI.Barrier(comm)
            @cuda maxregs=255 fastmath=true threads=nthreads blocks=nblock getY(Yi, ρi, Q)
        end

        # Output
        if tt % step_out == 0 || abs(Time-dt*tt) <= 1e-15
            μ_h = zeros(Float64, Nx_tot, Ny_tot, Nz_tot)
            λ_h = zeros(Float64, Nx_tot, Ny_tot, Nz_tot)
            ϕ_h = zeros(Float64, Nx_tot, Ny_tot, Nz_tot)
            copyto!(Q_h, Q)
            copyto!(ρi_h, ρi)
            copyto!(ϕ_h, ϕ)
            copyto!(μ_h, μ)
            copyto!(λ_h, λ)

            # visualization file, in Float32
            fname::String = string("plt", tt, "-", rank)

            rho = convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 1])
            u =   convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 2])
            v =   convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 3])
            w =   convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 4])
            p =   convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 5])
            T =   convert(Array{Float32, 3}, @view Q_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 6])
        
            YO  = convert(Array{Float32, 3}, @view ρi_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 1])
            YO2 = convert(Array{Float32, 3}, @view ρi_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 2])
            YN  = convert(Array{Float32, 3}, @view ρi_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 3])
            YNO = convert(Array{Float32, 3}, @view ρi_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 4])
            YN2 = convert(Array{Float32, 3}, @view ρi_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG, 5])

            ϕ_ng = convert(Array{Float32, 3}, @view ϕ_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])
            x_ng = convert(Array{Float32, 3}, @view x_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])
            y_ng = convert(Array{Float32, 3}, @view y_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])
            z_ng = convert(Array{Float32, 3}, @view z_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])

            μ_ng = convert(Array{Float32, 3}, @view μ_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])
            λ_ng = convert(Array{Float32, 3}, @view λ_h[1+NG:Nxp+NG, 1+NG:Ny+NG, 1+NG:Nz+NG])

            vtk_grid(fname, x_ng, y_ng, z_ng) do vtk
                vtk["rho"] = rho
                vtk["u"] = u
                vtk["v"] = v
                vtk["w"] = w
                vtk["p"] = p
                vtk["T"] = T
                vtk["phi"] = ϕ_ng
                vtk["YO"] = YO
                vtk["YO2"] = YO2
                vtk["YN"] = YN
                vtk["YNO"] = YNO
                vtk["YN2"] = YN2
                vtk["mu"] = μ_ng
                vtk["lambda"] = λ_ng
            end 

            # restart file, in Float64
            if chk_out
                chkname::String = string("chk", tt, ".h5")
                h5open(chkname, "w", comm, MPI.Info()) do f
                    dset1 = create_dataset(
                        f,
                        "Q_h",
                        datatype(Float64),
                        dataspace(Nx_tot, Ny_tot, Nz_tot, Nprim, Nprocs);
                        chunk=(Nx_tot, Ny_tot, Nz_tot, Nprim, 1),
                        dxpl_mpio=:collective
                    )
                    dset1[:, :, :, :, rank + 1] = Q_h
                    dset2 = create_dataset(
                        f,
                        "ρi_h",
                        datatype(Float64),
                        dataspace(Nx_tot, Ny_tot, Nz_tot, Nspecs, Nprocs);
                        chunk=(Nx_tot, Ny_tot, Nz_tot, Nspecs, 1),
                        dxpl_mpio=:collective
                    )
                    dset2[:, :, :, :, rank + 1] = ρi_h
                end
            end
            
            # release memory
            μ_h = nothing
            λ_h = nothing
            ϕ_h = nothing
        end
    end
    if rank == 0
        println("Done!")
        flush(stdout)
    end
    MPI.Finalize()
    return
end
