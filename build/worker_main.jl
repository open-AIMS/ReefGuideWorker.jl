# build/worker_main.jl -- juliac --output-exe entry point for reefguide-worker
#
# Untrimmed juliac build (no --trim): AOT-compiles what's statically
# inferable from ReefGuideWorker.start_worker() and keeps the full dynamic
# compiler embedded, falling back to normal JIT for anything it can't
# resolve. Unlike a --trim=safe build, this does not require rewriting
# ReefGuideWorker's JSON3/Dict-based job dispatch or its __init__-populated
# job registry -- see .claude/plans/ReefGuide-compilation.md for why.
#
# Behavior is otherwise identical to the existing container entrypoint:
#   julia --project=@app -e 'using ReefGuideWorker; ReefGuideWorker.start_worker()'

using ReefGuideWorker

function main(ARGS::Vector{String})::Cint
    ReefGuideWorker.start_worker()
    return Cint(0)
end

Base.@main
