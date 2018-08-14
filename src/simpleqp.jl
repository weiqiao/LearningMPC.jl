using QPControl
import SimpleQP
using OSQP.MathOptInterfaceOSQP
import MathOptInterface
const MOI = MathOptInterface
using RigidBodyDynamics.Contact
using Base.Iterators
using Gurobi

function defaultoptimizer()
    # optimizer = OSQPOptimizer()
    # MOI.set!(optimizer, OSQPSettings.Verbose(), false)
    # MOI.set!(optimizer, OSQPSettings.EpsAbs(), 1e-5)
    # MOI.set!(optimizer, OSQPSettings.EpsRel(), 1e-5)
    # MOI.set!(optimizer, OSQPSettings.MaxIter(), 5000)
    # MOI.set!(optimizer, OSQPSettings.AdaptiveRhoInterval(), 25) # required for deterministic behavior
    # MOI.set!(optimizer, OSQPSettings.WarmStart(), false)
    optimizer = GurobiOptimizer(OutputFlag=0)
    optimizer
    # MosekOptimizer()
end

function build_contact_controller(mechanism, lqrsol, contacts, contact_state)
    lowlevel = QPControl.MPCController{4}(mechanism, defaultoptimizer())
    stage = QPControl.addstage!(lowlevel, lqrsol.Δt)
    for (i, (point, surface)) in enumerate(contacts)
        body = body_fixed_frame_to_body(mechanism, point.frame)
        contact_point = QPControl.addcontact!(stage,
            body,
            point,
            FreeVector3D(default_frame(body), 0., 0, 1),
            0.8,
            surface
        )
        if contact_state[i]
            contact_point.maxnormalforce = 1e9
        else
            contact_point.maxnormalforce = 0
        end
    end

    lowlevel.running_state_cost.Q .= lqrsol.Q
    lowlevel.running_state_cost.q .= 0
    lowlevel.running_state_cost.x0 .= lqrsol.x0
    lowlevel.running_input_cost.Q .= lqrsol.R
    lowlevel.running_input_cost.q .= 0
    lowlevel.running_input_cost.x0 .= 0
    lowlevel.terminal_state_cost.Q .= lqrsol.S
    lowlevel.terminal_state_cost.q .= 0
    lowlevel.terminal_state_cost.x0 .= lqrsol.x0;
    lowlevel
end

# TODO: don't assume that the contact force is always in the same
# direction in body frame. This is especially important for the hands.


function build_mixed_controller(mechanism, lqrsol, contacts::AbstractVector{<:Tuple{Point3D, HalfSpace3D}})

    contact_states = collect(product([[true, false] for _ in contacts]...))
    controllers = map(contact_states) do contact_state
        @show contact_state
        build_contact_controller(mechanism, lqrsol, contacts, contact_state)
    end
    τs = [zeros(num_velocities(mechanism)) for controller in controllers]
    objective_values = zeros(length(controllers))

    function control(τ, t, x)
        let controllers = controllers,
            τs = τs,
            objective_values = objective_values

#             Threads.@threads
            for i in eachindex(controllers)
                controller = controllers[i]
                # controller.running_state_cost.x0[2] = 0.7 + 0.2 * sin(t)
                # controller.terminal_state_cost.x0[2] = 0.7 + 0.2 * sin(t)
                if !controller.initialized
                    QPControl.initialize!(controller)
                end
                for stage in QPControl.stages(controller)
                    QPControl.copyto!(stage.state, x)
                end
                model = controller.qpmodel
                SimpleQP.solve!(model)
                τs[i] .= SimpleQP.value.(model, controller.stages[1].input)
                if SimpleQP.primalstatus(model) ∈ (MOI.InfeasiblePoint, MOI.InfeasibilityCertificate, MOI.InfeasibleOrUnbounded)
                    objective_values[i] = Inf
                else
                    objective_values[i] = SimpleQP.objectivevalue(model)
                end
            end
        end
        best_cost = Inf
        best_model = 0
        for i in eachindex(controllers)
            if objective_values[i] < best_cost
                best_model = i
                best_cost = objective_values[i]
                τ .= τs[i]
            end
        end
        if best_cost == Inf
            @show configuration(x) velocity(x)
            set_configuration!(mvis, configuration(x))
            error("infeasible")
        end
        # @show best_model contact_states[best_model]
        # @show objective_values
#         @show best_cost
        τ
    end, controllers
end
