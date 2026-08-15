#!/bin/sh
# Wraps gcc to unconditionally inject -lm, working around JuliaC's linker
# only adding -lm on i686 (on x86_64, floorf becomes a libcall to libm and
# the link fails with "undefined reference to floorf@@GLIBC" / "DSO missing
# from command line" -- see linking.jl's get_compiler_cmd). Shared by
# build/build.sh (local dev) and the Dockerfile's app-juliac-builder stage
# (CI/production) via JULIA_CC, so the workaround only needs updating in one
# place. Same fix already verified in Kora.jl/build/build.sh's worker mode.
exec gcc "$@" -lm
