#!/bin/bash
set -e

# Compile processor.cpp into processor binary
g++ -std=c++17 -O2 -o processor processor.cpp \
    -lhiredis -lredis++ -lfftw3 -ltbb -lpthread

