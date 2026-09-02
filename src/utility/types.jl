"""Utility types"""

const OptionalValue{T} = Union{T,Nothing};

"""
========================
Data specification types
========================
"""

"""
Criteria definition for data specification update
Contains all metadata and bounds information for a specific criteria type
"""
struct UpdateCriteriaInput
    "Unique identifier for the criteria (e.g., 'depth', 'slope')"
    name::String
    "Display title for UI (e.g., 'Depth Range')"
    display_title::String
    "Optional subtitle for additional context"
    display_subtitle::OptionalValue{String}
    "Units of measurement (e.g., 'meters', 'degrees')"
    units::OptionalValue{String}
    "Tooltip text for minimum value input"
    min_tooltip::OptionalValue{String}
    "Tooltip text for maximum value input"
    max_tooltip::OptionalValue{String}
    "Prefix for job payload properties (e.g., 'depth' becomes 'depth_min', 'depth_max')"
    payload_prefix::String
    "Minimum value for this criteria in this region"
    min_val::Float32
    "Maximum value for this criteria in this region"
    max_val::Float32
    "Default minimum value users typically select"
    default_min_val::Float32
    "Default maximum value users typically select"
    default_max_val::Float32
    "MCDA preference direction default (Phase B); mirrored from ReefGuide.jl ASSESSMENT_CRITERIA"
    default_direction::OptionalValue{String}
    "MCDA band-peak default (Phase B); set only when the criterion's direction is `band`"
    default_band_peak::OptionalValue{Float64}
    "MCDA missing-data weight default (Phase B), on the [0,1] score scale"
    default_missing_weight::OptionalValue{Float64}
    "MCDA aggregate weight default (Phase B)"
    default_weight::OptionalValue{Float64}

    # Kwarg constructor
    function UpdateCriteriaInput(;
        name::String,
        display_title::String,
        display_subtitle::OptionalValue{String}=nothing,
        units::OptionalValue{String}=nothing,
        min_tooltip::OptionalValue{String}=nothing,
        max_tooltip::OptionalValue{String}=nothing,
        payload_prefix::String,
        min_val::Number,
        max_val::Number,
        default_min_val::Number,
        default_max_val::Number,
        default_direction::OptionalValue{String}=nothing,
        default_band_peak::Union{Real,Nothing}=nothing,
        default_missing_weight::Union{Real,Nothing}=nothing,
        default_weight::Union{Real,Nothing}=nothing
    )
        return new(
            name,
            display_title,
            display_subtitle,
            units,
            min_tooltip,
            max_tooltip,
            payload_prefix,
            Float32(min_val),
            Float32(max_val),
            Float32(default_min_val),
            Float32(default_max_val),
            default_direction,
            isnothing(default_band_peak) ? nothing : Float64(default_band_peak),
            isnothing(default_missing_weight) ? nothing : Float64(default_missing_weight),
            isnothing(default_weight) ? nothing : Float64(default_weight)
        )
    end
end

"""
Region definition for data specification update
Contains region metadata and all associated criteria for that region
"""
struct UpdateRegionInput
    "Unique identifier for the region (e.g., 'great_barrier_reef')"
    name::String
    "Human-readable display name (e.g., 'Great Barrier Reef')"
    display_name::String
    "Optional description of the region"
    description::OptionalValue{String}
    "List of all criteria available in this region"
    criteria::Vector{UpdateCriteriaInput}

    # Kwarg constructor
    function UpdateRegionInput(;
        name::String,
        display_name::String,
        description::OptionalValue{String}=nothing,
        criteria::Vector{UpdateCriteriaInput}
    )
        return new(
            name,
            display_name,
            description,
            criteria
        )
    end
end

"""
Complete data specification update payload
Contains all regions and their associated criteria
"""
struct DataSpecificationUpdatePayload
    "List of all regions with their criteria definitions"
    regions::Vector{UpdateRegionInput}

    # Kwarg constructor
    function DataSpecificationUpdatePayload(;
        regions::Vector{UpdateRegionInput}
    )
        return new(regions)
    end
end
