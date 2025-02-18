# SPDX-FileCopyrightText: 2023 Christian Willberg <christian.willberg@dlr.de>, Jan-Timo Hesse <jan-timo.hesse@dlr.de>
#
# SPDX-License-Identifier: BSD-3-Clause

module Solver_control

include("../../Support/Parameters/parameter_handling.jl")
include("../../Support/Helpers.jl")
using .Parameter_Handling:
    get_density,
    get_horizon,
    get_solver_name,
    get_model_options,
    get_fem_block,
    get_calculation_options,
    get_angles,
    get_block_names,
    get_solver_params
using .Helpers: find_indices, fastdot
include("../../Models/Model_Factory.jl")
include("Verlet.jl")
include("Static_solver.jl")
include("../BC_manager.jl")
include("../../MPI_communication/MPI_communication.jl")
include("../../FEM/FEM_Factory.jl")
include("../Influence_function.jl")

using .Model_Factory: init_models, read_properties
using .Boundary_conditions: init_BCs
using .Verlet
using .FEM
using .Influence_function
using TimerOutputs

export init
export solver

"""
    init(params::Dict, datamanager::Module)

Initialize the solver

# Arguments
- `params::Dict`: The parameters
- `datamanager::Module`: Datamanager
- `to::TimerOutputs.TimerOutput`: A timer output
# Returns
- `block_nodes::Dict{Int64,Vector{Int64}}`: A dictionary mapping block IDs to collections of nodes.
- `bcs::Dict{Any,Any}`: A dictionary containing boundary conditions.
- `datamanager::Module`: The data manager module that provides access to data fields and properties.
- `solver_options::Dict{String,Any}`: A dictionary containing solver options.
"""
function init(
    params::Dict,
    datamanager::Module,
    to::TimerOutput,
    step_id::Union{Nothing,Int64} = nothing,
)
    solver_options = Dict()
    nnodes = datamanager.get_nnodes()
    num_responder = datamanager.get_num_responder()
    block_ids = datamanager.get_field("Block_Id")
    block_nodes_with_neighbors = get_block_nodes(block_ids, nnodes + num_responder)
    block_nodes = get_block_nodes(block_ids, nnodes)
    block_list = get_block_names(params, block_ids)
    datamanager.set_block_list(block_list)
    density = datamanager.create_constant_node_field("Density", Float64, 1)
    horizon = datamanager.create_constant_node_field("Horizon", Float64, 1)
    if datamanager.fem_active()
        fem_block = datamanager.create_constant_node_field("FEM Block", Bool, 1, false)
        fem_block = set_fem_block(params, block_nodes_with_neighbors, fem_block) # includes the neighbors
    end
    active_nodes = datamanager.create_constant_node_field("Active Nodes", Int64, 1)
    update_nodes = datamanager.create_constant_node_field("Update Nodes", Int64, 1)
    datamanager.create_constant_node_field("Update", Bool, 1, true)
    density = set_density(params, block_nodes_with_neighbors, density) # includes the neighbors
    horizon = set_horizon(params, block_nodes_with_neighbors, horizon) # includes the neighbors
    set_angles(datamanager, params, block_nodes_with_neighbors) # includes the Neighbors
    solver_params =
        isnothing(step_id) ? params["Solver"] : get_solver_params(params, step_id)
    solver_options["Models"] = get_model_options(solver_params)
    solver_options["All Models"] = get_model_options(solver_params)
    if !isnothing(step_id)
        for step = 1:datamanager.get_max_step()
            append!(
                solver_options["All Models"],
                get_model_options(get_solver_params(params, step)),
            )
        end
        solver_options["All Models"] = unique(solver_options["All Models"])
    end
    solver_options["Calculation"] = get_calculation_options(solver_params)
    datamanager.create_constant_bond_field("Influence Function", Float64, 1, 1)
    for iblock in eachindex(block_nodes)
        datamanager = Influence_function.init_influence_function(
            block_nodes[iblock],
            datamanager,
            params["Discretization"],
        )
    end
    datamanager.create_bond_field("Bond Damage", Float64, 1, 1)
    @debug "Read properties"
    read_properties(params, datamanager, "Material" in solver_options["Models"])
    @debug "Init models"
    @timeit to "init_models" datamanager =
        Model_Factory.init_models(params, datamanager, block_nodes, solver_options, to)
    @debug "Init Boundary Conditions"
    @timeit to "init_BCs" bcs = Boundary_conditions.init_BCs(params, datamanager)
    solver_options["Solver"] = get_solver_name(solver_params)
    if get_solver_name(solver_params) == "Verlet"
        @debug "Init " * get_solver_name(solver_params)
        @timeit to "init_solver" solver_options["Initial Time"],
        solver_options["dt"],
        solver_options["nsteps"],
        solver_options["Numerical Damping"],
        solver_options["Maximum Damage"] = Verlet.init_solver(
            solver_params,
            bcs,
            datamanager,
            block_nodes,
            "Material" in solver_options["Models"],
            "Thermal" in solver_options["Models"],
        )
    elseif solver_options["Solver"] == "Static"
        @debug "Init " * get_solver_name(solver_params)
        @timeit to "init_solver" solver_options["Initial Time"],
        solver_options["dt"],
        solver_options["nsteps"],
        solver_options["Numerical Damping"],
        solver_options["Maximum Damage"] = Static_solver.init_solver(
            solver_params,
            bcs,
            datamanager,
            block_nodes,
            "Material" in solver_options["Models"],
            "Thermal" in solver_options["Models"],
        )

    else
        @error get_solver_name(solver_params) * " is no valid solver."
        return nothing
    end

    if datamanager.fem_active()
        datamanager = FEM.init_FEM(params, datamanager)
        datamanager = FEM.Coupling_PD_FEM.init_coupling(
            datamanager,
            1:datamanager.get_nnodes(),
            params,
        )
    end
    if !datamanager.has_key("Active")
        active = datamanager.create_constant_node_field("Active", Bool, 1, true)
    end
    #TODO: sync active with datamanager

    datamanager = remove_models(datamanager, solver_options["Models"])

    @debug "Finished Init Solver"
    return block_nodes, bcs, datamanager, solver_options
end

"""
    get_block_nodes(block_ids, nnodes)

Returns a dictionary mapping block IDs to collections of nodes.

# Arguments
- `block_ids::Vector{Int64}`: A vector of block IDs
- `nnodes::Int64`: The number of nodes
# Returns
- `block_nodes::Dict{Int64,Vector{Int64}}`: A dictionary mapping block IDs to collections of nodes
"""
function get_block_nodes(block_ids, nnodes)
    block_nodes = Dict{Int64,Vector{Int64}}()
    for i in unique(block_ids[1:nnodes])
        block_nodes[i] = find_indices(block_ids[1:nnodes], i)
    end
    return block_nodes
end

"""
    set_density(params::Dict, block_nodes::Dict, density::Vector{Float64})

Sets the density of the nodes in the dictionary.

# Arguments
- `params::Dict`: The parameters
- `block_nodes::Dict`: A dictionary mapping block IDs to collections of nodes
- `density::Vector{Float64}`: The density
# Returns
- `density::Vector{Float64}`: The density
"""
function set_density(params::Dict, block_nodes::Dict, density::Vector{Float64})
    for block in eachindex(block_nodes)
        density[block_nodes[block]] .= get_density(params, block)
    end
    return density
end

"""
    set_angles(datamanager::Module, params::Dict, block_nodes::Dict)

Sets the density of the nodes in the dictionary.

# Arguments
- `datamanager::Module`: The data manager
- `params::Dict`: The parameters
- `block_nodes::Dict`: A dictionary mapping block IDs to collections of nodes
"""
function set_angles(datamanager::Module, params::Dict, block_nodes::Dict)
    rotation = false
    dof = datamanager.get_dof()
    for block in eachindex(block_nodes)
        if get_angles(params, block, dof) !== nothing
            rotation = true
            break
        end
    end
    if rotation
        datamanager.set_rotation(true)
        angles = datamanager.create_constant_node_field("Angles", Float64, dof)

        for block in eachindex(block_nodes)
            angles_global = get_angles(params, block, dof)
            if isnothing(angles_global)
                angles_global = 0.0
            end
            for iID in block_nodes[block]
                angles[iID, :] .= angles_global
            end
        end
    end
end

"""
    set_fem_block(params::Dict, block_nodes::Dict, fem_block::Vector{Bool})

Sets the fem_block of the nodes in the dictionary.

# Arguments
- `params::Dict`: The parameters
- `block_nodes::Dict`: A dictionary mapping block IDs to collections of nodes
- `fem_block::Vector{Bool}`: The fem_block
# Returns
- `fem_block::Vector{Bool}`: The fem_block
"""
function set_fem_block(params::Dict, block_nodes::Dict, fem_block::Vector{Bool})
    for block in eachindex(block_nodes)
        fem_block[block_nodes[block]] .= get_fem_block(params, block)
    end
    return fem_block
end

"""
    set_horizon(params::Dict, block_nodes::Dict, horizon::Vector{Float64})

Sets the horizon of the nodes in the dictionary.

# Arguments
- `params::Dict`: The parameters
- `block_nodes::Dict`: A dictionary mapping block IDs to collections of nodes
- `horizon::Vector{Float64}`: The horizon
# Returns
- `horizon::Vector{Float64}`: The horizon
"""
function set_horizon(params::Dict, block_nodes::Dict, horizon::Vector{Float64})
    for block in eachindex(block_nodes)
        horizon[block_nodes[block]] .= get_horizon(params, block)
    end
    return horizon
end

"""
    solver(solver_options::Dict{String,Any}, block_nodes::Dict{Int64,Vector{Int64}}, bcs::Dict{Any,Any}, datamanager::Module, outputs::Dict{Int64,Dict{}}, result_files::Vector{Any}, write_results, to, silent::Bool)

Runs the solver.

# Arguments
- `solver_options::Dict{String,Any}`: The solver options
- `block_nodes::Dict{Int64,Vector{Int64}}`: A dictionary mapping block IDs to collections of nodes
- `bcs::Dict{Any,Any}`: The boundary conditions
- `datamanager::Module`: The data manager module
- `outputs::Dict{Int64,Dict{}}`: A dictionary for output settings
- `result_files::Vector{Any}`: A vector of result files
- `write_results`: A function to write simulation results
- `to::TimerOutputs.TimerOutput`: A timer output
- `silent::Bool`: A boolean flag to suppress progress bars
# Returns
- `result_files`: A vector of updated result files
"""
function solver(
    solver_options::Dict{Any,Any},
    block_nodes::Dict{Int64,Vector{Int64}},
    bcs::Dict{Any,Any},
    datamanager::Module,
    outputs::Dict{Int64,Dict{}},
    result_files::Vector{Dict},
    write_results,
    to,
    silent::Bool,
)

    if solver_options["Solver"] == "Verlet"
        return Verlet.run_solver(
            solver_options,
            block_nodes,
            bcs,
            datamanager,
            outputs,
            result_files,
            synchronise_field,
            write_results,
            to,
            silent,
        )
    elseif solver_options["Solver"] == "Static"
        return Static_solver.run_solver(
            solver_options,
            block_nodes,
            bcs,
            datamanager,
            outputs,
            result_files,
            synchronise_field,
            write_results,
            to,
            silent,
        )
    end
end

"""
    synchronise_field(comm, synch_fields::Dict, overlap_map, get_field, synch_field::String, direction::String)

Synchronises field.

# Arguments
- `comm`: The MPI communicator
- `synch_fields::Dict`: A dictionary of fields
- `overlap_map`: The overlap map
- `get_field`: The function to get the field
- `synch_field::String`: The field
- `direction::String`: The direction
# Returns
- `nothing`
"""
function synchronise_field(
    comm,
    synch_fields::Dict,
    overlap_map,
    get_field,
    synch_field::String,
    direction::String,
)
    # might not needed
    if !haskey(synch_fields, synch_field)
        @error "Field $synch_field does not exist in synch_field dictionary"
        return nothing
    end
    if direction == "download_from_cores"
        if synch_fields[synch_field][direction]
            vector = get_field(synch_field, synch_fields[synch_field]["time"])
            return synch_responder_to_controller(
                comm,
                overlap_map,
                vector,
                synch_fields[synch_field]["dof"],
            )
        end
        return nothing
    end
    if direction == "upload_to_cores"
        if synch_fields[synch_field][direction]
            vector = get_field(synch_field, synch_fields[synch_field]["time"])
            if occursin("Bond", synch_field)
                return synch_controller_bonds_to_responder_flattened(
                    comm,
                    overlap_map,
                    vector,
                    synch_fields[synch_field]["dof"],
                )
            else
                return synch_controller_to_responder(
                    comm,
                    overlap_map,
                    vector,
                    synch_fields[synch_field]["dof"],
                )
            end
        end
        return nothing
    end
    @error "Wrong direction key word $direction in function synchronise_field; it should be download_from_cores or upload_to_cores"
    return nothing
end

"""
    remove_models(datamanager::Module, solver_options::Vector{String})

Sets the active models to false if they are deactivated in the solver. They can be active, because they are defined as model and in the blocks.

# Arguments
- `datamanager::Module`: The MPI communicator
- `solver_options::Vector{String}`: A dictionary of fields
# Returns
- `datamanager`
"""
function remove_models(datamanager::Module, solver_options::Vector{String})

    check = replace.(solver_options .* " Model", "_" => " ")
    for active_model_name in keys(datamanager.get_active_models())
        if !(active_model_name in check)
            datamanager.remove_active_model(active_model_name)
        end
    end
    return datamanager
end

end
