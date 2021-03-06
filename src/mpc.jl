@with_kw struct MIPResults
    solvetime_s::Float64
    objective_value::Float64
    objective_bound::Float64
end

struct WarmstartCostRecord{T}
    lqr::Nullable{T}
    learned::Nullable{T}
end

function WarmstartCostRecord(lqr::T, learned::T) where T <: Real
    WarmstartCostRecord{T}(Nullable(lqr), Nullable(learned))
end

struct Sample{NX, NU, T}
    state::SVector{NX, T}
    input::SVector{NU, T}
    x0::SVector{NX, T}
    u0::SVector{NU, T}
    warmstart_costs::WarmstartCostRecord{T}
    mip::MIPResults
end

struct MPCResults{T}
    lcp_updates::Nullable{Vector{LCPSim.LCPUpdate{T, T, T, T}}}
    warmstart_costs::Vector{T}
    mip::MIPResults
end

function nominal_input(x0::MechanismState{X, M}, contacts::AbstractVector{<:Point3D}=Point3D[]) where {X, M}
    # externalwrenches = BodyDict(BodyID(body) => zero(Wrench{X}) for body in bodies(mechanism))
    externalwrenches = Dict{BodyID, Wrench{X}}()
    g = x0.mechanism.gravitational_acceleration
    for point in contacts
        body = body_fixed_frame_to_body(x0.mechanism, point.frame)
        force = FreeVector3D(g.frame, -mass(x0.mechanism) / length(contacts) * g.v)
        wrench = Wrench(transform_to_root(x0, point.frame) * point, force)
        if haskey(externalwrenches, body)
            externalwrenches[BodyID(body)] += wrench
        else
            externalwrenches[BodyID(body)] = wrench
        end
    end
    v̇ = similar(velocity(x0))
    v̇ .= 0
    u = inverse_dynamics(x0, v̇, externalwrenches)
    u .= clamp.(u, LCPSim.all_effort_bounds(x0.mechanism))
    u
end

function lqr_cost(lqr::LQRSolution,
                  state::StateLike,
                  results::AbstractVector{<:LCPSim.LCPUpdate})
    cost = sum(eachindex(results)) do i
        r = results[i]
        ū = r.input - lqr.u0
        # if i == 1
        #     v̇ = (velocity(r.state) .- velocity(state)) / r.Δt
        # else
        #     v̇ = (velocity(r.state) .- velocity(results[i-1].state)) / r.Δt
        # end
        x̄ = r.state.state .- lqr.x0
        x̄' * lqr.Q * x̄ + ū' * lqr.R * ū
    end
    x̄ = results[end].state.state .- lqr.x0
    cost + x̄' * lqr.S * x̄
end

(lqr::LQRSolution)(x0::StateLike, results::AbstractVector{<:LCPSim.LCPUpdate}) = lqr_cost(lqr, x0, results)

function run_warmstarts!(model::Model,
                         results::AbstractVector{<:LCPUpdate},
                         x0::MechanismState,
                         env::Environment,
                         params::MPCParams,
                         cost::Function,
                         warmstart_controllers::AbstractVector{<:Function})
    q0 = copy(configuration(x0))
    v0 = copy(velocity(x0))
    warmstarts = map(warmstart_controllers) do controller
        set_configuration!(x0, q0)
        set_velocity!(x0, v0)
        LCPSim.simulate(x0, controller, env, params.Δt, params.horizon, params.lcp_solver; relinearize=false)
    end
    warmstart_costs = [isempty(w) ? Inf : cost(x0, w) for w in warmstarts]
    idx = indmin(warmstart_costs)
    if isfinite(warmstart_costs[idx])
        best_warmstart = warmstarts[idx]
        setvalue.(results[1:length(best_warmstart)], best_warmstart)
        ConditionalJuMP.warmstart!(model, false)
    end
    return warmstart_costs
end

function run_mpc(x0::MechanismState,
                 env::Environment,
                 params::MPCParams,
                 cost,
                 warmstart_controllers::AbstractVector{<:Function}=[])
    model = Model(solver=params.mip_solver)
    _, results_opt = LCPSim.optimize(x0, env, params.Δt, params.horizon, model)
    @objective model Min cost(x0, results_opt)

    warmstart_costs = if isempty(warmstart_controllers)
        Float64[]
    else
        run_warmstarts!(model, results_opt, x0, env, params, cost, warmstart_controllers)
    end
    ConditionalJuMP.handle_constant_objective!(model)
    try
        JuMP.solve(model, suppress_warnings=true)
        # @show model.objVal
    catch e
        println("captured: $e")
        return MPCResults{Float64}(nothing, nothing, warmstart_costs, MIPResults(NaN, NaN, NaN))
    end

    mip_results = MIPResults(
        solvetime_s = getsolvetime(model),
        objective_value = _getvalue(getobjective(model)),
        objective_bound = getobjbound(model),
        )

    results_opt_value = getvalue.(results_opt)

    # @show results_opt_value[1].contacts
    # @show length(results_opt)
    # @show results_opt_value[1].input
    # @show configuration(results_opt_value[1].state)
    # @show velocity(results_opt_value[1].state)

    if any(isnan, results_opt_value[1].input)
        return MPCResults{Float64}(nothing, warmstart_costs, mip_results)
    else
        return MPCResults{Float64}(results_opt_value, warmstart_costs, mip_results)
    end
end

mutable struct MPCController{T, C <: Function, P <: MPCParams, M <: MechanismState} <: Function
    scratch_state::M
    env::Environment{T}
    params::P
    cost::C
    warmstart_controllers::Vector{Function}
    callback::Function
end

function MPCController(model::AbstractModel,
                       params::MPCParams,
                       cost,
                       warmstart_controllers::AbstractVector{<:Function})
    scratch_state = MechanismState{Float64}(mechanism(model))
    MPCController(scratch_state,
                  environment(model),
                  params,
                  cost,
                  convert(Vector{Function}, warmstart_controllers),
                  (state, results) -> nothing)
end

function (c::MPCController)(τ::AbstractVector, t::Real, x0::Union{MechanismState, LCPSim.StateRecord})
    set_configuration!(c.scratch_state, configuration(x0))
    set_velocity!(c.scratch_state, velocity(x0))
    results = run_mpc(c.scratch_state,
                      c.env,
                      c.params,
                      c.cost,
                      c.warmstart_controllers)
    set_configuration!(c.scratch_state, configuration(x0))
    set_velocity!(c.scratch_state, velocity(x0))
    c.callback(c.scratch_state, results)
    if !isnull(results.lcp_updates)
        τ .= first(get(results.lcp_updates)).input
    else
        τ .= 0
    end
    nothing
end
