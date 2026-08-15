# See https://hub.docker.com/_/julia for valid versions.
ARG JULIA_VERSION="1.12.6"

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

# Copy project and manifest - includes Manifest-v1.12 etc
COPY Project.toml Manifest*.toml ./

# SentryIntegration.jl fork is not on Julia registry, requiring this step
RUN julia --project=@app \
    -e 'using Pkg; Pkg.add(url="https://github.com/toolpath/SentryIntegration.jl", rev="main");'

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

# Julia thread pool size. `-t`/`--threads` would take precedence over this and
# is deliberately NOT passed on the command line, so this is the only knob:
# derive it from the deployment's actual vCPU allocation (ECS task definition
# environment, docker run -e, etc.) rather than letting Julia's `-t auto`
# infer it from the host cgroup, which does not reflect a Fargate task's CFS
# quota at fractional/low vCPU allocations. The default below (4 worker
# threads, 1 interactive) is only a fallback for ad-hoc/local use.
ENV JULIA_NUM_THREADS="4,1"

# By default, drops the user into a julia shell with ReefGuideWorker activated
ENTRYPOINT ["julia", "--project=@app", "-e"]

# Derived applications should override the command e.g. to start
CMD ["using ReefGuideWorker; ReefGuideWorker.start_worker()"]

#------------------------------------------------------------------------------
# app-juliac-builder build target: compiles ReefGuideWorker.jl into a
# standalone executable via `juliac --bundle` (no --trim). See
# build/build.sh and .claude/plans/ReefGuide-compilation.md §5.2. Reuses
# app-src's already-precompiled @app environment rather than reinstantiating.
#------------------------------------------------------------------------------
FROM app-src AS app-juliac-builder

# JuliaC's link step shells out to `gcc`/`clang`, neither of which
# internal-base installs (it's not needed to just run Julia). Only this
# builder stage needs it -- app-src ships as its own image target and
# app-juliac's final runtime stage is deliberately not based on this one.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    apt-get update \
    && apt-get install --no-install-recommends -y gcc

# The `juliac` on PATH in the base julia image is just the bare
# contrib/juliac.jl script shipped with Julia, which has neither --bundle
# nor --project support. The CLI our build/build.sh relies on (mirroring
# Kora.jl/build/build.sh) is actually provided by the separate `JuliaC`
# package (https://github.com/JuliaLang/JuliaC.jl, registered in General),
# installed as a Julia 1.12 Pkg App. Install it here and put its shim on
# PATH, overriding the stdlib script of the same name.
RUN julia -e 'using Pkg; Pkg.Apps.add("JuliaC")'
ENV PATH="${JULIA_DEPOT_PATH}/bin:${PATH}"

# Only what juliac actually needs -- build.sh/push.sh are for local dev/CI
# invocation, not used inside this stage (which reimplements the juliac
# invocation directly, so it can reuse app-src's already-precompiled @app
# environment rather than shelling out to build.sh's own path resolution).
COPY build/worker_main.jl build/worker_main.jl
COPY build/gcc-with-lm.sh build/gcc-with-lm.sh

# Same JULIA_CPU_TARGET as internal-base, so the compiled executable is
# portable across the deployed x86_64 microarchitectures, not just the
# build host's.
# --project must be an actual directory/Project.toml path here, not the
# `@app` named-environment shorthand: JuliaC's own --project parsing (unlike
# plain `julia --project=@app`) does not resolve `@app` and will fail trying
# to readdir("") if given it verbatim.
#
# See build/gcc-with-lm.sh for why JULIA_CC needs to inject -lm here --
# shared with build.sh's identical local-dev invocation.
RUN mkdir -p /out && \
    chmod +x build/gcc-with-lm.sh && \
    JULIA_CC="$(pwd)/build/gcc-with-lm.sh" \
    juliac --verbose --project="${PRJ_PATH}" --output-exe reefguide-worker \
    --bundle /out --experimental build/worker_main.jl && \
    rm -f /out/*.dll.a

#------------------------------------------------------------------------------
# app-juliac build target: runs the juliac-compiled standalone executable
# directly, no `julia --project=@app -e ...` and no Julia depot/install on
# the target. A/B-tested against app-src via a separate imageTag
# (see infraConfig.ts JuliacConfigurationSchema / infra.ts).
#
# Deliberately FROM debian:bookworm-slim rather than internal-base/app-src:
# the whole point of --bundle is that the target no longer needs a Julia
# install/depot, so basing this on the Julia image would defeat the size
# win. The gdal-bin/libfftw3-dev/openssl/ca-certificates subset below is
# intentionally re-declared (not reused from internal-base) for that
# reason - keep it in sync by hand if internal-base's list changes. Unlike
# internal-base, this stage deliberately omits libgdal-dev: the compiled
# executable only needs GDAL's runtime shared library (pulled in as a
# dependency of gdal-bin), not the dev headers/static libs internal-base
# needs for building/precompiling against GDAL.
#------------------------------------------------------------------------------
FROM debian:bookworm-slim AS app-juliac

RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    apt-get update \
    && apt-get -y upgrade \
    && apt-get install --no-install-recommends -y \
    gdal-bin \
    libfftw3-dev \
    openssl \
    ca-certificates \
    && apt-get clean \
    && apt-get autoremove --purge \
    && rm -rf /var/lib/apt/lists/*

# Expect to include the prepped data at /data/app and the config at
# /data/.config.toml, same as app-src.
VOLUME ["/data/app"]

# See app-src's JULIA_NUM_THREADS comment: same reasoning applies to the
# compiled executable's thread pool.
ENV JULIA_NUM_THREADS="4,1"

COPY --from=app-juliac-builder /out /opt/reefguide-worker

ENTRYPOINT ["/opt/reefguide-worker/bin/reefguide-worker"]
