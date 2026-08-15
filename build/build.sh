#!/usr/bin/env bash
# build/build.sh -- Compile ReefGuideWorker.jl into a standalone executable via juliac.
#
# Usage (from the ReefGuideWorker.jl root):
#   ./build/build.sh
#
# Mode:
#   bundled (only mode currently supported) juliac --output-exe --bundle ->
#       standalone reefguide-worker executable + bundled libjulia, stdlibs,
#       and artifacts (GDAL etc.). No Julia install/depot required on the
#       target. No --trim: see .claude/plans/ReefGuide-compilation.md §2/§5.2
#       for why untrimmed is the near-term target, not --trim=safe.
#
# Overridable env vars:
#   REEFGUIDE_WORKER_DIST_DIR  output directory (default: build/dist/bundled
#                              inside the ReefGuideWorker.jl root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENTRY_FILE="$SCRIPT_DIR/worker_main.jl"

OUTPUT_DIR="${REEFGUIDE_WORKER_DIST_DIR:-$PROJECT_ROOT/build/dist/bundled}"
mkdir -p "$OUTPUT_DIR"

# Multi-target CPU dispatch, matching the Dockerfile's JULIA_CPU_TARGET, so
# the compiled executable is portable across the x86_64 microarchitectures
# actually deployed to (rather than compiling for only the build host's CPU).
export JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

BUILD_LOG="$OUTPUT_DIR/build.log"
echo "Mode: bundled (libjulia, stdlibs, and artifacts bundled via --bundle, no --trim)"
echo "Build log: $BUILD_LOG"

# JuliaC only adds -lm on i686; on x86_64, floorf becomes a libcall to libm
# and the link fails ("undefined reference to floorf@@GLIBC" / "DSO missing
# from command line"). Wrap the compiler via JULIA_CC to inject -lm
# unconditionally -- same workaround already verified in
# Kora.jl/build/build.sh's `worker` mode.
_GCC_WRAPPER="$(mktemp /tmp/gcc-wrapper-XXXXXX.sh)"
printf '#!/bin/sh\nexec gcc "$@" -lm\n' > "$_GCC_WRAPPER"
chmod +x "$_GCC_WRAPPER"
JULIA_CC="$_GCC_WRAPPER" \
time juliac --verbose --project="$PROJECT_ROOT" --output-exe reefguide-worker \
    --bundle "$OUTPUT_DIR" --experimental "$ENTRY_FILE" \
    2>&1 | tee "$BUILD_LOG"
rm -f "$_GCC_WRAPPER"

# Remove import library (.dll.a) -- not needed for distribution
for f in "$OUTPUT_DIR"/*.dll.a; do
    [[ -e "$f" ]] || continue
    rm -f "$f"
    echo "Removed $(basename "$f")"
done
