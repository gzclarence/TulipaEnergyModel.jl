export create_model, solve_model

"""
    create_model(graph, representative_periods; verbose = false)

Create the model using the `graph` structure and the `representative_periods`.
"""

function create_model(graph, representative_periods; verbose = false, write_lp_file = false)
    # Sets unpacking
    A = labels(graph)
    F = edge_labels(graph)
    filter_assets(key, value) = Iterators.filter(a -> getfield(graph[a], key) == value, A)
    filter_flows(key, value) = Iterators.filter(f -> getfield(graph[f...], key) == value, F)

    Ac = filter_assets(:type, "consumer")
    Ap = filter_assets(:type, "producer")
    Ai = filter_assets(:investable, true)
    As = filter_assets(:type, "storage")
    Ah = filter_assets(:type, "hub")
    Acv = filter_assets(:type, "conversion")
    Fi = filter_flows(:investable, true)
    Ft = filter_flows(:is_transport, true)
    RP = 1:length(representative_periods)

    # For balance equations:
    # Every asset a ∈ A and every rp ∈ RP will define a collection of flows, and therefore the time steps
    # can be defined a priori.
    P = Dict(
        (a, rp) => begin
            compute_rp_partition(
                [
                    [
                        graph[u, v].partitions[rp] for
                        (u, v) in edge_labels(graph) if u == a || v == a
                    ]
                    [graph[a].partitions[rp]]
                ],
            )
        end for a in labels(graph), rp = 1:length(representative_periods)
    )

    # Model
    model = Model(HiGHS.Optimizer)
    set_attribute(model, "output_flag", verbose)

    # Variables
    @variable(model, flow[(u, v) ∈ F, rp ∈ RP, graph[u, v].partitions[rp]])
    @variable(model, 0 ≤ assets_investment[Ai], Int)  #number of installed asset units [N]
    @variable(model, 0 ≤ flows_investment[Fi], Int)
    @variable(model, 0 ≤ storage_level[a ∈ As, rp ∈ RP, P[(a, rp)]])

    # TODO: Fix storage_level[As, RP, 0] = 0

    # Expressions
    assets_investment_cost = @expression(
        model,
        sum(graph[a].investment_cost * graph[a].capacity * assets_investment[a] for a ∈ Ai)
    )

    flows_investment_cost = @expression(
        model,
        sum(
            graph[u, v].investment_cost * graph[u, v].unit_capacity * flows_investment[(u, v)]
            for (u, v) ∈ Fi
        )
    )

    flows_variable_cost = @expression(
        model,
        sum(
            representative_periods[rp].weight *
            graph[u, v].variable_cost *
            flow[(u, v), rp, B_flow] for (u, v) ∈ F, rp ∈ RP,
            B_flow ∈ graph[u, v].partitions[rp]
        )
    )

    # Objective function
    @objective(model, Min, assets_investment_cost + flows_investment_cost + flows_variable_cost)

    # Constraints
    # Computes the duration of the `block` that is within the `period`, and
    # multiply by the resolution of the representative period `rp`.
    # It is equivalent to finding the indexes of these values in the matrix.
    function duration(B1, B2, rp)
        return length(B1 ∩ B2) * representative_periods[rp].resolution
    end

    # Sums the profile of representative period rp over the time block B
    # Uses the default_value when that profile does not exist.
    function profile_sum(profiles, rp, B, default_value)
        if haskey(profiles, rp)
            return sum(profiles[rp][B])
        else
            return length(B) * default_value
        end
    end

    function assets_profile_sum(a, rp, B, default_value)
        return profile_sum(graph[a].profiles, rp, B, default_value)
    end

    # Same as above but for flow
    function flows_profile_sum(u, v, rp, B, default_value)
        return profile_sum(graph[u, v].profiles, rp, B, default_value)
    end

    @expression(
        model,
        incoming_flow[a ∈ A, rp ∈ RP, B ∈ P[(a, rp)]],
        sum(
            duration(B, B_flow, rp) * flow[(u, v), rp, B_flow] for
            (u, v) in F, B_flow ∈ graph[u, v].partitions[rp] if
            v == a && B_flow[end] ≥ B[1] && B[end] ≥ B_flow[1]
        )
    )
    @expression(
        model,
        outgoing_flow[a ∈ A, rp ∈ RP, B ∈ P[(a, rp)]],
        sum(
            duration(B, B_flow, rp) * flow[(u, v), rp, B_flow] for
            (u, v) in F, B_flow ∈ graph[u, v].partitions[rp] if
            u == a && B_flow[end] ≥ B[1] && B[end] ≥ B_flow[1]
        )
    )
    @expression(
        model,
        incoming_flow_w_efficiency[a ∈ A, rp ∈ RP, B ∈ P[(a, rp)]],
        sum(
            duration(B, B_flow, rp) * flow[(u, v), rp, B_flow] * graph[u, v].efficiency for
            (u, v) in F, B_flow ∈ graph[u, v].partitions[rp] if
            v == a && B_flow[end] ≥ B[1] && B[end] ≥ B_flow[1]
        )
    )
    @expression(
        model,
        outgoing_flow_w_efficiency[a ∈ A, rp ∈ RP, B ∈ P[(a, rp)]],
        sum(
            duration(B, B_flow, rp) * flow[(u, v), rp, B_flow] / graph[u, v].efficiency for
            (u, v) in F, B_flow ∈ graph[u, v].partitions[rp] if
            u == a && B_flow[end] ≥ B[1] && B[end] ≥ B_flow[1]
        )
    )

    @expression(
        model,
        assets_profile_times_capacity[a ∈ A, rp ∈ RP, B ∈ P[(a, rp)]],
        assets_profile_sum(a, rp, B, 1.0) *
        (graph[a].initial_capacity + (a ∈ Ai ? (graph[a].capacity * assets_investment[a]) : 0.0))
    )

    @expression(
        model,
        energy_limit[a ∈ As∩Ai],
        graph[a].energy_to_power_ratio * graph[a].capacity * assets_investment[a]
    )

    @expression(
        model,
        storage_inflows[a ∈ As, rp ∈ RP, T ∈ P[(a, rp)]],
        assets_profile_sum(a, rp, T, 0.0) *
        (graph[a].initial_storage_capacity + (a ∈ Ai ? energy_limit[a] : 0.0))
    )

    # Balance equations
    # - consumer balance equation
    @constraint(
        model,
        consumer_balance[a ∈ Ac, rp ∈ RP, B ∈ P[(a, rp)]],
        incoming_flow[(a, rp, B)] - outgoing_flow[(a, rp, B)] ==
        assets_profile_sum(a, rp, B, 1.0) * graph[a].peak_demand
    )

    # - storage balance equation
    @constraint(
        model,
        storage_balance[a ∈ As, rp ∈ RP, (k, B) ∈ enumerate(P[(a, rp)])],
        storage_level[a, rp, B] ==
        (k > 1 ? storage_level[a, rp, P[(a, rp)][k-1]] : graph[a].initial_storage_level) +
        storage_inflows[a, rp, B] +
        incoming_flow_w_efficiency[(a, rp, B)] - outgoing_flow_w_efficiency[(a, rp, B)]
    )

    # - hub balance equation
    @constraint(
        model,
        hub_balance[a ∈ Ah, rp ∈ RP, B ∈ P[(a, rp)]],
        incoming_flow[(a, rp, B)] == outgoing_flow[(a, rp, B)]
    )

    # - conversion balance equation
    @constraint(
        model,
        conversion_balance[a ∈ Acv, rp ∈ RP, B ∈ P[(a, rp)]],
        incoming_flow_w_efficiency[(a, rp, B)] == outgoing_flow_w_efficiency[(a, rp, B)]
    )

    # Constraints that define bounds of flows related to energy assets A
    # - overall output flows
    @constraint(
        model,
        overall_output_flows[a ∈ Acv∪As∪Ap, rp ∈ RP, B ∈ P[(a, rp)]],
        outgoing_flow[(a, rp, B)] ≤ assets_profile_times_capacity[a, rp, B]
    )
    #
    # # - overall input flows
    @constraint(
        model,
        overall_input_flows[a ∈ As, rp ∈ RP, B ∈ P[(a, rp)]],
        incoming_flow[(a, rp, B)] ≤ assets_profile_times_capacity[a, rp, B]
    )
    #
    # # - upper bound associated with asset
    @constraint(
        model,
        upper_bound_asset[
            a ∈ A,
            (u, v) ∈ F,
            rp ∈ RP,
            B ∈ P[(a, rp)];
            !(a ∈ Ah ∪ Ac) && u == a && (u, v) ∉ Ft,
        ],
        sum(
            duration(B, B_flow, rp) * flow[(u, v), rp, B_flow] for
            B_flow ∈ graph[u, v].partitions[rp] if B_flow[end] ≥ B[1] && B[end] ≥ B_flow[1]
        ) ≤ assets_profile_times_capacity[a, rp, B]
    )

    # Define lower bounds for flows that are not transport assets
    for f ∈ F, rp ∈ RP, B_flow ∈ graph[f...].partitions[rp]
        if f ∉ Ft
            set_lower_bound(flow[f, rp, B_flow], 0.0)
        end
    end

    # Constraints that define bounds for a transport flow Ft
    @expression(
        model,
        upper_bound_transport_flow[(u, v) ∈ F, rp ∈ RP, B_flow ∈ graph[u, v].partitions[rp]],
        flows_profile_sum(u, v, rp, B_flow, 1.0) * (
            graph[u, v].initial_capacity +
            (graph[u, v].investable ? graph[u, v].export_capacity * flows_investment[(u, v)] : 0.0)
        )
    )
    @constraint(
        model,
        transport_flow_upper_bound[f ∈ Ft, rp ∈ RP, B_flow ∈ graph[f...].partitions[rp]],
        flow[f, rp, B_flow] ≤ upper_bound_transport_flow[f, rp, B_flow]
    )
    @expression(
        model,
        lower_bound_transport_flow[(u, v) ∈ F, rp ∈ RP, B_flow ∈ graph[u, v].partitions[rp]],
        flows_profile_sum(u, v, rp, B_flow, 1.0) * (
            graph[u, v].initial_capacity +
            (graph[u, v].investable ? graph[u, v].import_capacity * flows_investment[(u, v)] : 0.0)
        )
    )
    @constraint(
        model,
        transport_flow_lower_bound[f ∈ Ft, rp ∈ RP, B_flow ∈ graph[f...].partitions[rp]],
        flow[f, rp, B_flow] ≥ -lower_bound_transport_flow[f, rp, B_flow]
    )

    # Extra constraints
    # - upper bound constraints for storage level
    @constraint(
        model,
        upper_bound_for_storage_level[a ∈ As, rp ∈ RP, B ∈ P[(a, rp)]],
        storage_level[a, rp, B] ≤
        graph[a].initial_storage_capacity + (a ∈ Ai ? energy_limit[a] : 0.0)
    )

    # - cycling condition for storage level
    for a ∈ As, rp ∈ RP
        set_lower_bound(storage_level[a, rp, P[(a, rp)][end]], graph[a].initial_storage_level)
    end

    if write_lp_file
        write_to_file(model, "model.lp")
    end

    return model
end

"""
    solve_model(model)

Solve the model.
"""
function solve_model(model)

    # Solve model
    optimize!(model)

    # Check solution status
    if termination_status(model) != OPTIMAL
        @warn("Model status different from optimal")
        return nothing
    end

    return (
        objective_value = objective_value(model),
        flow = value.(model[:flow]),
        assets_investment = value.(model[:assets_investment]),
    )
end
