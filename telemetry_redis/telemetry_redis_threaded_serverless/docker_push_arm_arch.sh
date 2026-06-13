#!/bin/bash
set -euo pipefail

#IMAGE_NAME="shemathomas/jsontelemetry_pi_perf_arm_new_stracetrial"
IMAGE_NAME="shemathomas/jsontelemetry_pi_perf_arm_new_stracetrial_serverless_n"
BUILD_DIR="$(pwd)"

echo "[INFO] Building and pushing ARM64 Docker image: $IMAGE_NAME"
docker buildx build \
    --platform linux/arm64 \
    -t "${IMAGE_NAME}:latest" \
    "$BUILD_DIR" \
    --push

