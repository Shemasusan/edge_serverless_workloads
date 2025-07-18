import json
from concurrent.futures import ThreadPoolExecutor

def compute_stats(messages, key):
    values = [m[key] for m in messages]
    return {
        "min": min(values),
        "max": max(values),
        "mean": sum(values) / len(values)
    }

def process_message(message_id, message):
    stats = {
        "temperature": compute_stats([message], "temperature"),
        "humidity": compute_stats([message], "humidity")
    }
    return (message_id, stats)

if __name__ == "__main__":
    with open("telemetry.json", "r") as f:
        messages = json.load(f)

    results = {}
    with ThreadPoolExecutor() as executor:
        futures = [executor.submit(process_message, i, msg) for i, msg in enumerate(messages)]
        for future in futures:
            message_id, stats = future.result()
            results[message_id] = stats

    # Optionally, aggregate all individual message stats here if needed
    # For now, just write the per-message stats
    with open("output.json", "w") as out:
        json.dump(results, out, indent=2)

