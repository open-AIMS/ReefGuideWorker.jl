using Dates
using HTTP
using JSON3
using JSON
using Logging
using AWSS3
using AWS
using Random
using JSONWebTokens
using Minio
using Statistics

# HTTP.jl's `StatusError` is defined in the `HTTP.Exceptions` submodule. Reaching it
# via `HTTP.ExceptionRequest.StatusError` (a re-imported binding on a client-layer
# submodule) is not resolvable in the juliac AOT build and throws `UndefVarError` the
# first time a request handler's `catch` branch runs. Bind the concrete type eagerly
# at module-compile time and match against that instead.
const HTTPStatusError = HTTP.Exceptions.StatusError

include("config.jl")
include("ecs.jl")
include("http_client.jl")
include("handlers.jl")
include("storage_client.jl")
include("worker.jl")

# Additions
include("handler_helpers.jl")
