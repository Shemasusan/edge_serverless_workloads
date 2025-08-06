from multiprocessing import Process, Queue, cpu_count
import json
import os
from collections import OrderedDict
from app.utils import ensure_dir
import ijson

output_dir = os.path.join(os.getcwd(), "data", "output")
ensure_dir(output_dir)

import numpy as np

def compute_stats(messages, key):
    # Safely collect numeric values and timestamps
    values = []
    times = []
    for m in messages:
        try:
            v = float(m[key])
            t = float(m["timestamp"])
            values.append(v)
            times.append(t)
        except (KeyError, TypeError, ValueError):
            continue

    if len(values) < 2:
        return {
            "dominant_freq_hz": None,
            "spectrum": []
        }

    # Sort by timestamp
    times, values = zip(*sorted(zip(times, values)))
    times = np.array(times)
    values = np.array(values)

    # Normalize time to start at 0
    times -= times[0]

    # Resample to uniform grid
    uniform_times = np.linspace(0, times[-1], num=len(times))
    values_interp = np.interp(uniform_times, times, values)

    # Normalize signal
    signal = (values_interp - np.mean(values_interp)) / (np.std(values_interp) + 1e-8)

    # FFT
    spectrum = np.fft.fft(signal)
    freqs = np.fft.fftfreq(len(signal), d=(uniform_times[1] - uniform_times[0]))

    # Keep only positive freqs
    positive_freqs = freqs[freqs > 0]
    magnitudes = np.abs(spectrum[freqs > 0])

    if len(magnitudes) == 0:
        return {
            "dominant_freq_hz": None,
            "spectrum": []
        }

    dominant_freq = float(positive_freqs[np.argmax(magnitudes)])
    return {
        "dominant_freq_hz": dominant_freq,
        "spectrum": magnitudes[:10].tolist()  # include top 10 spectrum magnitudes
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

