import json
from utils import ensure_dir

ensure_dir("/data/output")
def compute_stats(messages, key):
    values = [m[key] for m in messages]
    return {
        "min": min(values),
        "max": max(values),
        "mean": sum(values) / len(values)
    }

def process_data(filename, batch_size=None, max_points=None):
    with open(filename, "r") as f:
        messages = json.load(f)

    if max_points:
        messages = messages[:max_points]

    results = {}
    if batch_size:
        for i in range(0, len(messages), batch_size):
            batch = messages[i:i+batch_size]
            results[f"batch_{i//batch_size}"] = {
                "temperature": compute_stats(batch, "temperature"),
                "humidity": compute_stats(batch, "humidity")
            }
    else:
        results["all"] = {
            "temperature": compute_stats(messages, "temperature"),
            "humidity": compute_stats(messages, "humidity")
        }

    output_file = filename.replace(".json", "_output.json")
    with open(output_file, "w") as out:
        json.dump(results, out, indent=2)

