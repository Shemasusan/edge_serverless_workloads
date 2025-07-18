#!/bin/bash
set -e

echo "Building and pushing multi-arch Docker image..."

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --network=host \
  -t shemathomas/mobilenet-infer-local:latest \
  --push \
  .

echo "Build and push complete!"

