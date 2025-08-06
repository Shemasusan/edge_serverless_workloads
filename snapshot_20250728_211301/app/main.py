import os
import time
import uuid
import glob
from multiprocessing import Process, Queue
from app.simulator import generate_sensor_data
from app.processor import process_file_multiproc
from app.metrics_utils import write_metrics
from app.utils import ensure_dir

output_dir = os.path.join(os.getcwd(), "data", "output")
ensure_dir(output_dir)

def generate_worker(proc_id, record_count, queue):
    start = time.time()
    filename = os.path.join(output_dir, f"telemetry_{proc_id}_{uuid.uuid4().hex}.json")
    generate_sensor_data(record_count, filename)
    latency = round(time.time() - start, 3)
    queue.put({"file": filename, "latency": latency})

def run_sequential(record_count, files_to_generate):
    results = []
    for i in range(files_to_generate):
        start = time.time()
        filename = os.path.join(output_dir, f"telemetry_{i}_{uuid.uuid4().hex}.json")
        generate_sensor_data(record_count, filename)
        latency = round(time.time() - start, 3)
        results.append({"file": filename, "latency": latency})
    write_metrics(results)

def run_parallel(record_count, core_count):
    queue = Queue()
    processes = []
    for i in range(core_count):
        p = Process(target=generate_worker, args=(i, record_count, queue))
        p.start()
        processes.append(p)

    for p in processes:
        p.join()

    results = []
    while not queue.empty():
        results.append(queue.get())
    write_metrics(results)

def process_all_files(core_count, threaded=False):
    output_dir = os.path.join(os.getcwd(), "data", "output")
    filepaths = glob.glob(os.path.join(output_dir, "telemetry_*.json"))

    print("[INFO] Starting processing of generated files...")

    if threaded:
        # 🔁 Parallel: Each file is handled in a separate process
        procs = []
        for filepath in filepaths:
            print(f"[INFO] Launching process for {filepath}")
            p = Process(target=process_file_multiproc, args=(filepath, core_count))
            p.start()
            procs.append(p)

        for p in procs:
            p.join()

        print("[INFO] All files processed in parallel.")
    else:
        # 🚶 Sequential: One file at a time
        for filepath in filepaths:
            print(f"[INFO] Processing {filepath} sequentially")
            process_file_multiproc(filepath, core_count)

        print("[INFO] All files processed sequentially.")

def main():
    record_count = int(os.environ.get("COUNT", 1000))
    core_count = int(os.environ.get("CORE_COUNT", 1))
    files_to_generate = int(os.environ.get("FILES_TO_GENERATE", 1))
    threaded = os.environ.get("THREADED", "false").lower() == "true"

    # Generate files
    if threaded:
        run_parallel(record_count, core_count)
    else:
        run_sequential(record_count, files_to_generate)

    # Now call the processing function
    process_all_files(core_count, threaded)

if __name__ == "__main__":
    main()

