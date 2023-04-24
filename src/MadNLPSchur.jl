module MadNLPSchur

using DataStructures, SparseArrays
using NLPModels
using MadNLP

using MathOptInterface
const MOI = MathOptInterface
const MOIU = MOI.Utilities

using GraphOptInterface
const GOI = GraphOptInterface

include("utils.jl")

include("edge_model.jl")

include("block_nlp_evaluator.jl")

include("schur_optimizer.jl")

include("schur_linear.jl")

end
