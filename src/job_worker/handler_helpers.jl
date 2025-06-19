"""
Helpers for job handlers which interrupt main workflow. 

For example, converting between job system interfaces and assessment interfaces.
"""

# Parameter mapping: criteria_id => (min_field, max_field) or nothing
const PARAM_MAP::Dict{String,OptionalValue{Tuple{Symbol,Symbol}}} = Dict(
    "Depth" => (:depth_min, :depth_max),
    "Slope" => (:slope_min, :slope_max),
    "Turbidity" => nothing,  # Not user-configurable
    "WavesHs" => (:waves_height_min, :waves_height_max),
    "WavesTp" => (:waves_period_min, :waves_period_max),
    "Rugosity" => (:rugosity_min, :rugosity_max)
)

"""
Build regional assessment parameters from user input and regional data.

Creates a complete parameter set for regional assessment by merging user-specified
criteria bounds with regional defaults. Validates that the specified region exists.

# Arguments
- `input::RegionalAssessmentInput` : User input containing assessment parameters
- `regional_data::ReefGuide.RegionalData` : Complete regional data for validation and defaults

# Returns
`ReefGuide.RegionalAssessmentParameters` struct ready for assessment execution.

# Throws
- `ErrorException` : If specified region is not found in regional data
"""
function build_regional_assessment_parameters(
    input::RegionalAssessmentInput,
    regional_data::ReefGuide.RegionalData
)::ReefGuide.RegionalAssessmentParameters
    @info "Building regional assessment parameters" region = input.region

    # Validate region exists
    if !haskey(regional_data.regions, input.region)
        available_regions = collect(keys(regional_data.regions))
        @error "Region not found in regional data" region = input.region available_regions
        throw(
            ErrorException(
                "Regional data did not have data for region $(input.region). Available regions: $(join(available_regions, ", "))"
            )
        )
    end

    region_data = regional_data.regions[input.region]
    regional_criteria::ReefGuide.BoundedCriteriaDict = Dict()
    regional_bounds::ReefGuide.BoundedCriteriaDict = region_data.criteria

    for (criteria_id, possible_symbols) in PARAM_MAP
        bounds = get(regional_bounds, criteria_id, nothing)
        user_min =
            isnothing(possible_symbols) ? nothing :
            getproperty(input, first(possible_symbols))
        user_max =
            isnothing(possible_symbols) ? nothing :
            getproperty(input, last(possible_symbols))

        merged = merge_bounds(
            user_min,
            user_max,
            bounds
        )
        if !isnothing(merged)
            regional_criteria[criteria_id] = ReefGuide.BoundedCriteria(;
                metadata=ReefGuide.ASSESSMENT_CRITERIA[criteria_id],
                bounds=merged
            )
        end
    end

    return ReefGuide.RegionalAssessmentParameters(;
        region=input.region,
        regional_criteria,
        region_data
    )
end

"""
Build suitability assessment parameters from user input and regional data.

Creates a complete parameter set for suitability assessment by merging user-specified
criteria bounds with regional defaults. Includes spatial dimensions for polygon analysis.

# Arguments
- `input::SuitabilityAssessmentInput` : User input containing assessment parameters and spatial dimensions
- `regional_data::ReefGuide.RegionalData` : Complete regional data for validation and defaults

# Returns
`SuitabilityAssessmentParameters` struct ready for assessment execution.

# Throws
- `ErrorException` : If specified region is not found in regional data
"""
function build_suitability_assessment_parameters(
    input::SuitabilityAssessmentInput,
    regional_data::ReefGuide.RegionalData
)::ReefGuide.SuitabilityAssessmentParameters
    @info "Building suitability assessment parameters" region = input.region x_dist =
        input.x_dist y_dist = input.y_dist

    @debug "Building regional parameters first"
    regional_input = regional_job_from_suitability_job(input)
    regional_parameters = build_regional_assessment_parameters(
        regional_input,
        regional_data
    )
    # Extract threshold with default fallback
    threshold =
        !isnothing(input.threshold) ? input.threshold :
        ReefGuide.DEFAULT_SUITABILITY_THRESHOLD
    @debug "Extending regional parameters with suitability inputs x_dist and ydist" x =
        input.x_dist y = input.y_dist
    return ReefGuide.SuitabilityAssessmentParameters(;
        region=regional_parameters.region,
        regional_criteria=regional_parameters.regional_criteria,
        region_data=regional_parameters.region_data,
        suitability_threshold=Int64(threshold),
        x_dist=input.x_dist,
        y_dist=input.y_dist
    )
end

"""
Converts parameters from a suitability job into a regional job
"""
function regional_job_from_suitability_job(
    suitability_job::SuitabilityAssessmentInput
)::RegionalAssessmentInput
    return RegionalAssessmentInput(
        suitability_job.region,
        suitability_job.reef_type,
        suitability_job.depth_min,
        suitability_job.depth_max,
        suitability_job.slope_min,
        suitability_job.slope_max,
        suitability_job.rugosity_min,
        suitability_job.rugosity_max,
        suitability_job.waves_period_min,
        suitability_job.waves_period_max,
        suitability_job.waves_height_min,
        suitability_job.waves_height_max
    )
end

"""
Generate a deterministic hash string for RegionalAssessmentParameters.

Creates a consistent hash based on assessment parameters that can be used
for cache file naming. Same parameters will always produce the same hash.

# Arguments
- `params::RegionalAssessmentParameters` : Assessment parameters to hash

# Returns
String hash suitable for use in cache file names.
"""
function regional_assessment_params_hash(
    params::ReefGuide.RegionalAssessmentParameters
)::String
    @debug "Generating hash for regional assessment parameters" region = params.region

    # Create hash input from key parameters
    hash_components = [
        params.region,
        # spread result list of components from regional criteria
        get_hash_components_from_regional_criteria(params.regional_criteria)...
    ]

    # Create deterministic hash
    hash_string = build_hash_from_components(hash_components)

    @debug "Generated assessment parameters hash" hash = hash_string components_count = length(
        hash_components
    )

    return hash_string
end

"""
Generate a deterministic hash string for SuitabilityAssessmentParameters.

Creates a consistent hash based on assessment parameters that can be used
for cache file naming. Same parameters will always produce the same hash.

# Arguments
- `params::SuitabilityAssessmentParameters` : Assessment parameters to hash

# Returns
String hash suitable for use in cache file names.
"""
function suitability_assessment_params_hash(
    params::ReefGuide.SuitabilityAssessmentParameters
)::String
    @debug "Generating hash for suitability assessment parameters" region = params.region threshold =
        params.suitability_threshold x_dist = params.x_dist y_dist = params.y_dist

    # Create hash input from key parameters including spatial dimensions
    hash_components = [
        params.region,
        string(params.suitability_threshold),
        string(params.x_dist),
        string(params.y_dist)
    ]

    # Add criteria bounds to hash (only non-nothing criteria)
    hash_components::Vector{String} = [
        hash_components;
        get_hash_components_from_regional_criteria(params.regional_criteria)
    ]

    # Create deterministic hash
    hash_string = build_hash_from_components(hash_components)

    @debug "Generated suitability parameters hash" hash = hash_string components_count = length(
        hash_components
    )

    return hash_string
end

"""
Build predictable file path for regional assessment results in configured cache
location.

Creates a complete file path for caching regional assessment results using the
configured cache directory and deterministic parameter-based naming.

# Arguments
- `params::RegionalAssessmentParameters` : Regional assessment parameters
- `ext::String` : File extension for the cache file
- `cache_path::String` : Location to cache

# Returns
String path to cache file location.
"""
function build_regional_assessment_file_path(
    params::ReefGuide.RegionalAssessmentParameters;
    ext::String,
    cache_path::String
)::String
    @debug "Building file path for regional assessment cache" region = params.region ext

    param_hash = regional_assessment_params_hash(params)
    filename = "$(param_hash)_$(params.region)_regional_assessment.$(ext)"
    file_path = joinpath(cache_path, filename)

    @debug "Built regional assessment file path" file_path region = params.region hash =
        param_hash

    return file_path
end

"""
Merge user-specified bounds with regional defaults.

Creates bounds using user values where provided, falling back to regional 
bounds for unspecified values. Returns nothing if regional criteria is not available.

# Arguments
- `user_min::OptionalValue{Float64}` : User-specified minimum value (optional)
- `user_max::OptionalValue{Float64}` : User-specified maximum value (optional)  
- `regional_criteria::OptionalValue{RegionalCriteriaEntry}` : Regional criteria with default bounds (optional)

# Returns
`Bounds` struct with merged values, or `nothing` if regional criteria unavailable.
"""
function merge_bounds(
    user_min::OptionalValue{Float64},
    user_max::OptionalValue{Float64},
    criteria::OptionalValue{ReefGuide.BoundedCriteria}
)::OptionalValue{ReefGuide.Bounds}
    if isnothing(criteria)
        return nothing
    end

    bounds = ReefGuide.Bounds(;
        min=!isnothing(user_min) ? user_min : criteria.bounds.min,
        max=!isnothing(user_max) ? user_max : criteria.bounds.max
    )

    @debug "Merged bounds" min_val = bounds.min max_val = bounds.max user_specified_min =
        !isnothing(user_min) user_specified_max = !isnothing(user_max)

    return bounds
end
