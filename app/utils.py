import uuid
import time
import os

def unique_filename(prefix="telemetry", ext=".json"):
    ts = int(time.time())
    return f"{prefix}_{ts}_{uuid.uuid4().hex[:6]}{ext}"

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
