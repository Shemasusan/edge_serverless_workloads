# Find header path (usually /opt/nvidia/deepstream/deepstream/sources/includes)
INC_PATH=/opt/nvidia/deepstream/deepstream/sources/includes

# Compile shared object
sudo gcc -Wall -fPIC -shared libnvds_msgbroker_proto_file.c \
    -I${INC_PATH} \
    -o /opt/nvidia/deepstream/deepstream/lib/libnvds_msgbroker_proto_file.so
