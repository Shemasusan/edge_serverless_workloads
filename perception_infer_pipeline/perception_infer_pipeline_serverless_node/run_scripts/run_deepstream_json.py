#!/usr/bin/env python3
import json
import time
import subprocess
from pathlib import Path
import re
import os
import sys
import urllib.request

# ---------------- CONFIG ----------------
# Base directory (automatically detects current project folder)
BASE_DIR = Path(__file__).resolve().parents[1]
print(f"[INFO] Using base directory: {BASE_DIR}")
CONFIG_DIR = BASE_DIR / "configs"

DEEPSTREAM_APP = "/opt/nvidia/deepstream/deepstream-7.1/bin/deepstream-app"
CONFIG_FILE = BASE_DIR / "configs/av_app.txt"
DEBUG_DIR = BASE_DIR / "debug_json"
# ---------------- METRICS ----------------
def get_metrics():
    """Return GPU and CPU utilization using tegrastats (Jetson only)."""
    gpu, cpu = 0, 0
    try:
        output = subprocess.check_output(
            ["tegrastats", "--interval", "1000", "--once"]
        ).decode()
        g = re.search(r"GR3D_FREQ (\d+)%", output)
        c = re.search(r"CPU@(\d+)%", output)
        if g:
            gpu = int(g.group(1))
        if c:
            cpu = int(c.group(1))
    except Exception:
        pass
    return gpu, cpu


# ---------------- HELPERS ----------------
def patch_streammux_live(config_path, live):
    """Toggle live-source=1 for HTTP/RTSP sources, 0 for file sources."""
    try:
        with open(config_path) as f:
            lines = f.readlines()
        with open(config_path, "w") as f:
            in_streammux = False
            for line in lines:
                s = line.strip()
                if s.startswith("[streammux]"):
                    in_streammux = True
                    f.write(line)
                    continue
                if in_streammux and s.startswith("[") and s.endswith("]"):
                    in_streammux = False
                if in_streammux and s.startswith("live-source="):
                    f.write(f"live-source={1 if live else 0}\n")
                else:
                    f.write(line)
    except Exception as e:
        print(f"[WARN] Could not patch live-source in streammux: {e}")


# ---------------- MAIN ----------------
def main():
    # Ensure debug directory exists and is empty
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    for f in DEBUG_DIR.glob("*.json"):
        f.unlink()

    print("Starting DeepStream pipeline...")

    # --- Read hosted video URL from make_video_and_host.py ---
    url_file = "/tmp/video_url.txt"
    video_url = None

    if os.path.exists(url_file):
        try:
            with open(url_file) as f:
                video_url = f.read().strip()
            if video_url:
                print(f"[INFO] Using video URL from {url_file}: {video_url}")
            else:
                print(f"[WARN] {url_file} was empty, falling back to local file.")
                video_url = "file:///home/camsin-nano/perception_infer_pipeline/output.mp4"
        except Exception as e:
            print(f"[WARN] Failed to read {url_file}: {e}")
            video_url = "file:///home/camsin-nano/perception_infer_pipeline/output.mp4"
    else:
        print(f"[WARN] {url_file} not found, using local file.")
        video_url = "file:///home/camsin-nano/perception_infer_pipeline/output.mp4"

    # --- Wait until HTTP server is ready if using network stream ---
    if video_url.startswith("http://"):
        print(f"[WAIT] Checking if video host is reachable at {video_url} ...")
        for i in range(10):  # wait up to 10 seconds
            try:
                with urllib.request.urlopen(video_url, timeout=2) as response:
                    if response.status in (200, 206):
                        print(f"[READY] Video host is reachable.")
                        break
            except Exception:
                print(f"[WAIT] Host not ready yet (attempt {i+1}/10)...")
                time.sleep(1)
        else:
            print(f"[WARN] HTTP host did not respond — falling back to local file.")
            video_url = "file:///home/camsin-nano/perception_infer_pipeline/output.mp4"

    # --- Determine live/file mode ---
    if video_url.startswith("http://192.168."):
        is_live = False
    else:
        is_live = video_url.startswith("http://") or video_url.startswith("rtsp://")

    patch_streammux_live(CONFIG_FILE, is_live)
    print(f"[INFO] Patched streammux live-source={'1 (live)' if is_live else '0 (file)'}")


    # --- Prepare environment for DeepStream ---
    env = os.environ.copy()
    ds_path = "/opt/nvidia/deepstream/deepstream-7.1"
    env["LD_LIBRARY_PATH"] = f"{ds_path}/lib:{ds_path}/lib/gst-plugins:" + env.get("LD_LIBRARY_PATH", "")
    env["GST_PLUGIN_PATH"] = f"{ds_path}/lib/gst-plugins:" + env.get("GST_PLUGIN_PATH", "")

    # --- Launch DeepStream ---
    print(f"[INFO] Launching DeepStream with source: {video_url}")
    cmd = f"bash -c '{DEEPSTREAM_APP} -c {CONFIG_FILE}'"
#    proc = subprocess.Popen(cmd, shell=True, env=env)
    proc = subprocess.Popen(cmd, shell=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    seen = set()
    try:
        while True:
            # ---- Check if DeepStream exited ----
            if proc.poll() is not None:
                print("\n[INFO] DeepStream process exited.")
                break

            # ---- Parse new JSON output ----
            json_files = sorted(DEBUG_DIR.glob("*.json"))
            for path in json_files:
                if path in seen:
                    continue
                seen.add(path)
                try:
                    with open(path) as f:
                        content = f.read().strip()
                        if not content:
                            continue

                        try:
                            data = json.loads(content)
                            gpu, cpu = get_metrics()
                            data["gpu_util"] = gpu
                            data["cpu_util"] = cpu
                            print(json.dumps(data, indent=2))
                        except json.JSONDecodeError:
                            for line in content.splitlines():
                                line = line.strip()
                                if not line:
                                    continue
                                data = json.loads(line)
                                gpu, cpu = get_metrics()
                                data["gpu_util"] = gpu
                                data["cpu_util"] = cpu
                                print(json.dumps(data, indent=2))
                except Exception as e:
                    print(f"[WARN] Could not parse {path.name}: {e}")

            time.sleep(0.5)

        # ---- Wait for final termination ----
        ret = proc.wait()
        print(f"[INFO] DeepStream exited with code {ret}")
        print("[INFO] App run successful — exiting main loop.")
        sys.exit(ret)

    except KeyboardInterrupt:
        print("\n[INFO] Keyboard interrupt — stopping DeepStream pipeline...")
        proc.terminate()
        proc.wait()
        print("[INFO] Pipeline stopped.")
        sys.exit(0)


# ---------------- ENTRYPOINT ----------------
if __name__ == "__main__":
    main()

