# telemetry_generator Dockerfile
FROM ubuntu:22.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Install build and runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    build-essential \
    cmake \
    git \
    libtbb-dev \
    libhiredis-dev \
    ca-certificates \
    nlohmann-json3-dev \
    time \
    bc \
 && rm -rf /var/lib/apt/lists/*

# Install redis++ from source
WORKDIR /tmp
RUN git clone --depth 1 https://github.com/sewenew/redis-plus-plus.git && \
    cd redis-plus-plus && mkdir build && cd build && \
    cmake .. && make -j"$(nproc)" && make install && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/redis++.conf && ldconfig

# Set working directory for the generator app
WORKDIR /app_generate_data

# Copy the telemetry generator source code
COPY telemetry_generator.cpp .

# Compile telemetry generator
RUN g++ telemetry_generator.cpp -o telemetry_generator \
    -std=c++17 \
    -ltbb -lhiredis -lredis++ \
    -I/usr/local/include \
    -L/usr/local/lib \
    -pthread

# Make an optional run script executable (if you have one)
# COPY app_generate_data/run_generator.sh .
# RUN chmod +x run_generator.sh

# Default command: run the generator with default args
CMD ["./telemetry_generator", "1000", "1"]

