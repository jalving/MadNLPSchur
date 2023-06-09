"""
    SchurOptimizer()

Create a new MadNLP Schur optimizer.
"""
mutable struct SchurOptimizer <: GOI.AbstractGraphOptimizer
    solver::Union{Nothing,MadNLP.MadNLPSolver}
    nlp::Union{Nothing,NLPModels.AbstractNLPModel}
    result::Union{Nothing,MadNLP.MadNLPExecutionStats{Float64}}
    name::String
    invalid_model::Bool
    silent::Bool
    options::Dict{Symbol,Any}
    solve_time::Float64
    solve_iterations::Int
    sense::MOI.OptimizationSense
    graph::GOI.Graph
end

function SchurOptimizer(graph::GOI.Graph; kwargs...)
    option_dict = Dict{Symbol, Any}()
    for (name, value) in kwargs
        option_dict[name] = value
    end
    return SchurOptimizer(
        nothing,
        nothing,
        nothing,
        "",
        false,
        false,
        option_dict,
        NaN,
        0,
        MOI.FEASIBILITY_SENSE,
        graph
    )
end

function MOI.supports(optimizer::SchurOptimizer, ::GOI.GraphStructure)
    return true
end

function MOI.get(optimizer::SchurOptimizer, ::GOI.GraphStructure)
    return optimizer.graph
end

MOI.get(::SchurOptimizer, ::MOI.SolverName) = "MadNLP.Schur"

### MOI.Name

MOI.supports(::SchurOptimizer, ::MOI.Name) = true

MOI.supports(::SchurOptimizer, ::MOI.ObjectiveSense) = true

function MOI.set(
    model::SchurOptimizer,
    ::MOI.ObjectiveSense,
    sense::MOI.OptimizationSense,
)
    model.sense = sense
    model.solver = nothing
    return
end

MOI.get(model::SchurOptimizer, ::MOI.ObjectiveSense) = model.sense

function MOI.set(model::SchurOptimizer, ::MOI.Name, value::String)
    model.name = value
    return
end

MOI.get(model::SchurOptimizer, ::MOI.Name) = model.name

### MOI.Silent

MOI.supports(::SchurOptimizer, ::MOI.Silent) = true

function MOI.set(model::SchurOptimizer, ::MOI.Silent, value)
    model.silent = value
    return
end

MOI.get(model::SchurOptimizer, ::MOI.Silent) = model.silent

### MOI.TimeLimitSec

MOI.supports(::SchurOptimizer, ::MOI.TimeLimitSec) = true

function MOI.set(model::SchurOptimizer, ::MOI.TimeLimitSec, value::Real)
    MOI.set(model, MOI.RawSchurOptimizerAttribute("max_cpu_time"), Float64(value))
    return
end

function MOI.set(model::SchurOptimizer, ::MOI.TimeLimitSec, ::Nothing)
    delete!(model.options, "max_cpu_time")
    return
end

function MOI.get(model::SchurOptimizer, ::MOI.TimeLimitSec)
    return get(model.options, "max_cpu_time", nothing)
end

### MOI.RawOptimizerAttribute

MOI.supports(::SchurOptimizer, ::MOI.RawOptimizerAttribute) = true

function MOI.set(model::SchurOptimizer, p::MOI.RawOptimizerAttribute, value)
    model.options[Symbol(p.name)] = value
    return
end

function MOI.get(model::SchurOptimizer, p::MOI.RawOptimizerAttribute)
    if !haskey(model.options, p.name)
        error("RawParameter with name $(p.name) is not set.")
    end
    return model.options[p.name]
end

### NLP Models Wrapper

struct BlockNLPModel{T} <: NLPModels.AbstractNLPModel{T,Vector{T}}
    meta::NLPModels.NLPModelMeta{T, Vector{T}}
    optimizer::SchurOptimizer
    evaluator::BlockNLPEvaluator
    counters::NLPModels.Counters
end

function BlockNLPModel(optimizer::SchurOptimizer)
    # initialize
    block_evaluator = BlockNLPEvaluator(optimizer.graph)
    MOI.initialize(block_evaluator, [:Grad, :Hess, :Jac])
    block = optimizer.graph.block
    block_data = block_evaluator.block_data

    # primals, lower, upper bounds
    nvar = block_data.num_variables
    x0 = Vector{Float64}(undef,nvar) # primal start
    x_lower = Vector{Float64}(undef,nvar)
    x_upper = Vector{Float64}(undef,nvar)
    _fill_variable_info!(block, block_data, x0, x_lower, x_upper)

    # duals, constraints lower & upper bounds
    ncon = block_data.num_constraints
    y0 = Vector{Float64}(undef, ncon) # dual start
    c_lower = Vector{Float64}(undef, ncon)
    c_upper = Vector{Float64}(undef, ncon)
    _fill_constraint_info!(block, block_data, y0, c_lower, c_upper)

    # Sparsity
    nnzh = block_data.nnz_hess
    nnzj = block_data.nnz_jac

    optimizer.options[:jacobian_constant], optimizer.options[:hessian_constant] = false, false
    optimizer.options[:dual_initialized] = !iszero(y0)

    return BlockNLPModel(
        NLPModelMeta(
            nvar,
            x0 = x0,
            lvar = x_lower,
            uvar = x_upper,
            ncon = ncon,
            y0 = y0,
            lcon = c_lower,
            ucon = c_upper,
            nnzj = nnzj,
            nnzh = nnzh,
            minimize = optimizer.sense == MOI.MIN_SENSE
        ),
        optimizer,
        block_evaluator,
        NLPModels.Counters()
    )
end

NLPModels.obj(nlp::BlockNLPModel, x::Vector{Float64}) = MOI.eval_objective(nlp.evaluator, x)

function NLPModels.grad!(nlp::BlockNLPModel, x::Vector{Float64}, f::Vector{Float64})
    MOI.eval_objective_gradient(nlp.evaluator, f, x)
end

function NLPModels.cons!(nlp::BlockNLPModel, x::Vector{Float64}, c::Vector{Float64})
    MOI.eval_constraint(nlp.evaluator, c, x)
end

function NLPModels.jac_coord!(nlp::BlockNLPModel, x::Vector{Float64}, jac::Vector{Float64})
    MOI.eval_constraint_jacobian(nlp.evaluator, jac, x)
end

function NLPModels.hess_coord!(
    nlp::BlockNLPModel, 
    x::Vector{Float64},
    l::Vector{Float64},
    hess::Vector{Float64};
    obj_weight::Float64=1.
)
    MOI.eval_hessian_lagrangian(nlp.evaluator, hess, x, obj_weight, l)
end

function NLPModels.hess_structure!(nlp::BlockNLPModel, I::AbstractVector{T}, J::AbstractVector{T}) where T
    cnt = 1
    for (row, col) in MOI.hessian_lagrangian_structure(nlp.evaluator)
        I[cnt], J[cnt] = row, col
        cnt += 1
    end
end

function NLPModels.jac_structure!(nlp::BlockNLPModel, I::AbstractVector{T}, J::AbstractVector{T}) where T
    cnt = 1
    for (row, col) in  MOI.jacobian_structure(nlp.evaluator)
        I[cnt], J[cnt] = row, col
        cnt += 1
    end
end

# populate variable info for NLPModels wrapper
function _fill_variable_info!(block::GOI.Block, block_data::BlockData, x0, x_lower, x_upper)
    # loop through each node
    for node in block.nodes
        ninds = block_data.node_column_dict[node.index]
        x0_node = Vector{Float64}(undef, _num_variables(node))
        for i = 1:_num_variables(node)
            # if node.model.variable_primal_start[i] !== nothing
            if MOI.get(node, MOI.VariablePrimalStart(), MOI.VariableIndex(i)) !== nothing
                x0_node[i] = MOI.get(node, MOI.VariablePrimalStart(), MOI.VariableIndex(i))
            else
                x0_node[i] = clamp(0, node.variables.lower[i], node.variables.upper[i])
            end
        end
        x0[ninds] .= x0_node
        x_lower[ninds] .= node.variables.lower
        x_upper[ninds] .= node.variables.upper
    end

    # recursively call sub-blocks
    for sub_block in block.sub_blocks
        sub_block_data = block_data.sub_block_dict[sub_block.index]
        _fill_variable_info!(sub_block, sub_block_data, x0, x_lower, x_upper)
    end
    return
end

_dual_start(::EdgeModel, ::Nothing, ::Int=1) = 0.0

_dual_start(model::EdgeModel, value::Real, scale::Int=1) = value*scale

# populate constraint info for NLPModels wrapper
function _fill_constraint_info!(block::GOI.Block, block_data::BlockData, y0, c_lower, c_upper)
    # loop through each edge
    for edge in block.edges
        minds = block_data.edge_index_dict[edge.index].row_indices
        edge_model = block_data.edge_model_dict[edge.index]
        g_L = copy(edge_model.qp_data.g_L)
        g_U = copy(edge_model.qp_data.g_U)

        for bound in edge_model.nlp_data.constraint_bounds
            push!(g_L, bound.lower)
            push!(g_U, bound.upper)
        end
        c_lower[minds] .= g_L
        c_upper[minds] .= g_U

        # dual start
        y0_edge = Vector{Float64}(undef, _num_constraints(edge))
        for (i, start) in enumerate(edge_model.qp_data.mult_g)
            y0_edge[i] = _dual_start(edge_model, start, -1)
        end
        offset = length(edge_model.qp_data.mult_g)
        if edge_model.nlp_dual_start === nothing
            y0_edge[(offset+1):end] .= 0.0
        else
            for (i, start) in enumerate(edge_model.nlp_dual_start::Vector{Float64})
                y0_edge[offset+i] = _dual_start(model, start, -1)
            end
        end
        y0[minds] .= y0_edge
    end

    # recursively call sub-blocks
    for sub_block in block.sub_blocks
        sub_block_data = block_data.sub_block_dict[sub_block.index]
        _fill_constraint_info!(sub_block, sub_block_data, y0, c_lower, c_upper)
    end
    return
end

### MOI.optimize!

function MOI.optimize!(optimizer::SchurOptimizer)
    optimizer.nlp = BlockNLPModel(optimizer)
    if optimizer.silent
        optimizer.options[:print_level] = MadNLP.ERROR
    end

    # get block partitions from block structure
    partition = get_partition_vector(optimizer.nlp)
    optimizer.solver = MadNLP.MadNLPSolver(
        optimizer.nlp;
        linear_solver=SchurLinearSolver,
        partition=partition,
        optimizer.options...
    )
    optimizer.result = solve!(optimizer.solver)
    optimizer.solve_time = optimizer.solver.cnt.total_time
    optimizer.solve_iterations = optimizer.solver.cnt.k
    return
end

### SchurOptimizer supports up to two-level partition

function get_partition_vector(nlp::BlockNLPModel)
    if isempty(nlp.optimizer.graph.block.sub_blocks)
        partition = _get_one_level_partition(nlp)
    else
        partition = _get_two_level_partition(nlp)
    end
    return partition
end

# the nodes are the 'blocks' in this case
function _get_one_level_partition(nlp::BlockNLPModel)
    block = nlp.optimizer.graph.block
    block_data = nlp.evaluator.block_data
    num_var = nlp.meta.nvar
    num_con = nlp.meta.ncon
    ind_ineq = findall(get_lcon(nlp).!=get_ucon(nlp))

    columns = Vector{Int}(undef, num_var)
    rows = Vector{Int}(undef, num_con)

    for node in block.nodes
        node_columns = block_data.node_column_dict[node.index]
        columns[node_columns] .= node.index
    end

    for edge in GOI.self_edges(block)
        node_index = first(edge.index.vertices)
        edge_rows = block_data.edge_index_dict[edge.index].row_indices
        rows[edge_rows] .= node_index
    end

    for edge in GOI.linking_edges(block)
        edge_rows = block_data.edge_index_dict[edge.index].row_indices
        rows[edge_rows] .= 0

        # linked variables are moved to 0 partition
        edge_columns = block_data.edge_index_dict[edge.index].column_indices
        columns[edge_columns] .= 0
    end

    # get inequality partitions
    slacks = rows[ind_ineq]
    partition = [columns; slacks; rows]
    return partition
end

# the sub-blocks are the 'blocks' in this case
function _get_two_level_partition(nlp::BlockNLPModel)
    block = nlp.optimizer.graph.block
    block_data = nlp.evaluator.block_data
    num_var = nlp.meta.nvar
    num_con = nlp.meta.ncon
    ind_ineq = findall(get_lcon(nlp).!=get_ucon(nlp))

    columns = Vector{Int}(undef, num_var)
    rows = Vector{Int}(undef, num_con)

    # all columns on root block are partition 0
    for node in block.nodes
        node_columns = block_data.node_column_dict[node.index]
        columns[node_columns] .= 0
    end

    # we only support one level of hierarchy, so we assume sub-blocks are entire paritions
    for sub_block in block.sub_blocks
        sb_data = block_data.sub_block_dict[sub_block.index]
        block_node_columns = sb_data.all_columns
        block_edge_columns = sb_data.all_rows
        columns[block_node_columns] .= sub_block.index.value
        rows[block_edge_columns] .= sub_block.index.value
    end

    # set linking rows and columns on children to root partition index
    for edge in block.edges
        # set child connection columns to 0. redundant, but catches everything.
        edge_columns = block_data.edge_index_dict[edge.index].column_indices
        columns[edge_columns] .= 0

        edge_rows = block_data.edge_index_dict[edge.index].row_indices
        rows[edge_rows] .= 0
    end

    slacks = rows[ind_ineq]
    partition = [columns; slacks; rows]
    return partition
end