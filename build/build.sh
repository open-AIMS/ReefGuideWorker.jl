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

# See gcc-with-lm.sh for why this wrapper is needed (shared with the
# Dockerfile's app-juliac-builder stage via the same JULIA_CC mechanism).
JULIA_CC="$SCRIPT_DIR/gcc-with-lm.sh" \
time juliac --verbose --project="$PROJECT_ROOT" --output-exe reefguide-worker \
    --bundle "$OUTPUT_DIR" --experimental "$ENTRY_FILE" \
    2>&1 | tee "$BUILD_LOG"
