# generate_video_from_images.py
import os
import subprocess
import argparse

def generate_video(image_dir, output_video="output.mp4", fps=10):
    """
    Converts sequentially numbered PNGs into an MP4 video.
    """
    # Clean up ._ files (Mac resource forks)
    for f in os.listdir(image_dir):
        if f.startswith("._"):
            os.remove(os.path.join(image_dir, f))
    
    # Ensure files are sorted numerically
    pattern = os.path.join(image_dir, "%010d.png")  # KITTI format: 0000000000.png
    cmd = [
        "ffmpeg", "-y", "-framerate", str(fps),
        "-i", pattern,
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        output_video
    ]
    print(f"[INFO] Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)
    print(f"[SUCCESS] Video saved to {output_video}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input_dir", required=True, help="Path to image folder")
    parser.add_argument("--output", default="output.mp4", help="Output video file name")
    parser.add_argument("--fps", type=int, default=10, help="Frames per second")
    args = parser.parse_args()

    generate_video(args.input_dir, args.output, args.fps)

