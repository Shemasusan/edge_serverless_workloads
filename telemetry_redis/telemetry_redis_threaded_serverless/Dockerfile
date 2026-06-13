# Use ARM64 Ubuntu 24.04 base image (GLIBC 2.38)
FROM arm64v8/ubuntu:24.04

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
    wget \
    texinfo \
    gawk \
    && rm -rf /var/lib/apt/lists/*

# Install lua-cjson via LuaRocks
RUN luarocks install lua-cjson

# Install redis++ from source
WORKDIR /tmp
RUN git clone --depth 1 https://github.com/sewenew/redis-plus-plus.git && \
    cd redis-plus-plus && mkdir build && cd build && \
    cmake .. && make -j2 && make install && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/redis++.conf && ldconfig && \
    cd / && rm -rf /tmp/redis-plus-plus

# Install perf dependencies
# If you need host-matching perf, mount it in: 
#   docker run -v /usr/lib/linux-tools-$(uname -r):/usr/lib/linux-tools-$(uname -r) ...
RUN apt-get update && apt-get install -y --no-install-recommends \
    libelf-dev \
    libunwind-dev \
    libdw-dev \
    libnuma-dev \
    libslang2 \
    python3 \
    libpython3-dev \
    libtraceevent-dev \
    && rm -rf /var/lib/apt/lists/*

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

# Default command (runs entrypoint script)
CMD ["/app/run_entrypoint.sh"]

