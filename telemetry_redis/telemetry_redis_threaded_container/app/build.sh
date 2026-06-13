#!/bin/bash
set -e

# Compile processor.cpp into processor binary with FFTW threads support
g++ -std=c++17 -o processor processor.cpp \
    -lhiredis -lredis++ -lfftw3 -lfftw3_threads -ltbb -lpthread

