#==============================================================================
# ReefGuide Worker Base Image
#==============================================================================
# This Dockerfile creates a Julia-based container image for the ReefGuide Worker
# application. It provides a complete Julia environment with the ReefGuideWorker
# package installed from source as a development dependency.
#
# Usage: 
#    Build> docker build -t reefguide-worker . 
#    Run> docker build -t reefguide-worker . 
#==============================================================================

# See https://hub.docker.com/_/julia for valid versions.
ARG JULIA_VERSION="1.11.6"

FROM ${BASE_IMAGE}

# Redeclare
ARG BASE_IMAGE

# Record the actual base image used from the FROM command as label in the
# compiled image
LABEL org.opencontainers.image.base.name=${BASE_IMAGE}


# Update all pre-installed OS packages (to get security updates) and add a few
# extra utilities
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    apt-get update \
    && apt-get -y upgrade \
    && apt-get install --no-install-recommends -y \
    git \
    less \
    nano \
    gdal-bin \
    libgdal-dev \
    libfftw3-dev \
    openssl \
    libssl-dev \
    ca-certificates \
    && apt-get clean \
    && apt-get autoremove --purge \
    && rm -rf /var/lib/apt/lists/*

# Tweak the JULIA_DEPOT_PATH setting so that our shared environments will end up
# in a user-agnostic location, not in ~/.julia => /root/.julia which is the
# default. See
# https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_DEPOT_PATH
# This allows apps derived from this image to drop privileges and run as
# non-root user accounts, but still activate environments configured by this
# dockerfile.
ENV JULIA_DEPOT_PATH=/usr/local/share/julia

# Ensure the @app environment is in the load path for Julia, so that apps
# derived from this image can access any packages installed to there. (See
# https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_LOAD_PATH)
ENV JULIA_LOAD_PATH="@:@app:@v#.#:@stdlib"

# This tells Julia's package manager to use the CLI installation of Git rather
# than an internal lib version - this works better with auth for example in
# CI/CD environments
ENV JULIA_PKG_USE_CLI_GIT=true

# Coerce Julia to build across multiple targets. See:
# https://docs.julialang.org/en/v1/devdocs/sysimg/#Specifying-multiple-system-image-targets
# Alternate set that was found to initially alleviate excessive
# (re)precompilation issues on AWS at expense of very long build times...
# x86_64;haswell;skylake;skylake-avx512;tigerlake
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1);znver4,-rdrnd,base(1)"

# Prepare an empty @app Julia environment for derived images to use - this is
# created in the shared depot path
RUN mkdir -p "${JULIA_DEPOT_PATH}" && \
    chmod 0755 "${JULIA_DEPOT_PATH}"

# Copy project and manifest - includes Manifest-v1.11 etc
COPY Project.toml Manifest*.toml ./

# SentryIntegration.jl fork is not on Julia registry, requiring this step
RUN julia --project=@app \
    -e 'using Pkg; Pkg.add(url="https://github.com/toolpath/SentryIntegration.jl", rev="main");'

# Install ReefGuideWorker from source and configure it as a development
# package in the @app shared environment.
COPY ./src src
RUN julia --project=@app -e \
    'using Pkg; \
    Pkg.develop(PackageSpec(path=pwd())); \
    Pkg.instantiate(); \
    Pkg.precompile();'

# By default, drops the user into a  julia shell with ReefGuideWorker activated
ENTRYPOINT ["julia", "--project=@app", "-e"]

# Derived applications should override the command e.g. to start
CMD ["using ReefGuideWorker; ReefGuideWorker.start_worker()"]
