import os
import glob
import json
import ijson
import numpy as np
from multiprocessing import Process, Queue, cpu_count


output_dir = os.path.join(os.getcwd(), "data", "output")
os.makedirs(output_dir, exist_ok=True)


def compute_stats(messages, key):
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
            "spectrum": [],
            "mean": None,
            "std_dev": None,
            "min": None,
            "max": None
        }

    times, values = zip(*sorted(zip(times, values)))
    times = np.array(times)
    values = np.array(values)
    times -= times[0]

    uniform_times = np.linspace(0, times[-1], num=len(times))
    values_interp = np.interp(uniform_times, times, values)

    signal = (values_interp - np.mean(values_interp)) / (np.std(values_interp) + 1e-8)

    spectrum = np.fft.fft(signal)
    freqs = np.fft.fftfreq(len(signal), d=(uniform_times[1] - uniform_times[0]))

    positive_freqs = freqs[freqs > 0]
    magnitudes = np.abs(spectrum[freqs > 0])
    dominant_freq = float(positive_freqs[np.argmax(magnitudes)]) if len(magnitudes) > 0 else None

    return {
        "dominant_freq_hz": dominant_freq,
        "spectrum": magnitudes[:10].tolist(),
        "mean": float(np.mean(values)),
        "std_dev": float(np.std(values)),
        "min": float(np.min(values)),
        "max": float(np.max(values))
    }


def process_messages(messages, num_workers=cpu_count()):
    input_queue = Queue()
    output_queue = Queue()
    results = {}

    workers = []
    for _ in range(num_workers):
        p = Process(target=worker, args=(input_queue, output_queue))
        p.start()
        workers.append(p)

    input_queue.put((0, messages))
    for _ in workers:
        input_queue.put(None)

    while len(results) < 1:
        batch_id, result = output_queue.get()
        results[f"batch_{batch_id}"] = result

    for p in workers:
        p.join()

    return results


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
    with open(filename, "rb") as f:
        messages = list(ijson.items(f, 'item'))

    results = process_messages(messages, num_workers)

    output_filename = os.path.basename(filename).replace(".json", "_output.json")
    output_path = os.path.join(output_dir, output_filename)
    with open(output_path, "w") as out_f:
        json.dump(results, out_f, indent=2)

    print(f"[INFO] Processed {filename}, results saved to {output_path}")


def process_all_files(core_count, threaded=False):
    filepaths = glob.glob(os.path.join(output_dir, "telemetry_*.json"))

    if threaded:
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
        for filepath in filepaths:
            print(f"[INFO] Processing {filepath} sequentially")
            process_file_multiproc(filepath, core_count)
        print("[INFO] All files processed sequentially.")


def main():
    core_count = int(os.environ.get("CORE_COUNT", 1))
    threaded = os.environ.get("THREADED", "false").lower() == "true"
    workload_mode = os.environ.get("WORKLOAD_MODE", "native_st").lower()

    # Ignore redis, always process local files
    print("[INFO] Native mode – processing from local filesystem")
    process_all_files(core_count, threaded)


if __name__ == "__main__":
    main()

