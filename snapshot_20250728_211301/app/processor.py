from multiprocessing import Process, Queue, cpu_count
import json
import os
from collections import OrderedDict
from app.utils import ensure_dir
import ijson

output_dir = os.path.join(os.getcwd(), "data", "output")
ensure_dir(output_dir)

def compute_stats(messages, key):
    values = [m[key] for m in messages if key in m and isinstance(m[key], (int, float))]
    if not values:
        return {"min": None, "max": None, "mean": None}
    return {
        "min": min(values),
        "max": max(values),
        "mean": sum(values) / len(values)
    }

def worker(input_queue, output_queue):
    while True:
        item = input_queue.get()
        if item is None:
            break
        batch_id, messages = item
        result = {
            "vehicle_count": compute_stats(messages, "vehicle_count"),
            "avg_speed": compute_stats(messages, "avg_speed"),
            "occupancy": compute_stats(messages, "occupancy")
        }
        output_queue.put((batch_id, result))

def process_file_multiproc(filename, num_workers=cpu_count()):
    input_queue = Queue()
    output_queue = Queue()
    results = {}

    workers = []
    for _ in range(num_workers):
        p = Process(target=worker, args=(input_queue, output_queue))
        p.start()
        workers.append(p)

    # Read all messages from file
    with open(filename, "rb") as f:
        messages = list(ijson.items(f, 'item'))

    # Since no batch_size, treat all messages as one batch
    input_queue.put((0, messages))

    # Send termination signals
    for _ in workers:
        input_queue.put(None)

    # Collect results
    while len(results) < 1:
        batch_id, result = output_queue.get()
        results[f"batch_{batch_id}"] = result

    for p in workers:
        p.join()

    # Save output
    output_filename = os.path.basename(filename).replace(".json", "_output.json")
    output_path = os.path.join(output_dir, output_filename)
    with open(output_path, "w") as out_f:
        json.dump(results, out_f, indent=2)

    print(f"[INFO] Processed {filename}, results saved to {output_path}")

