#!/usr/bin/env python3
from prometheus_client import Gauge, start_http_server
import subprocess, re

gpu_util = Gauge('gpu_util', 'GPU utilization %')
cpu_util = Gauge('cpu_util', 'CPU utilization %')

def parse_tegrastats(line):
    g = re.search(r'GR3D_FREQ (\d+)%', line)
    c = re.search(r'CPU@(\d+)%', line)
    if g: gpu_util.set(int(g.group(1)))
    if c: cpu_util.set(int(c.group(1)))

# Expose Prometheus metrics on port 9101
start_http_server(9101)

# Continuous loop to read tegrastats
p = subprocess.Popen(['tegrastats', '--interval', '1000'], stdout=subprocess.PIPE)
for l in p.stdout:
    parse_tegrastats(l.decode('utf-8'))

