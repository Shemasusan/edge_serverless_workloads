#!/bin/bash
sudo systemctl restart docker
MODE=$1
if [[ -z "$MODE" ]]; then
  echo "Usage: $0 <mode>"
  echo "Example: $0 _mt"
  exit 1
fi

# Sanitize mode for tag (replace underscores with hyphens if desired)
TAG_MODE=${MODE//_/-}
IMAGE_NAME="shemathomas/jsontelemetry_c_trial"
BUILD_DIR="$(pwd)"

echo "[INFO] Building and pushing Docker image: $IMAGE_NAME"
echo "[INFO] Build context: $BUILD_DIR"

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --network=host \
  -t $IMAGE_NAME:latest \
  -t $IMAGE_NAME:$(date +%Y%m%d%H%M) \
  --push \
  "$BUILD_DIR"

echo "[DONE] Image pushed: $IMAGE_NAME:latest and with timestamp tag"

