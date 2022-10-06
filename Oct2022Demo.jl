#=module Oct2022Demo

export stratify, typed_stratify, simulate, calibrate, MakeReactionSystem, generate_data, get_infected_states, get_susceptible_states,
    get_recovered_states, optimise_p, full_train, obs_SIRD, makeLossFunction, plot_obs_w_ests, full_train_rand
 =#

using AlgebraicPetri
# using Catlab
using Catlab.CategoricalAlgebra
# using Catalyst
# using OrdinaryDiffEq
using DiffEqFlux
using Plots
using JSON
using CSV
using DataFrames

stratify(typed_model1, typed_model2) = ob(pullback(typed_model1, typed_model2))

typed_stratify(typed_model1, typed_model2) =
  compose(proj1(pullback(typed_model1, typed_model2)), typed_model1);

counter(a) = [count(==(i),a) for i in unique(a)]
function MakeReactionSystem(pn::AbstractPetriNet)
    @parameters t k[1:(nt(pn) + ns(pn))]
    @variables S[1:ns(pn)](t)

    rxs = map(1:nt(pn)) do t
      inpts = pn[incident(pn, t, :it),:is]
      otpts = pn[incident(pn, t, :ot),:os]
      in_count = collect(counter(inpts))
      ot_count = collect(counter(otpts))
      Reaction(k[t], [S[i] for i in unique(inpts)],
                     [S[o] for o in unique(otpts)],
                     in_count, ot_count)
    end

    ReactionSystem(rxs, t, S, k; name=:model)
end

function simulate(model, u0, p, tspan)
    rxn = MakeReactionSystem(model)
    prob = ODEProblem(rxn, u0, tspan, p)
    sol = solve(prob, Tsit5())
    return sol
end

get_infected_states(g::AbstractLabelledPetriNet) =
   [i for (i,s) in enumerate(g[:sname]) if occursin("I", string(s))]

get_susceptible_states(g::AbstractLabelledPetriNet) =
   [i for (i,s) in enumerate(g[:sname]) if occursin("S", string(s))]

get_recovered_states(g::AbstractLabelledPetriNet) =
   [i for (i,s) in enumerate(g[:sname]) if occursin("R", string(s)) || occursin("V", string(s))]

get_dead_states(g::AbstractLabelledPetriNet) =
   [i for (i,s) in enumerate(g[:sname]) if occursin("D", string(s))]

function obsSIRD(model::AbstractLabelledPetriNet, sol, sample_times)
    inf_sample_vals = sol(sample_times)[get_infected_states(model),:]
    susc_sample_vals = sol(sample_times)[get_susceptible_states(model),:]
    rec_sample_vals = sol(sample_times)[get_recovered_states(model),:]
    dead_sample_vals = sol(sample_times)[get_dead_states(model),:]
    
    total_inf_samples = map(sum, eachcol(inf_sample_vals))
    total_susc_samples = map(sum, eachcol(susc_sample_vals))
    total_rec_samples = map(sum, eachcol(rec_sample_vals))
    total_dead_samples = map(sum, eachcol(dead_sample_vals))

    labels = reshape(["I", "R or V", "S", "D"],1,4)

    return hcat(total_inf_samples, total_rec_samples, total_susc_samples, total_dead_samples), labels
end

function generateData(model::AbstractLabelledPetriNet, p, u0, tspan, num_samples, obs_func)
    sample_times = range(tspan[1], stop=tspan[2], length=num_samples)

    sol = simulate(model, u0, p, tspan) # , tstops=sample_times

    obs_true, obs_lbls = obs_func(model, sol, sample_times)
    
    obs_noisy = obs_true .* (ones(size(obs_true)...)+0.1rand(size(obs_true)...)-0.05ones(size(obs_true)...))

    return obs_noisy, sample_times, prob, sol, obs_true
end

function makeLossFunction(model::AbstractLabelledPetriNet, obs_func, op, tend, sample_data, sample_times)
    # Loss on all populations
    #=loss = function (p)
        sol = solve(remake(op,tspan=(0.0,tend),p=p), Tsit5(), tstops=sample_times)
        vals = hcat(map(ts -> sol.u[findfirst(sol.t .>= ts)], sample_times[1:findlast(sample_times .<= tend)])...)    
        loss = sum(abs2, vals .- sample_vals[:,1:size(vals)[2]])   
        return loss, sol
    end=#

    function loss(p)
        sol = solve(remake(op,tspan=(0.0,tend),p=p), Tsit5(), tstops=sample_times)

        vals, _ = obs_func(model, sol, sample_times[1:findlast(sample_times .<= tend)])
        inf_vals = vals[:,1]
        rec_vals = vals[:,2]
        susc_vals = vals[:,3]
        dead_vals = vals[:,4]

        #loss = sum(abs2, vals[2,:] .- sample_vals[:,1:size(vals)[2]][2,:])
        inf_samples = sample_data[:,1]
        rec_samples = sample_data[:,2]
        susc_samples = sample_data[:,3]
        dead_samples = sample_data[:,4]

        inf_loss = sum(abs2, inf_vals .- inf_samples[1:size(inf_vals)[1]])
        susc_loss = sum(abs2, susc_vals .- susc_samples[1:size(susc_vals)[1]])
        rec_loss = sum(abs2, rec_vals .- rec_samples[1:size(rec_vals)[1]])
        #=dead_loss = sum(abs2, dead_vals .- dead_samples[1:size(dead_vals)[1]])=#

        # Lines for debugging
        # println(size(sample_times[1:findlast(sample_times .<= tend)]),": ",maximum(sample_times[1:findlast(sample_times .<= tend)]))
        # println(size(vals), ": ", size(inf_vals), ": ", size(inf_samples))

        return susc_loss + inf_loss + rec_loss, sol
    end

end

function calibrate(model, obs_func, u0, p_init, training_data, sample_times; name="")
    
    rxn = MakeReactionSystem(model)

    tspan = (minumum(sample_times), maximum(sample_times))
    
    prob = ODEProblem(rxn, u0, tspan, p_init)
    
    p_estimate = p_init
    loss = 0
    sol_estimate = Nothing

    for i in 1:7:50 # 2:8:50 # 25:25:50 # 
        l_func = makeLossFunction(model, obs_func, prob, sample_times[i], training_data, sample_times)
        
        res_ode = DiffEqFlux.sciml_train(l_func, p_estimate, #=ADAM(0.05), cb=callback,=# maxiters=2000, abstol=1e-4, reltol=1e-4,
            lower_bounds=repeat([1e-6], length(p_estimate)), upper_bounds=ones(length(p_estimate)))
        p_estimate = res_ode.minimizer
        loss = res_ode.minimum
        
        sol_estimate = solve(remake(prob,tspan=tspan,p=p_estimate), Tsit5())
    end
    
    return  p_estimate, sol_estimate, loss
end

function calibrateFromFiles(fname_mdl,fname_obs_func_and_params,fname_data)
    include(fname_obs_func_and_params)

    mdl = read_json_acset_schema(fname_mdl)

    df_data = CSV.read(fname_data, DataFrame)
    obs_times = 1:length(df_data[:, :t])
    obs_data = df_data[:,[:s,:i,:r]]

    p_est, sol_est, loss = calibrate(mdl, obs_func, u0, p_init, obs_data, obs_times; name="")

    # output p_est to file?

    return p_est
end

function test()
    infectious_type = LabelledPetriNet([:Pop],
      :interact=>((:Pop, :Pop)=>(:Pop, :Pop)), 
      :t_disease=>(:Pop=>:Pop),
      :t_strata=>(:Pop=>:Pop)
    )
    s, = parts(infectious_type, :S)
    t_interact, t_disease, t_strata = parts(infectious_type, :T)
    i_interact1, i_interact2, i_disease, i_strata = parts(infectious_type, :I)
    o_interact1, o_interact2, o_disease, o_strata = parts(infectious_type, :O);
    infectious_type = map(infectious_type, Name=name->nothing); 

    SIR = LabelledPetriNet([:S, :I, :R],
      :inf => ((:S, :I)=>(:I, :I)),
      :rec => (:I=>:R),
      :id => (:S => :S),
      :id => (:I => :I),
      :id => (:R => :R)
    )
    typed_SIR = ACSetTransformation(SIR, infectious_type,
      S = [s, s, s],
      T = [t_interact, t_disease, t_strata, t_strata, t_strata],
      I = [i_interact1, i_interact2, i_disease, i_strata, i_strata, i_strata],
      O = [o_interact1, o_interact2, o_disease, o_strata, o_strata, o_strata],
      Name = name -> nothing # specify the mapping for the loose ACSet transform
    );
    @assert is_natural(typed_SIR)

    quarantine = LabelledPetriNet([:Q, :NotQ],
      :id => (:Q => :Q),
      :id => (:NotQ => :NotQ),
      :enter_q => (:NotQ => :Q),
      :exit_q => (:Q => :NotQ),
      :interact => ((:NotQ, :NotQ) => (:NotQ, :NotQ))
    )
    typed_quarantine = ACSetTransformation(quarantine, infectious_type,
      S = [s, s],
      T = [t_disease, t_disease, t_strata, t_strata, t_interact],
      I = [i_disease, i_disease, i_strata, i_strata, i_interact1, i_interact2],
      O = [o_disease, o_disease, o_strata, o_strata, o_interact1, o_interact2],
      Name = name -> nothing
    )
    @assert is_natural(typed_quarantine)

    true_mdl = typed_stratify(typed_SIR,typed_quarantine)
    true_p = vcat(repeat([1e-4], 14), repeat([0.01], 6))
	true_p = vcat([1.1e-4,1.3e-4,1.2e-4,1.4e-4,1.5e-4,1.2e-4,
				   1.e-4,1.3e-4,1.5e-4,1.2e-4,1.7e-4,1.6e-4,
		           1.2e-4,1.1e-4,], [0.01,0.02,0.01,0.01,0.01,0.02])
	u0 = [0.0,0.0,0.0,0.0,0.0,999.0,1.0,0.0,0.0,0.0] 
	tspan = (0.0,250.0)

    true_sol = simulate(true_mdl,u0,true_p,tspan)

    sample_data, sample_times, prob_real, sol_real = generate_data(true_mdl, true_p, u0, tspan, 50, obsSIRD)

    plt = plot(sol_real, lw=2, label=reshape(map(string, true_mdl[:, :sname]), 1, ns(true_mdl)))
	plot!(sample_times, sample_data, seriestype=:scatter, label="")


end

# function stratifyFromFiles() end
# function testCalibrateFromFiles() end
# function testStratifyFromFiles() end


#=
THIS IS KRIS'S VERSION FROM StratificationMadeEasy. BUT NEEDS DIFFERENT INPUT FORMAT.

"""Modify a typed petri net to add cross terms"""
function add_cross_terms(pn_crossterms, type_system)
  typed_pn, crossterms = deepcopy.(pn_crossterms)
  pn = dom(typed_pn)
  type_comps = Dict([k=>collect(v) for (k,v) in pairs(components(typed_pn))])
  for (s_i,cts) in enumerate(crossterms)
    for ct in cts 
      type_ind = findfirst(==(ct), type_system[:tname])
      is, os = [incident(type_system, type_ind, f) for f in [:it, :ot]]
      new_t = add_part!(pn, :T; tname=ct)
      add_parts!(pn, :I, length(is); is=s_i, it=new_t)
      add_parts!(pn, :O, length(os); os=s_i, ot=new_t)
      push!(type_comps[:T], type_ind)
      append!(type_comps[:I], is); append!(type_comps[:O], os); 
    end
  end
  return homomorphism(pn, codom(typed_pn); initial=type_comps, 
                      type_components=(Name=x->nothing,),)
end

"""Add cross terms before taking pullback"""
function stratify(pn1, pn2, type_system)
  return pullback([add_cross_terms(pn, type_system) for pn in [pn1, pn2]]) |> apex
end
=#