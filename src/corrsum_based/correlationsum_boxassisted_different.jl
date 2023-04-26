# Legacy code. I tried to improve the algorithm via a completely different implementation.
# Turned out slower, about 2x times. Still don't understand why so I leave this code here
# and in the future maybe I can have a second look.

import ProgressMeter
export boxed_correlationsum, boxassisted_correlation_dim, data_boxing
export estimate_r0_buenoorovio, autoprismdim, estimate_r0_theiler

################################################################################
# Boxed correlation sum main API functions
################################################################################
"""
    boxassisted_correlation_dim(X::AbstractStateSpaceSet; kwargs...)

Use the box-assisted optimizations of [^Bueno2007]
to estimate the correlation dimension `Δ_C` of `X`.

This function does something extremely simple:
```julia
εs, Cs = boxed_correlationsum(X; kwargs...)
return linear_region(log2.(Cs), log2.(εs))[2]
```

and hence see [`boxed_correlationsum`](@ref) for more information and available keywords.

[^Bueno2007]:
    Bueno-Orovio and Pérez-García, [Enhanced box and prism assisted algorithms for
    computing the correlation dimension. Chaos Solitons & Fractrals, 34(5)
    ](https://doi.org/10.1016/j.chaos.2006.03.043)
"""
function boxassisted_correlation_dim(X::AbstractStateSpaceSet; kwargs...)
    εs, Cs = boxed_correlationsum(X; kwargs...)
    return linear_region(log2.(εs), log2.(Cs))[2]
end

"""
    boxed_correlationsum(X::AbstractStateSpaceSet, εs, r0 = maximum(εs); kwargs...) → Cs

Estimate the box assisted q-order correlation sum `Cs` of `X` for each radius in `εs`,
by splitting the data into boxes of size `r0`
beforehand. This method is much faster than [`correlationsum`](@ref), **provided that** the
box size `r0` is significantly smaller than the attractor length.
Good choices for `r0` are [`estimate_r0_buenoorovio`](@ref) and
[`estimate_r0_theiler`](@ref).

See [`correlationsum`](@ref) for the definition of the correlation sum.

Initial implementation of the algorithm was according to [^Theiler1987].
However, current implementation has been re-written and utilizes histogram handling
from ComplexityMeasures.jl and nearest neighbor searches in discrete spaces from Agents.jl.

    boxed_correlationsum(X::AbstractStateSpaceSet; kwargs...) → εs, Cs

In this method the minimum inter-point distance and [`estimate_r0_buenoorovio`](@ref)
of `X` are used to estimate good `εs` for the calculation, which are also returned.

## Keyword arguments

* `q = 2` : The order of the correlation sum.
* `P = autoprismdim(X)` : The prism dimension.
* `w = 0` : The [Theiler window](@ref).
* `show_progress = false` : Whether to display a progress bar for the calculation.
* `norm = Euclidean()` : Distance norm.

## Description

`C_q(ε)` is calculated for every `ε ∈ εs` and each of the boxes to then be
summed up afterwards. The method of splitting the data into boxes was
implemented according to Theiler[^Theiler1987]. `w` is the [Theiler window](@ref).
`P` is the prism dimension. If `P` is unequal to the dimension of the data, only the
first `P` dimensions are considered for the box distribution (this is called the
prism-assisted version). By default `P` is choosen automatically.

The function is explicitly optimized for `q = 2` but becomes quite slow for `q ≠ 2`.

See [`correlationsum`](@ref) for the definition of `C_q`.

[^Theiler1987]:
    Theiler, [Efficient algorithm for estimating the correlation dimension from a set
    of discrete points. Physical Review A, 36](https://doi.org/10.1103/PhysRevA.36.4456)
"""
function boxed_correlationsum(X; P = 2, kwargs...)
    r0, ε0 = estimate_r0_buenoorovio(X, P)
    εs = MathConstants.e .^ range(log(ε0), log(r0); length = 16)
    Cs = boxed_correlationsum(X, εs, r0; P, kwargs...)
    return εs, Cs
end

function boxed_correlationsum(X, εs, r0 = maximum(εs); P = autoprismdim(X), kwargs...)
    db = data_boxing(X, float(r0), P)
    return _boxed_correlationsum(db, X, εs; r0, kwargs...)
end

boxed_correlationsum(X, e::Real, args...; kwargs...) = boxed_correlationsum(X, [e], args...; kwargs...)[1]

"""
    autoprismdim(X, version = :bueno)

An algorithm to find the ideal choice of a prism dimension for
[`boxed_correlationsum`](@ref). `version = :bueno` uses `P=2`, while
`version = :theiler` uses Theiler's original suggestion.
"""
function autoprismdim(X, version = :bueno)
    D = dimension(X)
    N = length(X)
    if version == :bueno
        return min(D, 2)
    elseif version == :theiler
        if D > 0.75 * log2(N)
            return max(2, ceil(0.5 * log2(N)))
        else
            return D
        end
    else
        error("Unknown method.")
    end
end

################################################################################
# Data boxing and iterating over boxes for neighboring points
################################################################################
"""
    data_boxing(X::StateSpaceSet, r0 [, P::Int]) → boxes_to_contents, hist_size

Distribute `X` into boxes of size `r0`. Return a dictionary, mapping tuples
(cartesian indices of the histogram boxes) into point indices of `X` in the boxes
and the (maximum) size of the boxing scheme (i.e., max dimensions of the histogram).
If `P` is given, only the first `P` dimensions of `X` are considered for constructing
the boxes and distributing the points into them.

Used in: [`boxed_correlationsum`](@ref).
"""
function data_boxing(X, r0::AbstractFloat, P::Int = autoprismdim(X))
    P ≤ dimension(X) || error("Prism dimension has to be ≤ than data dimension.")
    Xreduced = P == dimension(X) ? X : X[:, SVector{P, Int}(1:P)]
    encoding = RectangularBinEncoding(RectangularBinning(r0, true), Xreduced)
    return _data_boxing(Xreduced, encoding)
end

function _data_boxing(X::AbstractStateSpaceSet{D}, encoding) where {D}
    # Create empty array with empty vectors
    boxed_contents = Array{Vector{Int}, D}(undef, encoding.histsize)
    for i in eachindex(boxed_contents); boxed_contents[i] = Int[]; end
    # Loop over points and store them in the bin they are contained in
    for (j, x) in enumerate(X)
        i = encode(encoding, x) # linear index of box in histogram
        if i == -1
            error("$(j)-th point was encoded as -1. Point = $(x)")
        end
        # ci = encoding.ci[i] # cartesian index of box in histogram
        # We actually don't need ci as linear access to multi-dim array is the same
        push!(boxed_contents[i], j)
    end
    li, ci = getproperty.(Ref(encoding), (:li, :ci))
    return DataBoxing(boxed_contents, li, ci)
end

# This struct exists to make iteration more efficient by
# grouping the info together, but also by allowing the use of linear vectors
# instead of dictionaries to go from cartesian index of box in histogram
# to the contents inside the box (i.e., the indices of points in that box)
struct DataBoxing{D}
    boxed_contents::Array{Vector{Int}, D} # content of `i`-th box
    li::LinearIndices{D, NTuple{D, Base.OneTo{Int}}}
    ci::CartesianIndices{D, NTuple{D, Base.OneTo{Int}}}
end

################################################################################
# Correlation sum computation code
################################################################################
# Actual implementation
function _boxed_correlationsum(db::DataBoxing, X, εs;
        w = 0, show_progress = false, q = 2, norm = Euclidean(), r0 = maximum(εs)
    )
    Cs = zeros(eltype(X), length(εs))
    Csdummy = copy(Cs)

    progress = ProgressMeter.Progress(count(!isempty, db.boxed_contents);
        desc = "Boxed correlation sum: ", dt = 1.0, enabled = show_progress
    )
    N = length(X)
    # Skip predicate (theiler window): if `true` skip current point index.
    # Notice that the predicate depends on `q`, because if `q = 2` we can safely
    # skip all points with index `j` less or equal to `i`
    skip = if q == 2
        (i, j) -> j ≤ w + i
    else
        (i, j) -> (i < w + 1) || (i > N - w) || (abs(i - j) ≤ w)
    end
    offsets = chebyshev_offsets(ceil(Int, maximum(εs)/r0), length(size(db.boxed_contents)))
    # We iterate over all existing boxes; for each box, we iterate over
    # all points in the box and all neighboring boxes (offsets added to box coordinate)
    # Note that the `box_index` is also its cartesian index in the histogram
    # TODO: Threading
    for box_index in eachindex(db.boxed_contents)
        indices_in_box = db.boxed_contents[box_index]
        isempty(indices_in_box) && continue # important to skip empty boxes
        # This is a special iterator; for the given box, it iterates over
        # all points in this box and in the neighboring boxes (offsets added)
        nearby_indices_iter = PointsInBoxesIterator(db, box_index, offsets)
        add_to_corrsum!(Cs, Csdummy, εs, X, indices_in_box, nearby_indices_iter, skip, norm, q)
        ProgressMeter.next!(progress)
    end
    # Normalize accordingly
    if q == 2
        return Cs .* (2 / ((N - w) * (N - w - 1)))
    else
        return clamp.((Cs ./ ((N - 2w) * (N - 2w - 1) ^ (q-1))), 0, Inf) .^ (1 / (q-1))
    end
end

function chebyshev_offsets(r::Int, P::Int)
    # Offsets, which are required by the nearest neighbor algorithm, are constants
    # and depend only on `P` (histogram dimension = prism) and the ceiling
    # of the maximum `ε` over the box size. They don't depend on the points themselves.
    # We pre-compute them here once and we are done with it
    hypercube = Iterators.product(repeat([-r:r], P)...)
    offsets = vec([β for β ∈ hypercube])
    # make it guaranteed so that (0s...) offset is first in order
    z = ntuple(i -> 0, Val(P))
    filter!(x -> x ≠ z, offsets)
    pushfirst!(offsets, z)
    return offsets
end

@inbounds function add_to_corrsum!(Cs, Csdummy, εs, X, indices_in_box, nearby_indices_iter, skip, norm, q)
    # first, we iterate over points inside the histogram box
    for i in indices_in_box
        Csdummy .= 0 # reset set count for the given point to 0
        # Then, we iterate over points in current box and all other boxes
        # within radius (in histogram discrete size Chebyshev distance metric)
        @inbounds for j in nearby_indices_iter
            skip(i, j) && continue
            dist = norm(X[i], X[j])
            for k in length(εs):-1:1
                if dist < εs[k]
                    Csdummy[k] += 1
                else
                    break # since `εs` are ordered, we don't have to check for smaller
                end
            end
        end
        if q == 2
            Cs .+= Csdummy
        else
            # the q != 2 formula requires this inner exponentiation
            Cs .+= Csdummy .^ (q-1)
        end
    end
    return Cs
end

################################################################################
# Extremely optimized custom iterator for nearby boxes
################################################################################
# Notice that from creation we know the first box index, and its nubmer
# in the box offseting sequence is by construction 1

# For optinal performance and design we need a different method of starting the iteration
# and another one that continues iteration. Second case uses the explicitly
# known knowledge of `offset_number` being a valid position index.

struct PointsInBoxesIterator{D}
    db::DataBoxing{D}
    origin::Int                       # box we started from, in linear indices
    offsets::Vector{NTuple{D,Int}}    # Result of `chebyshev_offsets`
    L::Int                            # length of `offsets`
end

function PointsInBoxesIterator(db::DataBoxing{D}, origin, offsets) where {D}
    L = length(offsets)
    return PointsInBoxesIterator{D}(db, origin, offsets, L)
end

Base.eltype(::Type{<:PointsInBoxesIterator}) = Int # It returns indices
Base.IteratorSize(::Type{<:PointsInBoxesIterator}) = Base.SizeUnknown()

# Notice that the initial state of the iteration ensures we are in
# a box with indices inside it (as we start with offset = 0)
@inbounds function Base.iterate(
        iter::PointsInBoxesIterator, state = (1, 1, iter.origin)
    )
    db, offsets, L, origin = getproperty.(Ref(iter), (:db, :offsets, :L, :origin))
    offset_number, inner_i, box_index = state
    idxs_in_box::Vector{Int} = db.boxed_contents[box_index]

    if inner_i > length(idxs_in_box)
        # we have exhausted IDs in current box, so we go to next
        offset_number += 1
        # Stop iteration if `box_index` exceeded the amount of positions
        offset_number > L && return nothing
        # Reset count of indices inside current box
        inner_i = 1
        box_cartesian = CartesianIndex(offsets[offset_number] .+ Tuple(db.ci[origin]))
        # Of course, we need to check if we have valid index
        while invalid_access(box_cartesian, db.boxed_contents)
            # if not, again go to next box
            offset_number += 1
            offset_number > L && return nothing
            # The box index is in linear indices; to create the linear index of the
            # nearby (offseted) boxes, we trasform to cartesian, and then back again
            box_cartesian = CartesianIndex(offsets[offset_number] .+ Tuple(db.ci[origin]))
        end
        # Don't forget to convert the box index to linear
        box_index = db.li[CartesianIndex(box_cartesian)]
        idxs_in_box = db.boxed_contents[box_index]
    end
    # We are in a valid box with indices inside it
    id::Int = idxs_in_box[inner_i]
    return (id, (offset_number, inner_i + 1, box_index))
end


# Return `true` if the access to the histogram box with `box_index` is invalid
function invalid_access(box_index, boxed_contents)
    # Check if within bounds of the histogram (for iterating near edges of histogram)
    valid_bounds = checkbounds(Bool, boxed_contents, box_index)
    valid_bounds || return true
    # Then, check if there are points in the histogram box
    empty = @inbounds isempty(boxed_contents[box_index])
    empty && return true
    # If a box exists, it is guaranteed to have at least one point by construction
    return false
end

#######################################################################################
# Good boxsize estimates for boxed correlation sum
#######################################################################################
using Statistics: mean
"""
    estimate_r0_theiler(X::AbstractStateSpaceSet) → r0, ε0
Estimate a reasonable size for boxing the data `X` before calculating the
[`boxed_correlationsum`](@ref) proposed by Theiler[^Theiler1987].
Return the boxing size `r0` and minimum inter-point distance in `X`, `ε0`.

To do so the dimension is estimated by running the algorithm by Grassberger and
Procaccia[^Grassberger1983] with `√N` points where `N` is the number of total
data points. Then the optimal boxsize ``r_0`` computes as
```math
r_0 = R (2/N)^{1/\\nu}
```
where ``R`` is the size of the chaotic attractor and ``\\nu`` is the estimated dimension.

[^Theiler1987]:
    Theiler, [Efficient algorithm for estimating the correlation dimension from a set
    of discrete points. Physical Review A, 36](https://doi.org/10.1103/PhysRevA.36.4456)

[^Grassberger1983]:
    Grassberger and Proccacia, [Characterization of strange attractors, PRL 50 (1983)
    ](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.50.346)
"""
function estimate_r0_theiler(data)
    N = length(data)
    mini, maxi = minmaxima(data)
    R = mean(maxi .- mini)
    # Sample √N datapoints for a rough estimate of the dimension.
    data_sample = data[unique(rand(1:N, ceil(Int, sqrt(N))))] |> StateSpaceSet
    # Define radii for the rough dimension estimate
    min_d, _ = minimum_pairwise_distance(data)
    if min_d == 0
        @warn(
        "Minimum distance in the dataset is zero! Probably because of having data "*
        "with low resolution, or duplicate data points. Setting to `d₊/1000` for now.")
        min_d = R/(10^3)
    end
    lower = log10(min_d)
    εs = 10 .^ range(lower, stop = log10(R), length = 12)
    # Actually estimate the dimension.
    cm = correlationsum(data_sample, εs)
    ν = linear_region(log.(εs), log.(cm), tol = 0.5, warning = false)[2]
    # The combination yields the optimal box size
    r0 = R * (2/N)^(1/ν)
    return r0, min_d
end

"""
    estimate_r0_buenoorovio(X::AbstractStateSpaceSet, P = autoprismdim(X)) → r0, ε0

Estimate a reasonable size for boxing `X`, proposed by
Bueno-Orovio and Pérez-García[^Bueno2007], before calculating the correlation
dimension as presented by Theiler[^Theiler1983].
Return the size `r0` and the minimum interpoint distance `ε0` in the data.

If instead of boxes, prisms
are chosen everything stays the same but `P` is the dimension of the prism.
To do so the dimension `ν` is estimated by running the algorithm by Grassberger
and Procaccia[^Grassberger1983] with `√N` points where `N` is the number of
total data points.
An effective size `ℓ` of the attractor is calculated by boxing a small subset
of size `N/10` into boxes of sidelength `r_ℓ` and counting the number of filled
boxes `η_ℓ`.
```math
\\ell = r_\\ell \\eta_\\ell ^{1/\\nu}
```
The optimal number of filled boxes `η_opt` is calculated by minimising the number
of calculations.
```math
\\eta_\\textrm{opt} = N^{2/3}\\cdot \\frac{3^\\nu - 1}{3^P - 1}^{1/2}.
```
`P` is the dimension of the data or the number of edges on the prism that don't
span the whole dataset.

Then the optimal boxsize ``r_0`` computes as
```math
r_0 = \\ell / \\eta_\\textrm{opt}^{1/\\nu}.
```

[^Bueno2007]:
    Bueno-Orovio and Pérez-García, [Enhanced box and prism assisted algorithms for
    computing the correlation dimension. Chaos Solitons & Fractrals, 34(5)
    ](https://doi.org/10.1016/j.chaos.2006.03.043)

[^Theiler1987]:
    Theiler, [Efficient algorithm for estimating the correlation dimension from a set
    of discrete points. Physical Review A, 36](https://doi.org/10.1103/PhysRevA.36.4456)

[^Grassberger1983]:
    Grassberger and Proccacia, [Characterization of strange attractors, PRL 50 (1983)
    ](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.50.346)
"""
function estimate_r0_buenoorovio(X, P = autoprismdim(X))
    mini, maxi = minmaxima(X)
    N = length(X)
    R = mean(maxi .- mini)
    # The possibility of a bad pick exists, if so, the calculation is repeated.
    ν = zero(eltype(X))
    min_d, _ = minimum_pairwise_distance(X)
    if min_d == 0
        @warn(
        "Minimum distance in the dataset is zero! Probably because of having data "*
        "with low resolution, or duplicate data points. Setting to `d₊/1000` for now.")
        min_d = R/(10^3)
    end

    # Sample N/10 datapoints out of data for rough estimate of effective size.
    sample1 = X[unique(rand(1:N, N÷10))] |> StateSpaceSet
    r_ℓ = R / 10
    η_ℓ = count(!isempty, data_boxing(sample1, r_ℓ, P).boxed_contents)
    r0 = zero(eltype(X))
    while true
        # Sample √N datapoints for rough dimension estimate
        sample2 = X[unique(rand(1:N, ceil(Int, sqrt(N))))] |> StateSpaceSet
        # Define logarithmic series of radii.
        εs = 10.0 .^ range(log10(min_d), log10(R); length = 16)
        # Estimate ν from a sample using the Grassberger Procaccia algorithm.
        cm = correlationsum(sample2, εs)
        ν = linear_region(log.(εs), log.(cm); tol = 0.5, warning = false)[2]
        # Estimate the effictive size of the chaotic attractor.
        ℓ = r_ℓ * η_ℓ^(1/ν)
        # Calculate the optimal number of filled boxes according to Bueno-Orovio
        η_opt = N^(2/3) * ((3^ν - 1/2) / (3^P - 1))^(1/2)
        # The optimal box size is the effictive size divided by the box number
        # to the power of the inverse dimension.
        r0 = ℓ / η_opt^(1/ν)
        !isnan(r0) && break
    end
    if r0 < min_d
        warn("The calculated `r0` box size was smaller than the minimum interpoint " *
        "distance. Please provide `r0` manually. For now, setting `r0` to "*
        "average attractor length divided by 16")
        r0 = max(4min_d, R/16)
    end
    return r0, min_d
end