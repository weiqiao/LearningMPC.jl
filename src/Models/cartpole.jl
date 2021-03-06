const cartpole_urdf = joinpath(@__DIR__, "urdf", "cartpole_with_walls.urdf")

struct CartPole{T} <: AbstractModel{T}
    mechanism::Mechanism{T}
    environment::Environment{T}
end

mechanism(c::CartPole) = c.mechanism
environment(c::CartPole) = c.environment
urdf(c::CartPole) = cartpole_urdf

function add_rbd_contact_model!(robot::CartPole)
    mech = mechanism(robot)
    urdf_env = LCPSim.parse_contacts(mech, urdf(robot), 1.0, :yz)
    obstacles = unique([c[3] for c in urdf_env.contacts])
    state = nominal_state(robot)
    for obstacle in obstacles
        face = obstacle.contact_face
        point_in_world = transform(state, face.point, root_frame(mech))
        normal_in_world = transform(state, face.outward_normal, root_frame(mech))
        add_environment_primitive!(mech, HalfSpace3D(point_in_world, normal_in_world))
    end
    contactmodel = SoftContactModel(hunt_crossley_hertz(k = 500e3), ViscoelasticCoulombModel(1.0, 20e3, 100.))
    bodyname = "pole"
    body = findbody(mech, bodyname)
    frame = default_frame(body)
    add_contact_point!(body, ContactPoint(Point3D(frame, 0.0, 0.0, 1.0), contactmodel))
    robot
end


function CartPole(;add_contacts=false)
    mechanism = parse_urdf(Float64, cartpole_urdf)
    env = LCPSim.parse_contacts(mechanism, cartpole_urdf, 0.5, :xz)
    robot = CartPole(mechanism, env)
    if add_contacts
        add_rbd_contact_model!(robot)
    end
    robot
end

function nominal_state(c::CartPole)
    x = MechanismState{Float64}(c.mechanism)
end

function default_costs(c::CartPole)
    Q = diagm([10., 100, 1, 10])
    R = diagm([0.1, 0.1])
    Q, R
end

function LearningMPC.MPCParams(c::CartPole)
    mpc_params = LearningMPC.MPCParams(
        Δt=0.025,
        horizon=20,
        mip_solver=GurobiSolver(Gurobi.Env(), OutputFlag=0,
            TimeLimit=3,
            MIPGap=1e-2,
            FeasibilityTol=1e-3),
        lcp_solver=GurobiSolver(Gurobi.Env(), OutputFlag=0))
end

function LearningMPC.LQRSolution(c::CartPole, params::MPCParams=MPCParams(c))
    xstar = nominal_state(c)
    Q, R = default_costs(c)
    lqrsol = LearningMPC.LQRSolution(xstar, Q, R, params.Δt, Point3D[])
end
