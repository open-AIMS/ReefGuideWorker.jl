"""
This is the file where handlers, input and output payloads are registered to
handle jobs for this worker.
"""

# ================
# Type Definitions
# ================

"""
Enum for job types matching the API definition
"""
@enum JobType begin
    SUITABILITY_ASSESSMENT
    REGIONAL_ASSESSMENT
    TEST
    DATA_SPECIFICATION_UPDATE
    FAST_REGIONAL_ASSESSMENT
    FAST_SUITABILITY_ASSESSMENT
end

symbol_to_job_type = Dict(zip(Symbol.(instances(JobType)), instances(JobType)))

"""
Enum for storage schemes matching the API definition
"""
@enum StorageScheme begin
    S3
end

"""
Abstract type for job input payloads
All concrete job input types should inherit from this
"""
abstract type AbstractJobInput end

"""
Abstract type for job output payloads
All concrete job output types should inherit from this
"""
abstract type AbstractJobOutput end

"""
Abstract type for job handler implementations
All concrete job handlers should inherit from this
"""
abstract type AbstractJobHandler end

"""
A context object passed through to a job handler
"""
struct HandlerContext
    "The path to the s3 storage location permitted for writing"
    storage_uri::String
    aws_region::String
    s3_endpoint::OptionalValue{String}
    cache_path::String
    data_path::String
    client::AuthApiClient

    function HandlerContext(;
        storage_uri::String, aws_region::String="ap-southeast-2",
        s3_endpoint::OptionalValue{String}=nothing,
        cache_path::String,
        data_path::String,
        client::AuthApiClient
    )
        return new(storage_uri, aws_region, s3_endpoint, cache_path, data_path, client)
    end
end

"""
Registry mapping job types to handlers, input/output types, and validators
"""
struct JobRegistry
    handlers::Dict{JobType,AbstractJobHandler}
    input_types::Dict{JobType,Type{<:AbstractJobInput}}
    output_types::Dict{JobType,Type{<:AbstractJobOutput}}

    function JobRegistry()
        return new(
            Dict{JobType,AbstractJobHandler}(),
            Dict{JobType,Type{<:AbstractJobInput}}(),
            Dict{JobType,Type{<:AbstractJobOutput}}()
        )
    end
end

# Global registry instance
const JOB_REGISTRY = JobRegistry()

# ======================
# Registration functions
# ======================

"""
Register a job handler for a specific job type
"""
function register_job_handler!(
    job_type::JobType,
    handler::AbstractJobHandler,
    input_type::Type{<:AbstractJobInput},
    output_type::Type{<:AbstractJobOutput}
)
    JOB_REGISTRY.handlers[job_type] = handler
    JOB_REGISTRY.input_types[job_type] = input_type
    JOB_REGISTRY.output_types[job_type] = output_type

    @debug "Registered handler for job type: $job_type"
    return nothing
end

"""
Get the appropriate handler for a job type
"""
function get_job_handler(job_type::JobType)::AbstractJobHandler
    if !haskey(JOB_REGISTRY.handlers, job_type)
        error("No handler registered for job type: $job_type")
    end
    return JOB_REGISTRY.handlers[job_type]
end

#
# Validation functions
#

"""
Parse and validate a job input payload
"""
function validate_job_input(job_type::JobType, raw_payload::Any)
    if !haskey(JOB_REGISTRY.input_types, job_type)
        error("No input type registered for job type: $job_type")
    end

    input_type = JOB_REGISTRY.input_types[job_type]

    try
        # Parse the raw JSON payload into the appropriate type
        return JSON3.read(JSON3.write(raw_payload), input_type)
    catch e
        @error "Input validation failed for job type $job_type" exception = (
            e, catch_backtrace()
        )
        error("Invalid input payload for job type: $job_type")
    end
end

"""
Validate a job output payload
"""
function validate_job_output(job_type::JobType, output::AbstractJobOutput)
    if !haskey(JOB_REGISTRY.output_types, job_type)
        error("No output type registered for job type: $job_type")
    end

    expected_type = JOB_REGISTRY.output_types[job_type]

    if !isa(output, expected_type)
        error("Output payload is not of the correct type for job type: $job_type")
    end

    return output
end

#
# Job processing
#

"""
Process a job using the appropriate handler
"""
function process_job(
    job_type::JobType, input_payload::Any, context::HandlerContext
)::AbstractJobOutput
    # Get the registered handler
    handler = get_job_handler(job_type)

    # Validate and convert input payload
    typed_input = validate_job_input(job_type, input_payload)

    # Process the job
    @debug "Processing job of type: $job_type"
    output = handle_job(handler, typed_input, context)

    # Validate output
    validate_job_output(job_type, output)

    return output
end

#
# ============================================
# TEST - this is an example set of job methods
# ============================================
#

"""
Input payload for TEST job
"""
struct TestInput <: AbstractJobInput
    id::Int64
end

"""
Output payload for TEST job
"""
struct TestOutput <: AbstractJobOutput
end

"""
Handler for TEST jobs
"""
struct TestHandler <: AbstractJobHandler end

"""
Process a TEST job
"""
function handle_job(
    ::TestHandler, input::TestInput, context::HandlerContext
)::TestOutput
    @debug "Processing test job with id: $(input.id)"

    # Simulate processing time
    sleep(10)

    @debug "Finished test job with id: $(input.id)"
    @debug "Could write something to $(context.storage_uri) if desired."

    # This is where the actual job processing would happen
    # For now, we just return a dummy output
    return TestOutput()
end

#
# ===================
# REGIONAL_ASSESSMENT
# ===================
#

"""
Input payload for REGIONAL_ASSESSMENT job

Subset of CRITERIA_ASSESSMENT payload
"""
struct RegionalAssessmentInput <: AbstractJobInput
    # High level config
    "Region for assessment"
    region::String
    "The type of reef, slopes or flats"
    reef_type::String
    # Criteria (all optional - defaulting to min/max of criteria, listed alphabetically)
    depth_min::OptionalValue{Float64}
    depth_max::OptionalValue{Float64}
    high_tide_min::OptionalValue{Float64}
    high_tide_max::OptionalValue{Float64}
    low_tide_min::OptionalValue{Float64}
    low_tide_max::OptionalValue{Float64}
    rugosity_min::OptionalValue{Float64}
    rugosity_max::OptionalValue{Float64}
    slope_min::OptionalValue{Float64}
    slope_max::OptionalValue{Float64}
    turbidity_min::OptionalValue{Float64}
    turbidity_max::OptionalValue{Float64}
    waves_height_min::OptionalValue{Float64}
    waves_height_max::OptionalValue{Float64}
    waves_period_min::OptionalValue{Float64}
    waves_period_max::OptionalValue{Float64}
end

"""
Output payload for REGIONAL_ASSESSMENT job
"""
struct RegionalAssessmentOutput <: AbstractJobOutput
    cog_path::String
end

"""
Handler for REGIONAL_ASSESSMENT jobs
"""
struct RegionalAssessmentHandler <: AbstractJobHandler end

"""
Handler for the regional assessment job.
"""
function handle_job(
    ::RegionalAssessmentHandler, input::RegionalAssessmentInput,
    context::HandlerContext
)::RegionalAssessmentOutput
    @info "Initiating regional assessment task"

    @info "Setting up regional assessment data"
    regional_data::ReefGuide.RegionalData = prepare_target_regional_data(;
        data_path=context.data_path, region_id=input.region
    )
    @info "Done setting up regional assessment data"

    @info "Compiling regional assessment parameters from regional data and input data"
    params = build_regional_assessment_parameters(
        input,
        regional_data
    )
    @info "Done compiling parameters"

    @info "Performing regional assessment"
    regional_assessment_filename = build_regional_assessment_file_path(
        params; ext="tiff", cache_path=context.cache_path
    )
    @debug "COG File name: $(regional_assessment_filename)"

    if !isfile(regional_assessment_filename)
        @debug "File system cache was not hit for this task"
        @debug "$(now()) : Assessing region $(params.region)"
        assessed = ReefGuide.assess_region_quality(params)

        @debug "$(now()) : Writing COG of regional assessment to $(regional_assessment_filename)"
        # TODO would be better to not hardcode these - env variables?
        ReefGuide._write_cog(
            regional_assessment_filename, assessed; tile_size=(256,), num_threads=4
        )
        @debug "$(now()) : Finished writing cog "
    else
        @info "Cache hit - skipping regional assessment process and re-uploading to output!"
    end

    # Now upload this to s3
    client = S3StorageClient(; region=context.aws_region, s3_endpoint=context.s3_endpoint)

    # Output file names
    output_file_name_rel = "regional_assessment.tiff"
    full_s3_target = "$(context.storage_uri)/$(output_file_name_rel)"
    @debug "File paths:" relative = output_file_name_rel absolute = full_s3_target

    @debug "$(now()) : Initiating file upload"
    upload_file(client, regional_assessment_filename, full_s3_target)
    @debug "$(now()) : File upload completed"

    @debug "Finished regional assessment job."
    return RegionalAssessmentOutput(
        output_file_name_rel
    )
end

#
# ======================
# SUITABILITY_ASSESSMENT
# ======================
#

"""
Input payload for SUITABILITY_ASSESSMENT job

NOTE this is a RegionalAssessmentInput (and more) and therefore also an
AbstractJobInput
"""
struct SuitabilityAssessmentInput <: AbstractJobInput
    # High level config
    "Region for assessment"
    region::String
    "The type of reef, slopes or flats"
    reef_type::String
    # Criteria (alphabetical order)
    depth_min::OptionalValue{Float64}
    depth_max::OptionalValue{Float64}
    high_tide_min::OptionalValue{Float64}
    high_tide_max::OptionalValue{Float64}
    low_tide_min::OptionalValue{Float64}
    low_tide_max::OptionalValue{Float64}
    rugosity_min::OptionalValue{Float64}
    rugosity_max::OptionalValue{Float64}
    slope_min::OptionalValue{Float64}
    slope_max::OptionalValue{Float64}
    turbidity_min::OptionalValue{Float64}
    turbidity_max::OptionalValue{Float64}
    waves_height_min::OptionalValue{Float64}
    waves_height_max::OptionalValue{Float64}
    waves_period_min::OptionalValue{Float64}
    waves_period_max::OptionalValue{Float64}
    # Unique to suitability assessment
    threshold::OptionalValue{Int64}
    "Length dimension of target polygon"
    x_dist::Int64
    "Width dimension of target polygon"
    y_dist::Int64
end

"""
Output payload for SUITABILITY_ASSESSMENT job
"""
struct SuitabilityAssessmentOutput <: AbstractJobOutput
    geojson_path::String
end

"""
Handler for SUITABILITY_ASSESSMENT jobs
"""
struct SuitabilityAssessmentHandler <: AbstractJobHandler end

"""
Handler for the suitability assessment job.
"""
function handle_job(
    ::SuitabilityAssessmentHandler, input::SuitabilityAssessmentInput,
    context::HandlerContext)::SuitabilityAssessmentOutput
    @info "Initiating site assessment task"

    @info "Setting up regional assessment data"
    regional_data::ReefGuide.RegionalData = prepare_target_regional_data(;
        data_path=context.data_path, region_id=input.region
    )
    @info "Done setting up regional assessment data"

    @info "Compiling suitability assessment parameters from regional data and job inputs"
    params::ReefGuide.SuitabilityAssessmentParameters = build_suitability_assessment_parameters(
        input,
        regional_data
    )
    @info "Done compiling parameters"

    @debug "Performing site assessment"
    best_sites = ReefGuide.filter_sites(
        ReefGuide.assess_sites(
            params
        )
    )

    @debug "Writing to temporary file"
    geojson_name = "$(tempname()).geojson"
    @debug "File name $(geojson_name)"

    if size(best_sites, 1) == 0
        open(geojson_name, "w") do f
            return JSON.print(f, nothing)
        end
    else
        output_geojson(geojson_name, best_sites)
    end

    # Now upload this to S3
    client = S3StorageClient(; region=context.aws_region, s3_endpoint=context.s3_endpoint)

    # Output file names
    output_file_name_rel = "suitable.geojson"
    full_s3_target = "$(context.storage_uri)/$(output_file_name_rel)"
    @debug "File paths:" relative = output_file_name_rel absolute = full_s3_target

    upload_file(client, geojson_name, full_s3_target)

    # clean up temp file
    if isfile(geojson_name)
        @debug "Cleaned up temp file"
        rm(geojson_name)
    end

    @debug "Finished suitability assessment job."
    return SuitabilityAssessmentOutput(
        output_file_name_rel
    )
end

#
# ===================================================
# FAST_REGIONAL_ASSESSMENT / FAST_SUITABILITY_ASSESSMENT
# ===================================================
#
# Fast/preview variants of the two assessments above, narrowed to a spatial
# scope (bbox or user-drawn polygon) so a viewport-sized request returns
# quickly instead of processing the entire region. See
# `.claude/plans/2026-07-31_slow_fast_assessment_feature.md`.
#

"""
Discriminated union mirroring the TS `spatialScopeSchema`
(`reefguide/packages/types/src/jobs.ts`), tagged on `type`.

Concrete variants: [`BBoxScopeInput`](@ref), [`PolygonScopeInput`](@ref).
"""
abstract type SpatialScopeInput end

"""
Bbox spatial scope input. `bounds` is `[minLon, minLat, maxLon, maxLat]`,
matching the `bbox` variant of the TS `spatialScopeSchema`.
"""
struct BBoxScopeInput <: SpatialScopeInput
    type::String
    bounds::NTuple{4,Float64}
end

"""
GeoJSON Polygon geometry, mirroring `GeoJSONPolygonSchema`
(`reefguide/packages/types/src/api.ts`).
"""
struct GeoJSONPolygonInput
    type::String
    coordinates::Vector{Vector{Vector{Float64}}}
end

"""
Polygon spatial scope input, matching the `polygon` variant of the TS
`spatialScopeSchema`.
"""
struct PolygonScopeInput <: SpatialScopeInput
    type::String
    geometry::GeoJSONPolygonInput
end

# Tag-based (dis)union dispatch for JSON3, keyed on the `type` field - mirrors
# the TS `z.discriminatedUnion('type', ...)`. JSON3 re-exports StructTypes
# internally without `export`ing it, so it's referenced qualified here rather
# than adding a direct `StructTypes` dependency for a single trait
# registration.
JSON3.StructTypes.StructType(::Type{SpatialScopeInput}) = JSON3.StructTypes.AbstractType()
JSON3.StructTypes.subtypekey(::Type{SpatialScopeInput}) = :type
function JSON3.StructTypes.subtypes(::Type{SpatialScopeInput})
    return (bbox=BBoxScopeInput, polygon=PolygonScopeInput)
end

"""
Input payload for FAST_REGIONAL_ASSESSMENT job

Same shape as RegionalAssessmentInput, plus a `scope` narrowing the
assessment to a bbox or user-drawn polygon.
"""
struct FastRegionalAssessmentInput <: AbstractJobInput
    # High level config
    "Region for assessment"
    region::String
    "The type of reef, slopes or flats"
    reef_type::String
    # Criteria (all optional - defaulting to min/max of criteria, listed alphabetically)
    depth_min::OptionalValue{Float64}
    depth_max::OptionalValue{Float64}
    high_tide_min::OptionalValue{Float64}
    high_tide_max::OptionalValue{Float64}
    low_tide_min::OptionalValue{Float64}
    low_tide_max::OptionalValue{Float64}
    rugosity_min::OptionalValue{Float64}
    rugosity_max::OptionalValue{Float64}
    slope_min::OptionalValue{Float64}
    slope_max::OptionalValue{Float64}
    turbidity_min::OptionalValue{Float64}
    turbidity_max::OptionalValue{Float64}
    waves_height_min::OptionalValue{Float64}
    waves_height_max::OptionalValue{Float64}
    waves_period_min::OptionalValue{Float64}
    waves_period_max::OptionalValue{Float64}
    "Spatial scope (bbox or polygon) narrowing the assessment"
    scope::SpatialScopeInput
end

"""
Input payload for FAST_SUITABILITY_ASSESSMENT job

Same shape as SuitabilityAssessmentInput, plus a `scope` narrowing the
assessment to a bbox or user-drawn polygon.
"""
struct FastSuitabilityAssessmentInput <: AbstractJobInput
    # High level config
    "Region for assessment"
    region::String
    "The type of reef, slopes or flats"
    reef_type::String
    # Criteria (alphabetical order)
    depth_min::OptionalValue{Float64}
    depth_max::OptionalValue{Float64}
    high_tide_min::OptionalValue{Float64}
    high_tide_max::OptionalValue{Float64}
    low_tide_min::OptionalValue{Float64}
    low_tide_max::OptionalValue{Float64}
    rugosity_min::OptionalValue{Float64}
    rugosity_max::OptionalValue{Float64}
    slope_min::OptionalValue{Float64}
    slope_max::OptionalValue{Float64}
    turbidity_min::OptionalValue{Float64}
    turbidity_max::OptionalValue{Float64}
    waves_height_min::OptionalValue{Float64}
    waves_height_max::OptionalValue{Float64}
    waves_period_min::OptionalValue{Float64}
    waves_period_max::OptionalValue{Float64}
    # Unique to suitability assessment
    threshold::OptionalValue{Int64}
    "Length dimension of target polygon"
    x_dist::Int64
    "Width dimension of target polygon"
    y_dist::Int64
    "Spatial scope (bbox or polygon) narrowing the assessment"
    scope::SpatialScopeInput
end

"""
Handler for FAST_REGIONAL_ASSESSMENT jobs

Output payload is the same shape as REGIONAL_ASSESSMENT (`RegionalAssessmentOutput`).
"""
struct FastRegionalAssessmentHandler <: AbstractJobHandler end

"""
Handler for FAST_SUITABILITY_ASSESSMENT jobs

Output payload is the same shape as SUITABILITY_ASSESSMENT (`SuitabilityAssessmentOutput`).
"""
struct FastSuitabilityAssessmentHandler <: AbstractJobHandler end

"""
Handler for the fast/preview regional assessment job. Identical to the
regional assessment handler, except regional data is loaded narrowed to
`input.scope` (see `prepare_fast_target_regional_data`) and the on-disk cache
key includes the scope (see `fast_regional_assessment_params_hash`) so two
different viewports never collide in the cache.
"""
function handle_job(
    ::FastRegionalAssessmentHandler, input::FastRegionalAssessmentInput,
    context::HandlerContext
)::RegionalAssessmentOutput
    @info "Initiating fast regional assessment task"

    scope = build_spatial_scope(input.scope)

    @info "Setting up scoped regional assessment data"
    regional_data::ReefGuide.RegionalData = prepare_fast_target_regional_data(;
        data_path=context.data_path, region_id=input.region, scope=scope
    )
    @info "Done setting up scoped regional assessment data"

    # Guard: if the scope doesn't intersect any reef data, fail with a clear message
    # rather than crashing inside assess_region_quality.
    scoped_slope_table = regional_data.regions[input.region].slope_table
    if nrow(scoped_slope_table) == 0
        throw(
            ErrorException(
                "No reef data found within the requested scope for region '$(input.region)'. " *
                "Try selecting a larger area or an area that overlaps with known reef data."
            )
        )
    end
    @info "Scoped slope table has $(nrow(scoped_slope_table)) rows"

    @info "Compiling regional assessment parameters from regional data and input data"
    params = build_regional_assessment_parameters(
        regional_job_from_fast_regional_job(input),
        regional_data
    )
    @info "Done compiling parameters"

    @info "Performing fast regional assessment"
    regional_assessment_filename = build_fast_regional_assessment_file_path(
        params, input.scope; ext="tiff", cache_path=context.cache_path
    )
    @debug "COG File name: $(regional_assessment_filename)"

    if !isfile(regional_assessment_filename)
        @debug "File system cache was not hit for this task"
        @debug "$(now()) : Fast-assessing region $(params.region)"
        assessed = ReefGuide.assess_region_quality(params)

        @debug "$(now()) : Writing COG of fast regional assessment to $(regional_assessment_filename)"
        # TODO would be better to not hardcode these - env variables?
        ReefGuide._write_cog(
            regional_assessment_filename, assessed; tile_size=(256,), num_threads=4
        )
        @debug "$(now()) : Finished writing cog "
    else
        @info "Cache hit - skipping fast regional assessment process and re-uploading to output!"
    end

    # Now upload this to s3
    client = S3StorageClient(; region=context.aws_region, s3_endpoint=context.s3_endpoint)

    # Output file names
    output_file_name_rel = "fast_regional_assessment.tiff"
    full_s3_target = "$(context.storage_uri)/$(output_file_name_rel)"
    @debug "File paths:" relative = output_file_name_rel absolute = full_s3_target

    @debug "$(now()) : Initiating file upload"
    upload_file(client, regional_assessment_filename, full_s3_target)
    @debug "$(now()) : File upload completed"

    @debug "Finished fast regional assessment job."
    return RegionalAssessmentOutput(
        output_file_name_rel
    )
end

"""
Handler for the fast/preview suitability assessment job. Identical to the
suitability assessment handler, except regional data is loaded narrowed to
`input.scope` (see `prepare_fast_target_regional_data`). Mirrors
SUITABILITY_ASSESSMENT in not caching results to disk.
"""
function handle_job(
    ::FastSuitabilityAssessmentHandler, input::FastSuitabilityAssessmentInput,
    context::HandlerContext)::SuitabilityAssessmentOutput
    @info "Initiating fast site assessment task"

    scope = build_spatial_scope(input.scope)

    @info "Setting up scoped regional assessment data"
    regional_data::ReefGuide.RegionalData = prepare_fast_target_regional_data(;
        data_path=context.data_path, region_id=input.region, scope=scope
    )
    @info "Done setting up scoped regional assessment data"

    # Guard: if the scope doesn't intersect any reef data, fail with a clear message.
    scoped_slope_table = regional_data.regions[input.region].slope_table
    if nrow(scoped_slope_table) == 0
        throw(
            ErrorException(
                "No reef data found within the requested scope for region '$(input.region)'. " *
                "Try selecting a larger area or an area that overlaps with known reef data."
            )
        )
    end
    @info "Scoped slope table has $(nrow(scoped_slope_table)) rows"

    @info "Compiling suitability assessment parameters from regional data and job inputs"
    params::ReefGuide.SuitabilityAssessmentParameters = build_suitability_assessment_parameters(
        suitability_job_from_fast_suitability_job(input),
        regional_data
    )
    @info "Done compiling parameters"

    @debug "Performing fast site assessment"
    best_sites = ReefGuide.filter_sites(
        ReefGuide.assess_sites(
            params
        )
    )

    @debug "Writing to temporary file"
    geojson_name = "$(tempname()).geojson"
    @debug "File name $(geojson_name)"

    if size(best_sites, 1) == 0
        open(geojson_name, "w") do f
            return JSON.print(f, nothing)
        end
    else
        output_geojson(geojson_name, best_sites)
    end

    # Now upload this to S3
    client = S3StorageClient(; region=context.aws_region, s3_endpoint=context.s3_endpoint)

    # Output file names
    output_file_name_rel = "suitable.geojson"
    full_s3_target = "$(context.storage_uri)/$(output_file_name_rel)"
    @debug "File paths:" relative = output_file_name_rel absolute = full_s3_target

    upload_file(client, geojson_name, full_s3_target)

    # clean up temp file
    if isfile(geojson_name)
        @debug "Cleaned up temp file"
        rm(geojson_name)
    end

    @debug "Finished fast suitability assessment job."
    return SuitabilityAssessmentOutput(
        output_file_name_rel
    )
end

#
# ========================
# DATA_SPECIFICATION_UPDATE
# ========================
#

"""
Input payload for DATA_SPECIFICATION_UPDATE job

Simple input with optional cache buster to force updates
"""
struct DataSpecificationUpdateInput <: AbstractJobInput
    "Cache buster to force update"
    cache_buster::OptionalValue{Int64}
end

"""
Output payload for DATA_SPECIFICATION_UPDATE job

Empty output as results are lodged directly to the database
"""
struct DataSpecificationUpdateOutput <: AbstractJobOutput
end

"""
Handler for DATA_SPECIFICATION_UPDATE jobs
"""
struct DataSpecificationUpdateHandler <: AbstractJobHandler end

"""
Handler for the data specification update job.

This job fetches the current regional data and updates the API database
with the latest criteria bounds and metadata for all regions.
"""
function handle_job(
    ::DataSpecificationUpdateHandler,
    input::DataSpecificationUpdateInput,
    context::HandlerContext
)::DataSpecificationUpdateOutput
    @info "Initiating data specification update task"

    # Build the data specification payload from regional data
    payload = build_data_specification_payload(context.data_path)

    @info "Built payload for $(length(payload.regions)) regions"

    # POST the payload to the API endpoint
    @info "Posting data specification update to API"
    # TODO add client to context
    post_data_specification_update(payload, context.client)
    @info "Successfully posted data specification update"

    @info "Data specification update completed successfully"

    return DataSpecificationUpdateOutput()
end

#
# ====
# INIT
# ====
#

#
# Register the job types when the module loads
#
function __init__()
    # Register the TEST job handler
    register_job_handler!(
        TEST,
        TestHandler(),
        TestInput,
        TestOutput
    )

    # Register the SUITABILITY_ASSESSMENT job handler
    register_job_handler!(
        SUITABILITY_ASSESSMENT,
        SuitabilityAssessmentHandler(),
        SuitabilityAssessmentInput,
        SuitabilityAssessmentOutput
    )

    # Register the REGIONAL_ASSESSMENT job handler
    register_job_handler!(
        REGIONAL_ASSESSMENT,
        RegionalAssessmentHandler(),
        RegionalAssessmentInput,
        RegionalAssessmentOutput
    )

    # Register the FAST_REGIONAL_ASSESSMENT job handler
    register_job_handler!(
        FAST_REGIONAL_ASSESSMENT,
        FastRegionalAssessmentHandler(),
        FastRegionalAssessmentInput,
        RegionalAssessmentOutput
    )

    # Register the FAST_SUITABILITY_ASSESSMENT job handler
    register_job_handler!(
        FAST_SUITABILITY_ASSESSMENT,
        FastSuitabilityAssessmentHandler(),
        FastSuitabilityAssessmentInput,
        SuitabilityAssessmentOutput
    )

    #Register the DATA_SPECIFICATION_UPDATE job handler
    register_job_handler!(
        DATA_SPECIFICATION_UPDATE,
        DataSpecificationUpdateHandler(),
        DataSpecificationUpdateInput,
        DataSpecificationUpdateOutput
    )

    @debug "Jobs module initialized with handlers"
end
