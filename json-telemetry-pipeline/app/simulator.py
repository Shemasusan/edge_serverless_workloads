import json
import random
import time

def generate_sensor_data(n, filename):
    data = []
    for _ in range(n):
        message = {
            "device_id": random.randint(1000, 1100),
            "temperature": round(random.uniform(20.0, 80.0), 2),
            "humidity": round(random.uniform(30.0, 90.0), 2),
            "timestamp": time.time()
        }
        data.append(message)

    with open(filename, "w") as f:
        json.dump(data, f)

