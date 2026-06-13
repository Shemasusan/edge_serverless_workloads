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
    libfftw3-dev \
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

# Set working directory for your app
WORKDIR /app

# Copy source code and scripts
COPY app/processor.cpp .
COPY app/httplib.h .
COPY run_local_for_container.sh .

# Compile processor
RUN g++ processor.cpp -o processor \
    -std=c++17 \
    -ltbb -lfftw3 -lhiredis -lredis++ \
    -I/usr/local/include \
    -L/usr/local/lib \
    -pthread

# Make run script executable
RUN chmod +x run_local_for_container.sh

# Default command
CMD ["./run_local_for_container.sh"]

