module ReefGuideWorker

# Precompilation
using PrecompileSignatures: @precompile_signatures
# using PrecompileTools

# System imports
using Base.Threads

# Critical import for reefguide assessment methods
using ReefGuide

# Collections
using DataFrames

# Serialisation/deserialisation
using Serialization

# Utilities and helpers for assessments
include("utility/utility.jl")

# Worker system
include("job_worker/job_worker.jl")

"""
Create and initialize a worker from the environment.

This is a blocking operation until the worker times out.
"""
function start_worker()
    @info "Initializing worker from environment variables..."
    worker = create_worker_from_env()

    @info "Warming up regional data (expensive op which is cached in memory and disk)"
    get_regional_data(;
        data_path=worker.config.data_path,
        cache_path=worker.config.cache_path
    )

    # NOTE: you can perform additional setup here if needed. For example, you
    # might want to initialise data, caches or clients.

    # Worker launch
    @info "Starting worker loop from ReefGuideWorker.jl with $(Threads.nthreads()) threads."
    start(worker)
    @info "Worker closed itself..."
end

export start_worker

# Auto-generate precompilation signatures for ReefGuideWorker
@precompile_signatures(ReefGuideWorker)

end
