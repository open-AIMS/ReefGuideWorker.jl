# See https://hub.docker.com/_/julia for valid versions.
ARG JULIA_VERSION="1.11.5"

#------------------------------------------------------------------------------
# internal-base build target: julia with OS updates and an empty @app
# Julia environment prepared for use. NOT intended for standalone use.
#------------------------------------------------------------------------------
FROM julia:${JULIA_VERSION}-bookworm AS internal-base

# Record the actual base image used from the FROM command as label in the compiled image
ARG BASE_IMAGE="julia:${JULIA_VERSION}-bookworm"
LABEL org.opencontainers.image.base.name=${BASE_IMAGE}

# Update all pre-installed OS packages (to get security updates)
# and add a few extra utilities
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
# in a user-agnostic location, not in ~/.julia => /root/.julia which is the default.
# See https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_DEPOT_PATH
# This allows apps derived from this image to drop privileges and run as non-root
# user accounts, but still activate environments configured by this dockerfile.
ENV JULIA_DEPOT_PATH="/usr/local/share/julia"
ENV PRJ_PATH="/usr/local/share/julia/environments/app"
ENV JULIA_PKG_USE_CLI_GIT=true

# Coerce Julia to build across multiple targets
# Generic targets taken from: cpu_targets taken from:
# https://docs.julialang.org/en/v1/devdocs/sysimg/#Specifying-multiple-system-image-targets
ENV JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)

# Alternate set that was found to initially alleviate issues on AWS at expense of very
# long build times.
# ENV JULIA_CPU_TARGET=x86_64;haswell;skylake;skylake-avx512;tigerlake

# Prepare an empty @app Julia environment for derived images to use - this is created in the shared depot path
RUN mkdir -p "${JULIA_DEPOT_PATH}" && \
    chmod 0755 "${JULIA_DEPOT_PATH}" && \
    julia -e 'using Pkg; Pkg.activate("app", shared=true)'

# Ensure the @app environment is in the load path for Julia, so that apps derived
# from this image can access any packages installed to there.
# (See https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_LOAD_PATH)
ENV JULIA_LOAD_PATH="@:@app:@v#.#:@stdlib"

# Copy project and manifest - includes Manifest-v1.11 etc
COPY Project.toml Manifest*.toml ./

# Install ReefGuideWorker from source and configure it as a development
# package in the @app shared environment.
# Should be v speedy if the .toml file is unchanged, because all the
# dependencies *should* already be installed.
COPY ./src src
RUN julia --project=@app \
    -e 'using Pkg; \
    Pkg.add("MKL"); \
    Pkg.develop(PackageSpec(path=pwd())); \
    Pkg.precompile(); \
    using ReefGuideWorker;'

# Run Julia commands by default as the container launches.
# Derived applications should override the command.
ENTRYPOINT ["julia", "--project=@app"]

#------------------------------------------------------------------------------
# app-src build target: installs directly from source files in this repo.
#------------------------------------------------------------------------------
FROM internal-base AS app-src

ENV APP_ENV_DIR="${JULIA_DEPOT_PATH}/environments/app" \
    APP_SRC_DIR="/usr/local/src/app" \
    JULIA_PKG_USE_CLI_GIT=true

# Expect to include the prepped data at /data/app and the config at
# /data/.config.toml
VOLUME ["/data/app"]

# Create an entrypoint script
RUN echo '#!/bin/bash\nexec julia --project=@app -t auto,1 "$@"' > /usr/local/bin/julia-entrypoint.sh && \
    chmod +x /usr/local/bin/julia-entrypoint.sh

# By default, drops the user into a julia shell with ReefGuideWorker activated
ENTRYPOINT ["/usr/local/bin/julia-entrypoint.sh"]

# Derived applications should override the command e.g. to start worker use
CMD ["-e", "using ReefGuideWorker; ReefGuideWorker.start_worker()"]
