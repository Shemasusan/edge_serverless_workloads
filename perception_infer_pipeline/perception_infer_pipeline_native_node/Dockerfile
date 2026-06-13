FROM nvcr.io/nvidia/deepstream-l4t:7.1-triton-multiarch

# ------------------------------------------------------------
# Install Nsight Compute CLI (ncu) + dependencies
# ------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nsight-compute \
        nsight-compute-cli \
        python3 python3-pip python3-venv \
        curl wget nano vim git \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav && \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Set up working directory
# ------------------------------------------------------------
WORKDIR /workspace

# ------------------------------------------------------------
# Copy your pipeline code
# ------------------------------------------------------------
COPY run_scripts/run_deepstream_json.py /workspace/run_deepstream_json.py
COPY configs /workspace/configs

# Optional: if you use custom DeepStream parsers / plugins
# COPY custom_libs/*.so /opt/nvidia/deepstream/deepstream-7.1/lib/

# ------------------------------------------------------------
# Install Python dependencies for your script
# ------------------------------------------------------------
RUN pip3 install --no-cache-dir \
    urllib3 \
    requests

# ------------------------------------------------------------
# Default environment for DeepStream
# ------------------------------------------------------------
ENV DS_PATH=/opt/nvidia/deepstream/deepstream-7.1
ENV LD_LIBRARY_PATH="$DS_PATH/lib:$DS_PATH/lib/gst-plugins:$LD_LIBRARY_PATH"
ENV GST_PLUGIN_PATH="$DS_PATH/lib/gst-plugins:$GST_PLUGIN_PATH"
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "/workspace/run_deepstream_json.py"]

