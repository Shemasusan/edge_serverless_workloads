import os
import time
import uuid
import json
from multiprocessing import Process, Queue
from app_generate_data.simulator import generate_sensor_data
from app.metrics_utils import write_metrics
from app.utils import ensure_dir

output_dir = os.path.join(os.getcwd(), "data", "output")
ensure_dir(output_dir)

def generate_file(proc_id, record_count, queue=None):
    start = time.time()
    filename = os.path.join(output_dir, f"telemetry_{proc_id}_{uuid.uuid4().hex}.json")

    generate_sensor_data(record_count, filename)
    latency = round(time.time() - start, 3)

    # No Redis upload, keep files locally

    if queue is not None:
        queue.put({"file": filename, "gen_latency": latency})

def run_sequential(record_count, files_to_generate):
    for i in range(files_to_generate):
        generate_file(i, record_count)
    print("[INFO] Sequential generation done.")

def run_parallel(record_count, files_to_generate):
    queue = Queue()
    processes = []

    for i in range(files_to_generate):
        p = Process(target=generate_file, args=(i, record_count, queue))
        p.start()
        processes.append(p)

    for p in processes:
        p.join()

    results = []
    while not queue.empty():
        results.append(queue.get())

    write_metrics(results)
    print("[INFO] Parallel generation done.")

def main():
    record_count = int(os.environ.get("COUNT", 1000))
    files_to_generate = int(os.environ.get("FILES_TO_GENERATE", 1))
    threaded = os.environ.get("THREADED", "false").lower() == "true"

    if threaded:
        run_parallel(record_count, files_to_generate)
    else:
        run_sequential(record_count, files_to_generate)

if __name__ == "__main__":
    main()

