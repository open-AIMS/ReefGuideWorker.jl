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
function initialise_data_with_cache(;
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

        # Try disk cache second (faster than full reload)
        disk_data = check_existing_regional_data_from_disk(; cache_path=cache_path)
        if !isnothing(disk_data)
            REGIONAL_DATA = disk_data
            return nothing
        end
    else
        @info "Cache invalidation forced - reloading from source files"
    end

    # No cache available or forced invalidation - load from source
    @info "Loading regional data from source files (no cache available)"
    regional_data = ReefGuide.initialise_data(data_path)

    # Update global cache
    REGIONAL_DATA = regional_data

    # Save to disk for future use
    @info "Saving regional data to disk cache" cache_path
    try
        # Ensure cache directory exists
        mkpath(cache_path)

        serialize(
            joinpath(cache_path, REGIONAL_DATA_CACHE_FILENAME),
            regional_data
        )
        @info "Successfully saved regional data cache to disk"
    catch e
        @warn "Failed to save regional data cache to disk" error = e
    end

    return nothing
end

"""
Get regional data with automatic cache management.

Primary interface for accessing regional data. Handles initialization
and caching automatically.

# Arguments
- `data_path::String` : Path to the regional data source files
- `cache_path::String` : Directory where cache files are stored

# Returns
`ReefGuide.RegionalData` struct containing all regional information.
"""
function get_regional_data(; data_path::String, cache_path::String)::ReefGuide.RegionalData
    @debug "Getting regional data with automatic cache management" data_path cache_path

    # Ensure data is loaded (with caching)
    initialise_data_with_cache(; data_path=data_path, cache_path=cache_path)

    # Return cached data
    return REGIONAL_DATA
end
