"""
Traffic Sensor Data Generator

This script simulates realistic traffic sensor data in JSON format for edge workloads.
It mimics common traffic telemetry fields such as vehicle count, average speed, and occupancy.

Inspired by public traffic datasets like Caltrans PeMS:
DOI: https://doi.org/10.5281/zenodo.3939050
"""

import json
import random
import time
import os

def generate_sensor_data(n, filename):
    """
    Generate synthetic traffic sensor data and save it to a JSON file.

    Parameters:
    - n (int): Number of telemetry records to generate.
    - filename (str): Output filename to save the generated JSON data.
    """
    # Ensure the directory for filename exists
    os.makedirs(os.path.dirname(filename), exist_ok=True)

    data = []
    sensor_ids = [1001, 1002, 1003]  # Simulated traffic sensor IDs

    for _ in range(n):
        message = {
            "sensor_id": random.choice(sensor_ids),
            "vehicle_count": random.randint(0, 20),
            "avg_speed": round(random.uniform(0, 120), 1),
            "occupancy": round(random.uniform(0, 100), 1),
            "timestamp": time.time()
        }
        data.append(message)

    with open(filename, "w") as f:
        json.dump(data, f, indent=2)

