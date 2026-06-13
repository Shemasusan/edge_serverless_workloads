# Use ARM64 Ubuntu 22.04 base image
FROM arm64v8/ubuntu:22.04

# Set environment variables to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Update and install dependencies
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
    redis-tools \
    lua5.1 \
    liblua5.1-0-dev \
    luarocks \
    && rm -rf /var/lib/apt/lists/*

# Install lua-cjson via LuaRocks
RUN luarocks install lua-cjson

# Install redis++ from source
WORKDIR /tmp
RUN git clone --depth 1 https://github.com/sewenew/redis-plus-plus.git && \
    cd redis-plus-plus && mkdir build && cd build && \
    cmake .. && make -j2 && make install && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/redis++.conf && ldconfig

# Set working directory for your app
WORKDIR /app
RUN mkdir -p /app/data

# Copy source code and scripts
COPY app/processor.cpp .
COPY app/httplib.h .
COPY run_entrypoint.sh .

# Compile processor
RUN g++ processor.cpp -o processor \
    -std=c++17 \
    -ltbb -lfftw3 -lfftw3_threads -lhiredis -lredis++ \
    -I/usr/local/include \
    -L/usr/local/lib \
    -pthread

# Make run script executable
RUN chmod +x run_entrypoint.sh

# Default command
CMD ["./run_entrypoint.sh"]

