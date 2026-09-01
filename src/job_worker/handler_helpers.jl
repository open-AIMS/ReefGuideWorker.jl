"""
Helpers for job handlers which interrupt main workflow.

For example, converting between job system interfaces and assessment interfaces.
"""

"""
Build regional assessment parameters from user input and regional data.

Creates a parameter set for regional assessment by merging user-specified
criteria bounds with regional defaults. Validates that the specified region
exists. At least one parameter for a criteria must be specified (min|max) for
it to be considered; a specified criterion the region has no data for is
skipped with a warning rather than failing the job.

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

    for criteria in ReefGuide.ASSESSMENT_CRITERIA_LIST
        criteria_id = criteria.id
        user_min = getproperty(input, Symbol("$(criteria.payload_prefix)min"))
        user_max = getproperty(input, Symbol("$(criteria.payload_prefix)max"))

        # only include a criteria if its min | max is specified.
        if (isnothing(user_min) && isnothing(user_max))
            continue
        end

        bounds = get(regional_bounds, criteria_id, nothing)
        if isnothing(bounds)
            # The region has no data for this criterion (e.g. a layer with no coverage
            # was dropped from the bounds sidecar), so there is nothing to filter on -
            # skip the user's bound for it rather than failing the whole job.
            @warn "Ignoring user-specified criteria with no data in this region" criteria_id region =
                input.region
            continue
        end

        merged = merge_bounds(
            user_min,
            user_max,
            bounds
        )
        if isnothing(merged)
            throw(ErrorException("merge_bounds failed for $(criteria_id) criteria"))
        end

        regional_criteria[criteria_id] = ReefGuide.BoundedCriteria(;
            metadata=criteria,
            bounds=merged
        )
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
        suitability_job.high_tide_min,
        suitability_job.high_tide_max,
        suitability_job.low_tide_min,
        suitability_job.low_tide_max,
        suitability_job.rugosity_min,
        suitability_job.rugosity_max,
        suitability_job.slope_min,
        suitability_job.slope_max,
        suitability_job.turbidity_min,
        suitability_job.turbidity_max,
        suitability_job.waves_height_min,
        suitability_job.waves_height_max,
        suitability_job.waves_period_min,
        suitability_job.waves_period_max
    )
end

"""
=====================================================
FAST_REGIONAL_ASSESSMENT / FAST_SUITABILITY_ASSESSMENT helpers
=====================================================
"""

"""
Converts a fast regional job's `scope` GeoJSON polygon into a
GeoInterface-compatible geometry, as expected by `ReefGuide.PolygonScope`.
"""
function build_geo_interface_polygon(geometry::GeoJSONPolygonInput)
    rings = [[(pt[1], pt[2]) for pt in ring] for ring in geometry.coordinates]
    return GeometryOps.GI.Wrappers.Polygon(rings)
end

"""
Translates a `BBoxScopeInput` (parsed job payload scope) into a
`ReefGuide.BBoxScope`.

!!! note
    Not annotated `::ReefGuide.SpatialScope` - see the note on
    `prepare_fast_target_regional_data` (`utility/regions_criteria_setup.jl`)
    for why: that type doesn't exist in the currently-pinned ReefGuide.jl
    version, and a return-type annotation is evaluated at method-definition
    time, so it would break precompilation.
"""
function build_spatial_scope(scope::BBoxScopeInput)
    min_lon, min_lat, max_lon, max_lat = scope.bounds
    return ReefGuide.BBoxScope(min_lon, min_lat, max_lon, max_lat)
end

"""
Translates a `PolygonScopeInput` (parsed job payload scope) into a
`ReefGuide.PolygonScope`. See the note on `build_spatial_scope(::BBoxScopeInput)`
for why this isn't annotated `::ReefGuide.SpatialScope`.
"""
function build_spatial_scope(scope::PolygonScopeInput)
    return ReefGuide.PolygonScope(build_geo_interface_polygon(scope.geometry))
end

"""
Converts parameters from a fast regional job into a regular regional job
(the `scope` field is handled separately - see `build_spatial_scope` -
since `RegionalAssessmentInput` has no `scope` field).
"""
function regional_job_from_fast_regional_job(
    fast_job::FastRegionalAssessmentInput
)::RegionalAssessmentInput
    return RegionalAssessmentInput(
        fast_job.region,
        fast_job.reef_type,
        fast_job.depth_min,
        fast_job.depth_max,
        fast_job.high_tide_min,
        fast_job.high_tide_max,
        fast_job.low_tide_min,
        fast_job.low_tide_max,
        fast_job.rugosity_min,
        fast_job.rugosity_max,
        fast_job.slope_min,
        fast_job.slope_max,
        fast_job.turbidity_min,
        fast_job.turbidity_max,
        fast_job.waves_height_min,
        fast_job.waves_height_max,
        fast_job.waves_period_min,
        fast_job.waves_period_max
    )
end

"""
Converts parameters from a fast suitability job into a regular suitability
job (the `scope` field is handled separately - see `build_spatial_scope` -
since `SuitabilityAssessmentInput` has no `scope` field).
"""
function suitability_job_from_fast_suitability_job(
    fast_job::FastSuitabilityAssessmentInput
)::SuitabilityAssessmentInput
    return SuitabilityAssessmentInput(
        fast_job.region,
        fast_job.reef_type,
        fast_job.depth_min,
        fast_job.depth_max,
        fast_job.high_tide_min,
        fast_job.high_tide_max,
        fast_job.low_tide_min,
        fast_job.low_tide_max,
        fast_job.rugosity_min,
        fast_job.rugosity_max,
        fast_job.slope_min,
        fast_job.slope_max,
        fast_job.turbidity_min,
        fast_job.turbidity_max,
        fast_job.waves_height_min,
        fast_job.waves_height_max,
        fast_job.waves_period_min,
        fast_job.waves_period_max,
        fast_job.threshold,
        fast_job.x_dist,
        fast_job.y_dist
    )
end

"""
Returns hash components for a spatial scope. Correctness-critical: two
different viewports/polygons must not collide in the fast-assessment cache
(see `.claude/plans/2026-07-31_slow_fast_assessment_feature.md`).
"""
function get_hash_components_from_scope(scope::BBoxScopeInput)::Vector{String}
    return ["bbox", string.(scope.bounds)...]
end

function get_hash_components_from_scope(scope::PolygonScopeInput)::Vector{String}
    ring_strings = [
        join((join(pt, ",") for pt in ring), ";") for ring in scope.geometry.coordinates
    ]
    return ["polygon", join(ring_strings, "|")]
end

"""
Generate a deterministic hash string for a fast regional assessment.

Same as `regional_assessment_params_hash`, plus the spatial `scope`, so
two different viewports produce distinct cache entries.

# Arguments
- `params::RegionalAssessmentParameters` : Assessment parameters to hash
- `scope::SpatialScopeInput` : The job's spatial scope (bbox or polygon)

# Returns
String hash suitable for use in cache file names.
"""
function fast_regional_assessment_params_hash(
    params::ReefGuide.RegionalAssessmentParameters, scope::SpatialScopeInput
)::String
    @debug "Generating hash for fast regional assessment parameters" region = params.region

    hash_components = [
        params.region,
        get_hash_components_from_scope(scope)...,
        get_hash_components_from_regional_criteria(params.regional_criteria)...
    ]

    hash_string = build_hash_from_components(hash_components)

    @debug "Generated fast regional assessment parameters hash" hash = hash_string components_count = length(
        hash_components
    )

    return hash_string
end

"""
Generate a deterministic hash string for a fast suitability assessment.

Same as `suitability_assessment_params_hash`, plus the spatial `scope`, so
two different viewports produce distinct cache entries.

# Arguments
- `params::SuitabilityAssessmentParameters` : Assessment parameters to hash
- `scope::SpatialScopeInput` : The job's spatial scope (bbox or polygon)

# Returns
String hash suitable for use in cache file names.
"""
function fast_suitability_assessment_params_hash(
    params::ReefGuide.SuitabilityAssessmentParameters, scope::SpatialScopeInput
)::String
    @debug "Generating hash for fast suitability assessment parameters" region =
        params.region threshold =
        params.suitability_threshold x_dist = params.x_dist y_dist = params.y_dist

    hash_components = [
        params.region,
        string(params.suitability_threshold),
        string(params.x_dist),
        string(params.y_dist),
        get_hash_components_from_scope(scope)...,
        get_hash_components_from_regional_criteria(params.regional_criteria)...
    ]

    hash_string = build_hash_from_components(hash_components)

    @debug "Generated fast suitability assessment parameters hash" hash = hash_string components_count = length(
        hash_components
    )

    return hash_string
end

"""
Build predictable file path for fast regional assessment results in the
configured cache location. Mirrors `build_regional_assessment_file_path`,
but keys the cache file name off `fast_regional_assessment_params_hash`
(which includes `scope`) so two different viewports never collide.

# Arguments
- `params::RegionalAssessmentParameters` : Regional assessment parameters
- `scope::SpatialScopeInput` : The job's spatial scope (bbox or polygon)
- `ext::String` : File extension for the cache file
- `cache_path::String` : Location to cache

# Returns
String path to cache file location.
"""
function build_fast_regional_assessment_file_path(
    params::ReefGuide.RegionalAssessmentParameters,
    scope::SpatialScopeInput;
    ext::String,
    cache_path::String
)::String
    @debug "Building file path for fast regional assessment cache" region = params.region ext

    param_hash = fast_regional_assessment_params_hash(params, scope)
    filename = "$(param_hash)_$(params.region)_fast_regional_assessment.$(ext)"
    file_path = joinpath(cache_path, filename)

    @debug "Built fast regional assessment file path" file_path region = params.region hash =
        param_hash

    return file_path
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
        min=(!isnothing(user_min) ? user_min : criteria.bounds.min),
        max=(!isnothing(user_max) ? user_max : criteria.bounds.max)
    )

    @debug """
    Merged bounds for $(criteria.metadata.id)
      min_val = $(bounds.min)
      max_val = $(bounds.max)
      user_specified_min = $(!isnothing(user_min))
      user_specified_max = $(!isnothing(user_max))
    """

    return bounds
end

"""
=================================
DATA_SPECIFICATION_UPDATE helpers
=================================
"""

"""
Build the data specification update payload from regional data
Transforms the RegionalData structure into the format expected by the API
"""
function build_data_specification_payload_for_region(;
    region_data::ReefGuide.RegionalDataEntry
)::UpdateRegionInput
    @debug "Building data specification payload for region" region_id =
        region_data.region_id
    # Name to use
    region_name = region_data.region_metadata.display_name
    @debug "Region display name" region_name

    # Build criteria list
    criteria_list = Vector{UpdateCriteriaInput}()
    @debug "Building criteria list for region" criteria_count = length(region_data.criteria)

    # Iterate through all criteria in this region
    for (criteria_name, bounded_criteria) in region_data.criteria
        @debug "Processing criteria: $criteria_name in $(region_data.region_id)"

        # Extract bounds and metadata
        bounds = bounded_criteria.bounds
        metadata = bounded_criteria.metadata

        # Determine default bounds (use metadata default_bounds if available, otherwise use main bounds)
        default_bounds = something(metadata.default_bounds, bounds)

        # Create the criteria input struct
        criteria_input = UpdateCriteriaInput(;
            name=criteria_name,
            display_title=metadata.display_label,
            display_subtitle=metadata.subtitle,
            units=metadata.units,
            min_tooltip=metadata.min_tooltip,
            max_tooltip=metadata.max_tooltip,
            payload_prefix=metadata.payload_prefix,
            min_val=bounds.min,
            max_val=bounds.max,
            default_min_val=default_bounds.min,
            default_max_val=default_bounds.max
        )

        push!(criteria_list, criteria_input)
    end

    # Create the region input struct
    # Note: We'll use the region name as both name and display_name for now
    return UpdateRegionInput(;
        # use the ID as the name - this is a unique ID
        name=region_data.region_id,
        # TODO would be nice to have a display name here
        display_name=string(region_name),
        # TODO missing description for now
        description=string(region_name),
        criteria=criteria_list
    )
end

"""
Build the data specification update payload from regional data
Transforms the RegionalData structure into the format expected by the API
"""
function build_data_specification_payload(
    data_path::String
)::DataSpecificationUpdatePayload
    @debug "Building data specification payload from regional data"

    # Build up the region list
    regions = Vector{UpdateRegionInput}()

    # Iterate through all regions in the REGIONS list from reefguide
    for region_metadata in ReefGuide.REGIONS
        @debug "Loading region metadata" region_id = region_metadata.id
        # Load region data
        region_data = ReefGuide.load_target_region(;
            region_id=region_metadata.id, data_source_directory=data_path
        )
        @debug "Finished loading region data" region_id = region_metadata.id
        @debug "Processing region -> data spec: $region_metadata.id"
        # Build the payload
        region_input = build_data_specification_payload_for_region(;
            region_data
        )
        # Append to the output list
        push!(regions, region_input)
    end

    @debug "Built payload with $(length(regions)) regions"

    return DataSpecificationUpdatePayload(; regions=regions)
end

"""
Post the data specification update to the API
Requires admin credentials and posts to the admin endpoint
"""
function post_data_specification_update(
    payload::DataSpecificationUpdatePayload, client::AuthApiClient
)
    @debug "Creating API client for data specification update"

    @debug "Serializing payload to JSON"

    try
        @debug "Posting to /admin/data-specification endpoint"
        response = HTTPPost(client, "/admin/data-specification", JSON3.write(payload))
        @debug "Received response: $(response)"
    catch e
        @error "Failed to post data specification update to API" exception = (
            e, catch_backtrace()
        )
        throw(e)
    end
end
