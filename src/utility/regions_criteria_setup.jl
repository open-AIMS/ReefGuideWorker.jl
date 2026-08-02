"""
Manages the regional data cache and initialisation process
"""

# =============================================================================
# Constants and Configuration
# =============================================================================

const REGIONAL_DATA_CACHE_FILENAME = "regional_cache_v2.dat"

# GLOBAL variable to store regional data cache
REGIONAL_DATA::OptionalValue{ReefGuide.RegionalData} = nothing

# =============================================================================
# Cache management
# =============================================================================

"""
Check if regional data exists in memory cache.

# Returns
`RegionalData` if available in memory, `nothing` otherwise.
"""
function check_existing_regional_data_from_memory()::OptionalValue{ReefGuide.RegionalData}
    global REGIONAL_DATA
    if !isnothing(REGIONAL_DATA)
        @debug "Regional data found in memory cache"
        return REGIONAL_DATA
    end
    @debug "No regional data in memory cache"
    return nothing
end

"""
Check if regional data cache exists on disk and attempt to load it.

# Arguments
- `cache_path::String` : Directory where cache files are stored

# Returns
`RegionalData` if successfully loaded from disk, `nothing` otherwise.
"""
function check_existing_regional_data_from_disk(;
    cache_path::String
)::OptionalValue{ReefGuide.RegionalData}
    # Construct cache file path
    reg_cache_filename = joinpath(cache_path, REGIONAL_DATA_CACHE_FILENAME)

    if isfile(reg_cache_filename)
        @info "Loading regional data from disk cache" cache_file = reg_cache_filename
        try
            data = deserialize(reg_cache_filename)
            @info "Successfully loaded regional data from disk cache"
            return data
        catch err
            @warn "Failed to deserialize regional data cache - removing corrupted file" cache_file =
                reg_cache_filename error = err
            # Remove corrupted cache file
            rm(reg_cache_filename)
        end
    else
        @debug "No disk cache file found" expected_path = reg_cache_filename
    end

    # No cache available or load failed
    return nothing
end

"""
Initialize regional data with caching support.

Attempts to load from memory cache, then disk cache, before falling back
to full data initialization. Handles cache invalidation and saves new data to disk.

# Arguments
- `data_path::String` : Path to the regional data source files
- `cache_path::String` : Directory where cache files are stored
- `force_cache_invalidation::Bool` : If true, bypass all caches and reload data
"""
function initialize_data_with_cache(;
    data_path::String, cache_path::String, force_cache_invalidation::Bool=false
)
    @info "Initializing regional data with caching" force_cache_invalidation data_path cache_path

    # Access global cache variable
    global REGIONAL_DATA

    if !force_cache_invalidation
        # Try memory cache first (fastest)
        local_data = check_existing_regional_data_from_memory()
        if !isnothing(local_data)
            REGIONAL_DATA = local_data
            return nothing
        end
    else
        @info "Cache invalidation forced - reloading from source files"
    end

    # No cache available or forced invalidation - load from source
    # and update global cache
    @info "Loading regional data from source files (no cache available)"
    REGIONAL_DATA = ReefGuide.initialize_data(;
        data_source_directory=data_path,
        # Disable regional data loading
        handle_regions=false
    )

    return nothing
end

"""
Get regional data with automatic cache management.

Primary interface for accessing regional data. Handles initialization
and caching automatically.

NOTE: does not by default initialise any regional data.

# Arguments
- `data_path::String` : Path to the regional data source files
- `cache_path::String` : Directory where cache files are stored

# Returns
`ReefGuide.RegionalData` struct containing regional info.
"""
function setup_shared_regional_data(;
    data_path::String, cache_path::String
)::ReefGuide.RegionalData
    @debug "Getting regional data with automatic cache management" data_path cache_path

    # Ensure data is loaded (with caching)
    ts = @elapsed initialize_data_with_cache(; data_path=data_path, cache_path=cache_path)
    @info "Took $(ts) seconds to initialize"

    # Return cached data
    return REGIONAL_DATA
end

"""
Dispels regional dictionary, then loads and sets up a specific region in the
data dictionary

# Arguments
- `data_path::String` : Path to the regional data source files
- `region_id` : The region to load up

# Returns
`ReefGuide.RegionalData` struct containing regional info.
"""
function prepare_target_regional_data(;
    data_path::String,
    region_id::String
)::ReefGuide.RegionalData
    # Access global cache variable
    global REGIONAL_DATA

    # Check if we already have the loaded region - great success!
    if haskey(REGIONAL_DATA.regions, region_id)
        @info "Region $region_id already loaded in memory cache - skipping load"
        return REGIONAL_DATA
    end

    # Dispel all old data
    empty!(REGIONAL_DATA.regions)

    # Build the new entry into dict
    try
        REGIONAL_DATA.regions[region_id] = ReefGuide.load_target_region(;
            data_source_directory=data_path,
            region_id=region_id
        )
    catch e
        @error "Failed to setup regional data dictionary" region_id = region_id error = e
        rethrow(e)
    end

    # Return updated in-memory cache
    return REGIONAL_DATA
end

"""
Loads a single region narrowed to a spatial scope, for the fast/preview
assessment path.

Deliberately does NOT read from or write to the shared `REGIONAL_DATA`
in-memory cache used by `prepare_target_regional_data`: that cache holds one
full (unscoped) region per entry, keyed only by `region_id`, and is reused
verbatim on a cache hit. A scoped load must never be stored there (a later
full-region request would incorrectly receive scoped/narrowed data) and must
never read a cached full-region entry back as if it were scoped (defeats the
purpose of narrowing). Each call loads its own throwaway
`ReefGuide.RegionalData` containing just the requested, scoped region.

# Arguments
- `data_path::String` : Path to the regional data source files
- `region_id` : The region to load
- `scope` : A `ReefGuide.SpatialScope` (bbox or polygon) to narrow the region to

# Returns
`ReefGuide.RegionalData` struct containing only `region_id`, scoped.

!!! note
    `scope` is intentionally left untyped rather than annotated
    `::ReefGuide.SpatialScope`. `SpatialScope`/`BBoxScope`/`PolygonScope` are
    new in an unreleased ReefGuide.jl (see `Project.toml` compat bump to
    `0.2.0`, still resolving to `0.1.12` in `Manifest.toml` pending
    registration); a type annotation referencing `ReefGuide.SpatialScope` is
    evaluated at method-definition time and would break precompilation
    against the currently-pinned version. Tighten this to
    `scope::ReefGuide.SpatialScope` once ReefGuide.jl is bumped past 0.2.0.
"""
function prepare_fast_target_regional_data(;
    data_path::String,
    region_id::String,
    scope
)::ReefGuide.RegionalData
    try
        entry = ReefGuide.load_target_region(;
            data_source_directory=data_path,
            region_id=region_id,
            scope=scope
        )
        return ReefGuide.RegionalData(;
            regions=Dict(region_id => entry),
            reef_outlines=DataFrame()
        )
    catch e
        @error "Failed to setup scoped regional data" region_id = region_id error = e
        rethrow(e)
    end
end
