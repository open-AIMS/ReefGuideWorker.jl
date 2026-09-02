"""
Helpers for job handlers which interrupt main workflow.

For example, converting between job system interfaces and assessment interfaces.
"""

"MCDA preference directions accepted on the request path (Phase B)."
const VALID_MCDA_DIRECTIONS = (:lower_is_better, :higher_is_better, :band)

"""
Parse a user-supplied MCDA `direction` string into a `Symbol`, rejecting the job
with a clear error if it is not one of [`VALID_MCDA_DIRECTIONS`](@ref). The Zod
enum in `@reefguide/types` is the only other guard, so an out-of-band value that
reaches the worker (e.g. a direct API call) must fail loudly rather than silently
falling back to the criterion default.
"""
function parse_mcda_direction(raw::AbstractString, criteria_id)::Symbol
    sym = Symbol(raw)
    if sym ∉ VALID_MCDA_DIRECTIONS
        throw(
            ErrorException(
                "Invalid MCDA direction '$(raw)' for criteria $(criteria_id); expected one of " *
                join(string.(VALID_MCDA_DIRECTIONS), ", ")
            )
        )
    end
    return sym
end

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
        prefix = criteria.payload_prefix
        user_min = getproperty(input, Symbol("$(prefix)min"))
        user_max = getproperty(input, Symbol("$(prefix)max"))
        # MCDA scoring config (Phase B) - each optional, nothing => criterion default
        user_direction = getproperty(input, Symbol("$(prefix)direction"))
        user_band_peak = getproperty(input, Symbol("$(prefix)band_peak"))
        user_missing_weight = getproperty(input, Symbol("$(prefix)missing_weight"))
        user_weight = getproperty(input, Symbol("$(prefix)weight"))

        # Include a criterion if the user touched either its bounds or its scoring
        # config; a scoring-only override still needs the criterion in the ruleset.
        if all(
            isnothing,
            (
                user_min,
                user_max,
                user_direction,
                user_band_peak,
                user_missing_weight,
                user_weight
            )
        )
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

        direction =
            isnothing(user_direction) ? criteria.direction :
            parse_mcda_direction(user_direction, criteria_id)
        band_peak =
            isnothing(user_band_peak) ? criteria.band_peak : Float64(user_band_peak)

        # A `band` preference needs a peak; if the request overrides `direction` to
        # `band` for a criterion whose metadata carries no `band_peak`, reject
        # rather than emit a silently degenerate score (mirrors decision D).
        if direction === :band && isnothing(band_peak)
            throw(
                ErrorException(
                    "MCDA direction 'band' for criteria $(criteria_id) requires a band_peak; " *
                    "none supplied and the criterion has no default"
                )
            )
        end

        regional_criteria[criteria_id] = ReefGuide.BoundedCriteria(;
            metadata=criteria,
            bounds=merged,
            direction=direction,
            band_peak=band_peak,
            missing_weight=isnothing(user_missing_weight) ? 0.0f0 :
                           Float32(user_missing_weight),
            weight=isnothing(user_weight) ? 1.0f0 : Float32(user_weight)
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
        suitability_job.waves_period_max,
        # MCDA scoring config (Phase B) - trailing block, must match struct field order
        suitability_job.depth_direction,
        suitability_job.depth_band_peak,
        suitability_job.depth_missing_weight,
        suitability_job.depth_weight,
        suitability_job.high_tide_direction,
        suitability_job.high_tide_band_peak,
        suitability_job.high_tide_missing_weight,
        suitability_job.high_tide_weight,
        suitability_job.low_tide_direction,
        suitability_job.low_tide_band_peak,
        suitability_job.low_tide_missing_weight,
        suitability_job.low_tide_weight,
        suitability_job.rugosity_direction,
        suitability_job.rugosity_band_peak,
        suitability_job.rugosity_missing_weight,
        suitability_job.rugosity_weight,
        suitability_job.slope_direction,
        suitability_job.slope_band_peak,
        suitability_job.slope_missing_weight,
        suitability_job.slope_weight,
        suitability_job.turbidity_direction,
        suitability_job.turbidity_band_peak,
        suitability_job.turbidity_missing_weight,
        suitability_job.turbidity_weight,
        suitability_job.waves_height_direction,
        suitability_job.waves_height_band_peak,
        suitability_job.waves_height_missing_weight,
        suitability_job.waves_height_weight,
        suitability_job.waves_period_direction,
        suitability_job.waves_period_band_peak,
        suitability_job.waves_period_missing_weight,
        suitability_job.waves_period_weight
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
        fast_job.waves_period_max,
        # MCDA scoring config (Phase B) - trailing block, must match struct field order
        fast_job.depth_direction,
        fast_job.depth_band_peak,
        fast_job.depth_missing_weight,
        fast_job.depth_weight,
        fast_job.high_tide_direction,
        fast_job.high_tide_band_peak,
        fast_job.high_tide_missing_weight,
        fast_job.high_tide_weight,
        fast_job.low_tide_direction,
        fast_job.low_tide_band_peak,
        fast_job.low_tide_missing_weight,
        fast_job.low_tide_weight,
        fast_job.rugosity_direction,
        fast_job.rugosity_band_peak,
        fast_job.rugosity_missing_weight,
        fast_job.rugosity_weight,
        fast_job.slope_direction,
        fast_job.slope_band_peak,
        fast_job.slope_missing_weight,
        fast_job.slope_weight,
        fast_job.turbidity_direction,
        fast_job.turbidity_band_peak,
        fast_job.turbidity_missing_weight,
        fast_job.turbidity_weight,
        fast_job.waves_height_direction,
        fast_job.waves_height_band_peak,
        fast_job.waves_height_missing_weight,
        fast_job.waves_height_weight,
        fast_job.waves_period_direction,
        fast_job.waves_period_band_peak,
        fast_job.waves_period_missing_weight,
        fast_job.waves_period_weight
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
        # MCDA scoring config (Phase B) - trailing block, before the suitability tail
        fast_job.depth_direction,
        fast_job.depth_band_peak,
        fast_job.depth_missing_weight,
        fast_job.depth_weight,
        fast_job.high_tide_direction,
        fast_job.high_tide_band_peak,
        fast_job.high_tide_missing_weight,
        fast_job.high_tide_weight,
        fast_job.low_tide_direction,
        fast_job.low_tide_band_peak,
        fast_job.low_tide_missing_weight,
        fast_job.low_tide_weight,
        fast_job.rugosity_direction,
        fast_job.rugosity_band_peak,
        fast_job.rugosity_missing_weight,
        fast_job.rugosity_weight,
        fast_job.slope_direction,
        fast_job.slope_band_peak,
        fast_job.slope_missing_weight,
        fast_job.slope_weight,
        fast_job.turbidity_direction,
        fast_job.turbidity_band_peak,
        fast_job.turbidity_missing_weight,
        fast_job.turbidity_weight,
        fast_job.waves_height_direction,
        fast_job.waves_height_band_peak,
        fast_job.waves_height_missing_weight,
        fast_job.waves_height_weight,
        fast_job.waves_period_direction,
        fast_job.waves_period_band_peak,
        fast_job.waves_period_missing_weight,
        fast_job.waves_period_weight,
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
    cache_path::String,
    infix::String=""
)::String
    @debug "Building file path for fast regional assessment cache" region = params.region ext

    param_hash = fast_regional_assessment_params_hash(params, scope)
    filename = "$(param_hash)_$(params.region)_fast_regional_assessment$(infix).$(ext)"
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
    cache_path::String,
    infix::String=""
)::String
    @debug "Building file path for regional assessment cache" region = params.region ext

    param_hash = regional_assessment_params_hash(params)
    filename = "$(param_hash)_$(params.region)_regional_assessment$(infix).$(ext)"
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

        # Create the criteria input struct.
        # MCDA scoring defaults (Phase B): direction/band_peak come from the
        # criterion metadata; missing_weight/weight are the BoundedCriteria
        # constructor defaults (no per-criterion override exists in metadata yet).
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
            default_max_val=default_bounds.max,
            default_direction=string(metadata.direction),
            default_band_peak=metadata.band_peak,
            default_missing_weight=0.0,
            default_weight=1.0
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
