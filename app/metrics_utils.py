import csv
import os

def write_metrics(results, filename="generation_metrics.csv"):
    """
    Write metrics (list of dicts) to a CSV file.

    Each dict should have keys: 'file' and 'latency'.
    """
    file_exists = os.path.isfile(filename)

    with open(filename, mode='a', newline='') as csvfile:
        fieldnames = ['file', 'latency']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        if not file_exists:
            writer.writeheader()

        for result in results:
            writer.writerow({
                'file': os.path.basename(result.get('file', '')),
                'latency': result.get('latency', 0)
            })

