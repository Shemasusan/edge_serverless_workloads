# Edge Serverless Workloads

This repository contains a collection of serverless workloads and example applications designed for deployment on edge computing environments. It demonstrates how to run lightweight, scalable, and event-driven workloads such as image processing, telemetry pipelines, and machine learning inference at the network edge.

---

## Repository Structure

- **generated-yamls/**  
  Contains Kubernetes YAML configuration files for deploying workloads and services.

- **image-resize-upload/**  
  Implements an image processing pipeline that downloads, resizes, and uploads images. Ideal for real-time image manipulation at the edge.

- **json-telemetry-pipeline/**  
  A telemetry data pipeline for generating, processing, and analyzing JSON-based telemetry data streams.

- **mobilenet-infer/**  
  Containerized MobileNet-based machine learning inference workloads for edge devices.

- **mobilenet-infer-local/**  
  Local version of MobileNet inference, useful for development and testing without containerization.

---

## Technologies Used

- **Python** — Main programming language for workload logic.
- **Docker** — Containerizes workloads for easy deployment.
- **Kubernetes (K3s)** — Lightweight Kubernetes used for orchestration at the edge.
- **FastAPI** — Web framework used for APIs in some workloads.
- **ONNX / TensorFlow Lite** — Machine learning model formats for edge inference.

---

## Getting Started

### Prerequisites

- Docker
- Kubernetes (e.g., K3s for edge environments)
- Python 3.8+
- `kubectl` CLI for managing Kubernetes deployments

### Build and Run

1. Clone the repository:
   ```bash
   git clone https://github.com/Shemasusan/edge_serverless_workloads.git
   cd edge_serverless_workloads
2. Build Docker images (example for MobileNet inference):
cd mobilenet-infer
docker buildx build   --platform linux/amd64,linux/arm64   --network=host   -t mobilenet-infer:latest   --push . 
3. Deploy workloads using the provided YAML files:
kubectl apply -f generated-yamls/
