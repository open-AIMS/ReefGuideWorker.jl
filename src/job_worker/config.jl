"""
Manages config for the worker node.
"""

"""
Configuration for the worker
These are populated from the environment and are only loaded when the worker
component is launched.
"""
struct WorkerConfig
    "API connection settings"
    api_endpoint::String
    "Worker behavior"
    job_types::Vector{String}
    "Auth settings - these target the reefguide-web-api providing necessary credentials for creating jobs etc"
    username::String
    password::String
    "Polling configuration"
    poll_interval_ms::Int64
    idle_timeout_ms::Int64
    "AWS Region"
    aws_region::String
    "S3 Endpoint for local S3 compatibility"
    s3_endpoint::OptionalValue{String}
    "What is the path to cache files into?"
    cache_path::String
    "What is the path to the data files?"
    data_path::String

    # Kwarg constructor
    function WorkerConfig(;
        api_endpoint::String,
        job_types::Vector{String},
        username::String,
        password::String,
        aws_region::String="ap-southeast-2",
        # Polling interval 2 second by default
        poll_interval_ms::Int64=2000,
        # Idle timeout 5 minutes by default
        idle_timeout_ms::Int64=5 * 60 * 1000,
        s3_endpoint::OptionalValue{String}=nothing,
        cache_path::String,
        data_path::String
    )
        return new(
            api_endpoint,
            job_types,
            username,
            password,
            poll_interval_ms,
            idle_timeout_ms,
            aws_region,
            s3_endpoint,
            cache_path,
            data_path
        )
    end
end

"""
Validation error for config values
"""
struct ConfigValidationError <: Exception
    field::String
    message::String
end

Base.showerror(io::IO, e::ConfigValidationError) = print(
    io, "ConfigValidationError: $(e.field) - $(e.message)"
)

"""
Validates a URL string
"""
function validate_url(url::String, field_name::String)
    # Basic URL validation - could be enhanced with regex
    if !startswith(url, "http://") && !startswith(url, "https://")
        throw(ConfigValidationError(field_name, "Invalid URL format: $url"))
    end
    return url
end

"""
Validates and parses an integer from string
"""
function parse_int(value::String, field_name::String, min_value::Int=nothing)
    try
        parsed = parse(Int, value)
        if !isnothing(min_value) && parsed < min_value
            throw(ConfigValidationError(field_name, "Value must be at least $min_value"))
        end
        return parsed
    catch e
        if isa(e, ArgumentError)
            throw(ConfigValidationError(field_name, "Cannot parse '$value' as integer"))
        end
        rethrow(e)
    end
end

"""
Gets an environment variable with validation
"""
function get_env(key::String, required::Bool=true)
    value = Base.get(ENV, key, nothing)
    if isnothing(value) && required
        throw(ConfigValidationError(key, "Required environment variable not set"))
    end
    return value
end

"""
Load configuration from environment variables
"""
function load_config_from_env()::WorkerConfig
    # Fetch and validate required environment variables

    # API Endpoint
    api_endpoint = "$(get_env("API_ENDPOINT"))/api"
    validate_url(api_endpoint, "API_ENDPOINT")

    # Job types
    job_types_str = get_env("JOB_TYPES")
    job_types = String.(strip.(split(job_types_str, ',')))
    if isempty(job_types) || any(isempty, job_types)
        throw(
            ConfigValidationError(
                "JOB_TYPES", "At least one non-empty job type must be specified"
            )
        )
    end

    data_path = get_env("DATA_PATH")
    if isempty(data_path)
        throw(ConfigValidationError("DATA_PATH", "Must supply a data path"))
    end

    cache_path = get_env("CACHE_PATH")
    if isempty(cache_path)
        throw(ConfigValidationError("CACHE_PATH", "Must supply a cache path"))
    end

    # Username and password
    username = get_env("WORKER_USERNAME")
    if isempty(username)
        throw(ConfigValidationError("WORKER_USERNAME", "Username cannot be empty"))
    end
    password = get_env("WORKER_PASSWORD")
    if isempty(password)
        throw(ConfigValidationError("WORKER_PASSWORD", "Password cannot be empty"))
    end

    # Get AWS region with default and warning
    aws_region = get_env("AWS_REGION", false)
    if isnothing(aws_region) || isempty(aws_region)
        aws_region = "ap-southeast-2"
        @warn "AWS_REGION environment variable not set, defaulting to $(aws_region)"
    end

    # Get S3 endpoint
    s3_endpoint = get_env("S3_ENDPOINT", false)

    # Optional environment variables with defaults (2 seconds)
    poll_interval_ms::Int64 = parse(
        Int64, something(get_env("POLL_INTERVAL_MS", false), string(2 * 1000))
    )
    # (5 min)
    idle_timeout_ms::Int64 = parse(
        Int64, something(get_env("IDLE_TIMEOUT_MS", false), string(5 * 60 * 1000))
    )

    # Create and return the config object using keyword arguments
    return WorkerConfig(;
        api_endpoint,
        job_types,
        username,
        password,
        poll_interval_ms,
        idle_timeout_ms,
        aws_region,
        s3_endpoint,
        cache_path,
        data_path
    )
end

"""
Create a Worker instance from environment variables
"""
function create_worker_from_env()::WorkerService
    # Load configuration from environment variables
    config = load_config_from_env()

    # Create credentials and API client
    credentials = Credentials(config.username, config.password)
    http_client = AuthApiClient(config.api_endpoint, credentials)

    # Get the ECS task metadata
    identifiers::TaskIdentifiers = get_task_metadata_safe()

    # Create and return worker instance
    return WorkerService(config, http_client, identifiers)
end
