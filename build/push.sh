#!/usr/bin/env bash
# build/push.sh -- Push a locally built ReefGuideWorker.jl image to GHCR.
#
# Usage (from the ReefGuideWorker.jl root):
#   ./build/push.sh <local-image> <ghcr-tag>
#
# Requires `docker login ghcr.io` beforehand, with a PAT that has
# `write:packages` scope and push access to the open-aims org -- this
# script does not handle authentication.
#
# Example:
#   docker build --target app-juliac -t reefguide-worker:juliac-test .
#   ./build/push.sh reefguide-worker:juliac-test juliac-test
#
#   # then in the deploy config:
#   #   workers.reefguide.imageTag = "juliac-test"
#   #   workers.reefguide.juliac = true

set -euo pipefail

IMAGE_REPO="ghcr.io/open-aims/reefguideworker.jl/reefguide-worker"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <local-image> <ghcr-tag>" >&2
    exit 1
fi

LOCAL_IMAGE="$1"
GHCR_TAG="$2"
REMOTE="${IMAGE_REPO}:${GHCR_TAG}"

docker tag "$LOCAL_IMAGE" "$REMOTE"
docker push "$REMOTE"
echo "Pushed $REMOTE"
