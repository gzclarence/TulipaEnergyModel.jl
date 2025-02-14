export resolution_matrix, compute_rp_partition

using SparseArrays

"""
    M = resolution_matrix(rp_partition, time_blocks; rp_resolution = 1.0)

Computes the resolution balance matrix using the array of `rp_partition` and the array of `time_blocks`.
The `time_blocks` will normally be from an asset or flow, but there is nothing constraining it to that.
The elements in these arrays must be ranges.

The resulting matrix will be multiplied by `rp_resolution`.

## Examples

The following two examples are for two flows/assets with resolutions of 3h and 4h, so that the representative period has 4h periods.

```jldoctest
rp_partition = [1:4, 5:8, 9:12]
time_blocks = [1:4, 5:8, 9:12]
resolution_matrix(rp_partition, time_blocks)

# output

3×3 SparseArrays.SparseMatrixCSC{Float64, Int64} with 3 stored entries:
 1.0   ⋅    ⋅
  ⋅   1.0   ⋅
  ⋅    ⋅   1.0
```

```jldoctest
rp_partition = [1:4, 5:8, 9:12]
time_blocks = [1:3, 4:6, 7:9, 10:12]
resolution_matrix(rp_partition, time_blocks; rp_resolution = 1.5)

# output

3×4 SparseArrays.SparseMatrixCSC{Float64, Int64} with 6 stored entries:
 1.5  0.5   ⋅    ⋅
  ⋅   1.0  1.0   ⋅
  ⋅    ⋅   0.5  1.5
```
"""
function resolution_matrix(
    rp_partition::AbstractVector{<:UnitRange{<:Integer}},
    time_blocks::AbstractVector{<:UnitRange{<:Integer}};
    rp_resolution = 1.0,
)
    matrix = sparse([
        rp_resolution * length(period ∩ time_block) / length(time_block) for
        period in rp_partition, time_block in time_blocks
    ])

    return matrix
end

"""
    rp_partition = compute_rp_partition(partitions; strategy = :greedy)

Given the time steps of various flows/assets in the `partitions` input, compute the representative period partitions.

Each element of `partitions` is a partition with the following assumptions:

  - An element is of the form `V = [r₁, r₂, …, rₘ]`, where each `rᵢ` is a range `a:b`.
  - `r₁` starts at 1.
  - `rᵢ₊₁` starts at the end of `rᵢ` plus 1.
  - `rₘ` ends at some value `N`, that is the same for all elements of `partitions`.

Notice that this implies that they form a disjunct partition of `1:N`.

The output will also be a partition with the conditions above.

## Strategies

### :greedy

If `strategy = :greedy` (default), then the output is constructed greedily,
i.e., it selects the next largest breakpoint following the algorithm below:

 0. Input: `Vᴵ₁, …, Vᴵₚ`, a list of time blocks. Each element of `Vᴵⱼ` is a range `r = r.start:r.end`. Output: `V`.
 1. Compute the end of the representative period `N` (all `Vᴵⱼ` should have the same end)
 2. Start with an empty `V = []`
 3. Define the beginning of the range `s = 1`
 4. Define an array with all the next breakpoints `B` such that `Bⱼ` is the first `r.end` such that `r.end ≥ s` for each `r ∈ Vᴵⱼ`.
 5. The end of the range will be the `e = max Bⱼ`.
 6. Define `r = s:e` and add `r` to the end of `V`.
 7. If `e = N`, then END
 8. Otherwise, define `s = e + 1` and go to step 4.

#### Examples

```jldoctest
partition1 = [1:4, 5:8, 9:12]
partition2 = [1:3, 4:6, 7:9, 10:12]
compute_rp_partition([partition1, partition2])

# output

3-element Vector{UnitRange{Int64}}:
 1:4
 5:8
 9:12
```

```jldoctest
partition1 = [1:1, 2:3, 4:6, 7:10, 11:12]
partition2 = [1:2, 3:4, 5:5, 6:7, 8:9, 10:12]
compute_rp_partition([partition1, partition2])

# output

5-element Vector{UnitRange{Int64}}:
 1:2
 3:4
 5:6
 7:10
 11:12
```

### :all

If `strategy = :all`, then the output selects includes all the breakpoints from the input.
Another way of describing it, is to select the minimum end-point instead of the maximum end-point in the `:greedy` strategy.

#### Examples

```jldoctest
partition1 = [1:4, 5:8, 9:12]
partition2 = [1:3, 4:6, 7:9, 10:12]
compute_rp_partition([partition1, partition2]; strategy = :all)

# output

6-element Vector{UnitRange{Int64}}:
 1:3
 4:4
 5:6
 7:8
 9:9
 10:12
```

```jldoctest
partition1 = [1:1, 2:3, 4:6, 7:10, 11:12]
partition2 = [1:2, 3:4, 5:5, 6:7, 8:9, 10:12]
compute_rp_partition([partition1, partition2]; strategy = :all)

# output

10-element Vector{UnitRange{Int64}}:
 1:1
 2:2
 3:3
 4:4
 5:5
 6:6
 7:7
 8:9
 10:10
 11:12
```
"""
function compute_rp_partition(
    partitions::AbstractVector{<:AbstractVector{<:UnitRange{<:Integer}}};
    strategy = :greedy,
)
    valid_strategies = [:greedy, :all]
    if !(strategy in valid_strategies)
        error("`strategy` should be one of $valid_strategies. See docs for more info.")
    end
    # Get Vᴵ₁, the last range of it, the last element of the range
    rp_end = partitions[1][end][end]
    for partition in partitions
        # Assumption: All start at 1 and end at N
        @assert partition[1][1] == 1
        @assert rp_end == partition[end][end]
    end
    rp_partition = UnitRange{Int}[] # List of ranges

    block_start = 1
    if strategy == :greedy
        while block_start ≤ rp_end
            # The first range end larger than period_start for each range in each time_blocks.
            breakpoints = (
                first(r[end] for r in partition if r[end] ≥ block_start) for
                partition in partitions
            )
            block_end = maximum(breakpoints)
            @assert block_end ≥ block_start
            push!(rp_partition, block_start:block_end)
            block_start = block_end + 1
        end
    elseif strategy == :all
        # We need all end points of each interval
        end_points_per_array = map(partitions) do x # For each partition
            last.(x) # Retrieve the last element of each interval
        end
        # Then we concatenate, remove duplicates, and sort.
        end_points = vcat(end_points_per_array...) |> unique |> sort
        for block_end in end_points
            push!(rp_partition, block_start:block_end)
            block_start = block_end + 1
        end
    end
    return rp_partition
end
