import requests

API_URL = "http://localhost:8000/process"

with open("input.txt") as f:
    urls = [line.strip() for line in f if line.strip()]

for url in urls:
    print(f"[TEST] Processing: {url}")
    try:
        response = requests.get(API_URL, params={"url": url}, timeout=10)
        if response.status_code == 200:
            try:
                data = response.json()
                print(data)
            except ValueError:
                print(f"[ERROR] Response is not valid JSON for {url}: {response.text[:200]}")
        else:
            print(f"[ERROR] Server returned status {response.status_code} for {url}: {response.text[:200]}")
    except Exception as e:
        print(f"[ERROR] Failed to process {url}: {e}")

