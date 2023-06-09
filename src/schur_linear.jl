import MadNLP: AbstractOptions, AbstractLinearSolver, MadNLPLogger, SubVector, 
default_linear_solver, default_dense_solver, default_options, get_cscsy_view, get_csc_view,
factorize!, solve!, mul!, inertia, is_inertia, introduce, improve!

Base.@kwdef mutable struct SchurOptions{S<:AbstractLinearSolver,D<:AbstractLinearSolver} <: AbstractOptions
    partition::Vector{Int}=Vector{Int}()
    subproblem_solver::Type{S}=default_linear_solver()
    subproblem_solver_options::AbstractOptions=default_options(subproblem_solver)
    dense_solver::Type{D}=default_dense_solver()
    dense_solver_options::AbstractOptions=default_options(dense_solver)
end

mutable struct SolverWorker{T,S<:AbstractLinearSolver{T}}
    V::Vector{Int}
    V_0_nz::Vector{Int}
    csc::SparseMatrixCSC{T,Int32}
    csc_view::SubVector{T}
    compl::SparseMatrixCSC{T,Int32}
    compl_view::SubVector{T}
    linear_solver::S
    w::Vector{T}
end
function SolverWorker(
    partition::Vector{Int}, 
    V_0::Vector{Int},
    csc::SparseMatrixCSC{T},
    inds::Vector{Int},
    k::Int,
    subproblem_solver::Type{S},
    options::AbstractOptions,
    logger::MadNLPLogger
) where T where S <: AbstractLinearSolver

    # local partition indices
    V = findall(partition.==k)

    # TODO: document these functions
    csc_k, csc_k_view = get_cscsy_view(csc, V, inds=inds)
    compl, compl_view = get_csc_view(csc, V, V_0, inds=inds)
    V_0_nz = findnz(compl.colptr)

    # sub-problem linear solver
    linear_solver = subproblem_solver(csc_k; opt=options, logger=logger)
    
    # sub-problem step
    w = Vector{T}(undef,csc_k.n)

    return SolverWorker(V, V_0_nz, csc_k, csc_k_view, compl, compl_view, linear_solver, w)
end

mutable struct SchurLinearSolver{T,D<:AbstractLinearSolver{T}} <: AbstractLinearSolver{T}
    csc::SparseMatrixCSC{T,Int32}
    inds::Vector{Int}

    # partition of primal-dual system
    partitions::Vector{Int}
    num_partitions::Int

    # schur complement matrix
    schur::Matrix{T}
    colors::Vector{Vector{Int64}}

    # first stage elements
    dense_solver::D
    V_0::Vector{Int}
    csc_0::SparseMatrixCSC{T,Int32}
    csc_0_view::SubVector{T}
    w_0::Vector{T}
    
    # sub-problem workers
    sws::Vector{SolverWorker}
    opt::SchurOptions
    logger::MadNLPLogger
end

function SchurLinearSolver(
	csc::SparseMatrixCSC{T};
    opt=SchurOptions(),
	logger=MadNLPLogger()
) where T

    if string(opt.subproblem_solver) == "MadNLP.Mumps"
        @warn(logger,"When Mumps is used as a subproblem solver, Schur is run in serial.")
        @warn(logger,"To use parallelized Schur, use Ma27 or Ma57.")
    end

    @assert !(isempty(opt.partition))

    # non-zeros in KKT
    inds = collect(1:nnz(csc))
    num_partitions = length(unique(opt.partition))-1 #do not count 0 as a partition

    # first stage indices
    V_0  = findall(opt.partition.==0)
    colors = get_colors(length(V_0), num_partitions)

    # KKT first-stage
    csc_0, csc_0_view = get_cscsy_view(csc, V_0, inds=inds)
    schur_matrix = Matrix{T}(undef, length(V_0), length(V_0))

    # first-stage primal-dual step
    w_0 = Vector{Float64}(undef, length(V_0))

    # solver-workers
    sws = Vector{SolverWorker}(undef, num_partitions)

    Threads.@threads for k=1:num_partitions
        sws[k] = SolverWorker(
            opt.partition,
            V_0,
            csc,
            inds,
            k,
            opt.subproblem_solver,
            opt.subproblem_solver_options,
            logger
        )
    end

    # dense system solver
    dense_solver = opt.dense_solver(schur_matrix; opt=opt.dense_solver_options, logger=logger)

    return SchurLinearSolver(
        csc, 
        inds,
        opt.partition,
        num_partitions,
        schur_matrix,
        colors,
        dense_solver,
        V_0,
        csc_0,
        csc_0_view,
        w_0,
        sws,
        opt,
        logger
    )
end

get_colors(n0::Int, K::Int) = [findall((x)->mod(x-1,K)+1==k,1:n0) for k=1:K]

function findnz(colptr)
    nz = Int[]
    for j=1:length(colptr)-1
        colptr[j]==colptr[j+1] || push!(nz,j)
    end
    return nz
end

function factorize!(M::SchurLinearSolver)
    M.schur .= 0.
    M.csc_0.nzval .= M.csc_0_view
    M.schur .= M.csc_0
    Threads.@threads for sw in M.sws
        sw.csc.nzval .= sw.csc_view
        sw.compl.nzval .= sw.compl_view
        factorize!(sw.linear_solver)
    end

    # NOTE: asynchronous multithreading doesn't work here
    for q = 1:length(M.colors)
        Threads.@threads for k = 1:length(M.sws)
            for j = M.colors[mod(q+k-1, length(M.sws))+1] # each subproblem works on a different color
                factorize_worker!(j, M.sws[k], M.schur)
            end
        end
    end
    factorize!(M.dense_solver)
    return M
end

function factorize_worker!(j, sw, schur)
    j in sw.V_0_nz || return
    sw.w.= view(sw.compl, :, j)
    solve!(sw.linear_solver, sw.w)
    mul!(view(schur, :, j), sw.compl', sw.w, -1., 1.)
end

function solve!(M::SchurLinearSolver, x::AbstractVector{T}) where T
    M.w_0 .= view(x, M.V_0)
    Threads.@threads for sw in M.sws
        sw.w.=view(x, sw.V)
        solve!(sw.linear_solver, sw.w)
    end
    for sw in M.sws
        mul!(M.w_0, sw.compl', sw.w, -1., 1.)
    end
    solve!(M.dense_solver, M.w_0)
    view(x, M.V_0) .= M.w_0
    Threads.@threads for sw in M.sws
        x_view = view(x, sw.V)
        sw.w.= x_view
        mul!(sw.w, sw.compl, M.w_0, 1., 1.)
        solve!(sw.linear_solver, sw.w)
        x_view.=sw.w
    end
    return x
end

is_inertia(M::SchurLinearSolver) = is_inertia(M.dense_solver) && is_inertia(M.sws[1].linear_solver)

function inertia(M::SchurLinearSolver)
    numpos,numzero,numneg = inertia(M.dense_solver)
    for k=1:M.opt.schur_num_parts
        _numpos,_numzero,_numneg =  inertia(M.sws[k].linear_solver)
        numpos += _numpos
        numzero += _numzero
        numneg += _numneg
    end
    return (numpos,numzero,numneg)
end

function improve!(M::SchurLinearSolver)
    for sw in M.sws
        improve!(sw.linear_solver) || return false
    end
    return true
end

function introduce(M::SchurLinearSolver)
    sw = M.sws[1]
    return "schur equipped with dense solver "*introduce(M.dense_solver)*" and sparse solver "*introduce(sw.linear_solver)
end

MadNLP.input_type(::Type{SchurLinearSolver}) = :csc
MadNLP.default_options(::Type{SchurLinearSolver}) = SchurOptions()
MadNLP.is_supported(::Type{SchurLinearSolver},::Type{Float32}) = true
MadNLP.is_supported(::Type{SchurLinearSolver},::Type{Float64}) = true