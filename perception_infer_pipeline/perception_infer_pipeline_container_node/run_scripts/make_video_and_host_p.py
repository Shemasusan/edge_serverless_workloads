#!/usr/bin/env python3
import os
import subprocess
import socket
import http.server
import socketserver
import threading
import argparse

# ------------------------------
# Step 1: Convert PNGs to MP4
# ------------------------------
def generate_video(image_dir, output_video="output.mp4", fps=10):
    """
    Converts sequentially numbered PNGs into an MP4 video using FFmpeg.
    """
    # Clean up Mac metadata files
    for f in os.listdir(image_dir):
        if f.startswith("._"):
            os.remove(os.path.join(image_dir, f))
    
    pattern = os.path.join(image_dir, "%010d.png")  # KITTI-style numbering
    cmd = [
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", pattern,
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        output_video
    ]
    print(f"[INFO] Running FFmpeg: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)
    print(f"[SUCCESS] Video generated: {output_video}")
    return os.path.abspath(output_video)

# ------------------------------
# Step 2: Utility to get local IP
# ------------------------------
def get_local_ip():
    """
    Finds the local IP address (used for DeepStream URI).
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

# ------------------------------
# Step 3: Fast threaded HTTP server with Range support
# ------------------------------
def start_http_server(port=8080):
    """
    Starts a threaded HTTP server that supports HTTP range requests
    (enables fast seeking for MP4 video playback).
    """
    class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
        def send_head(self):
            path = self.translate_path(self.path)
            try:
                f = open(path, 'rb')
            except OSError:
                self.send_error(404, "File not found")
                return None

            fs = os.fstat(f.fileno())
            ctype = self.guess_type(path)

            # Handle Range header for partial content
            range_header = self.headers.get('Range')
            if range_header:
                start, end = range_header.replace('bytes=', '').split('-')
                start = int(start)
                end = int(end) if end else fs.st_size - 1
                self.send_response(206)
                self.send_header("Content-type", ctype)
                self.send_header("Content-Range", f"bytes {start}-{end}/{fs.st_size}")
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                f.seek(start)
                self.copyfile(f, self.wfile)
                f.close()
                return None
            else:
                self.send_response(200)
                self.send_header("Content-type", ctype)
                self.send_header("Content-Length", str(fs.st_size))
                self.send_header("Accept-Ranges", "bytes")
                self.end_headers()
                return f

    class ReusableTCPServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True

    httpd = ReusableTCPServer(("", port), RangeRequestHandler)
    print(f"[INFO] Fast threaded HTTP server running on port {port} (CTRL+C to stop)...")

    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd

# ------------------------------
# Step 4: Main execution
# ------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert image folder to MP4 and host via HTTP.")
    parser.add_argument("--input_dir", required=True, help="Path to image folder")
    parser.add_argument("--output", default="output.mp4", help="Output video file name")
    parser.add_argument("--fps", type=int, default=10, help="Frames per second for video")
    parser.add_argument("--port", type=int, default=8080, help="Port for HTTP server")
    args = parser.parse_args()

    # Step 1: Generate video
    video_path = generate_video(args.input_dir, args.output, args.fps)
    
    # Step 2: Start HTTP server
    httpd = start_http_server(args.port)
    
    # Step 3: Compute and print URL
    local_ip = get_local_ip()
    video_name = os.path.basename(video_path)
    url = f"http://{local_ip}:{args.port}/{video_name}"
    print("\n VIDEO URL:", url)
    print("\nAdd to your DeepStream config as:")
    print(f"[source0]\nenable=1\ntype=3\nuri={url}\n")

    # Save URL for DeepStream automation
    with open("/tmp/video_url.txt", "w") as f:
        f.write(url + "\n")

    # Step 4: Keep alive
    try:
        while True:
            pass
    except KeyboardInterrupt:
        print("\n[INFO] Shutting down server...")
        httpd.shutdown()

