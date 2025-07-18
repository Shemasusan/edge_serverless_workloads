import os
import uuid
import time
from simulator import generate_sensor_data
from processor import process_data
from utils import unique_filename

def run_once(n):
    filename = f"telemetry_{uuid.uuid4().hex}.json"
    generate_sensor_data(n, filename)
    process_data(filename)

def run_looped(interval_min=5):
    counter = 100
    while True:
        filename = f"telemetry_{uuid.uuid4().hex}.json"
        print(f"Generating {counter} datapoints to {filename}")
        generate_sensor_data(counter, filename)
        process_data(filename)
        counter += 100
        time.sleep(interval_min * 60)

def run_batch(filename, batch_size, max_points):
    process_data(filename, batch_size=batch_size, max_points=max_points)

if __name__ == "__main__":
    filename = unique_filename()
    generate_sensor_data(count, filename)
    mode = os.environ.get("MODE", "once")
    count = int(os.environ.get("COUNT", "1000"))
    interval_min = int(os.environ.get("INTERVAL_MIN", "5"))
    batch_size = int(os.environ.get("BATCH_SIZE", "100"))
    max_points = int(os.environ.get("MAX_POINTS", "1000"))
    input_file = os.environ.get("INPUT_FILE", "telemetry.json")

    if mode == "once":
        run_once(count)
    elif mode == "loop":
        run_looped(interval_min)
    elif mode == "batch":
        run_batch(input_file, batch_size, max_points)
    else:
        raise ValueError("Invalid MODE. Use 'once', 'loop', or 'batch'.")

