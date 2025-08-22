#!/bin/bash
set -e

IMAGE_NAME="shemathomas/jsontelemetry_generator"

echo "[INFO] Restarting Docker..."
sudo systemctl restart docker

echo "[INFO] Building Docker image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

echo "[INFO] Pushing image to Docker Hub: $IMAGE_NAME"
docker push "$IMAGE_NAME"

echo "[INFO] Done."

