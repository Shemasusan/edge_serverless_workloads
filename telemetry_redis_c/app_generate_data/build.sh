#!/bin/bash
set -e
g++ -std=c++17 -O2 -o telemetry_generator telemetry_generator.cpp \
    -lhiredis -lpthread -luuid

