#!/bin/bash

# Script to run the ReefGuide worker container
# Usage: ./run-worker.sh <sysimage_directory> <sysimage_name>

set -e

# Check if required arguments are provided
if [ $# -lt 3 ]; then
    echo "Usage: $0 <sysimage_directory> <sysimage_name> <container_name>"
    echo "Example: $0 ./sysimages reefguide_img.so worker"
    exit 1
fi

SYSIMAGE_DIR="$1"
SYSIMAGE_NAME="$2"
CONTAINER_NAME="$3"

# Check if sysimage directory exists
if [ ! -d "$SYSIMAGE_DIR" ]; then
    echo "Error: System image directory not found at $SYSIMAGE_DIR"
    exit 1
fi

# Check if sysimage file exists in the directory
if [ ! -f "$SYSIMAGE_DIR/$SYSIMAGE_NAME" ]; then
    echo "Error: System image file $SYSIMAGE_NAME not found in $SYSIMAGE_DIR"
    exit 1
fi

echo "Starting ReefGuide worker container..."
echo "System image directory: $SYSIMAGE_DIR"
echo "System image file: $SYSIMAGE_NAME"
echo "Worker container name: $CONTAINER_NAME"

# Run the container
docker run \
    -v "$SYSIMAGE_DIR:/data" \
    --entrypoint julia \
    ${CONTAINER_NAME} \
    --project=@app \
    -J "/data/$SYSIMAGE_NAME" \
    --sysimage-native-code=yes \
    -e "using ReefGuideWorker; ReefGuideWorker.start_worker()"

echo "Container $CONTAINER_NAME started successfully!"
echo "To view logs: docker logs $CONTAINER_NAME"
echo "To stop: docker stop $CONTAINER_NAME"
echo "To remove: docker rm $CONTAINER_NAME"
