
import os
import requests
from PIL import Image
import numpy as np
import onnxruntime as ort
import platform
import io
from utils import preprocess, load_labels

def run_inference_from_env():
    arch = platform.machine()
    model_path = "models/mobilenetv2-12-qdq.onnx" if arch == "aarch64" else "models/mobilenetv2-10.onnx"

    session = ort.InferenceSession(model_path)
    labels = load_labels("data/imagenet_classes.txt")

    image_urls = os.getenv("IMAGE_URLS", "")
    urls = [url.strip() for url in image_urls.split(",") if url.strip()]
    if not urls:
        print("No IMAGE_URLS provided. Set the environment variable.")
        return

    for idx, url in enumerate(urls):
        try:
            print(f"[{idx+1}/{len(urls)}] Fetching: {url}")
            if url.startswith("file://"):
                with open(url[7:], "rb") as img_f:
                    image_bytes = img_f.read()
            else:
                response = requests.get(url, timeout=10)
                response.raise_for_status()
                image_bytes = response.content

            input_tensor = preprocess(image_bytes)
            outputs = session.run(None, {session.get_inputs()[0].name: input_tensor})
            prediction = int(np.argmax(outputs[0]))

            print(f"Prediction: class_id={prediction}, label={labels[prediction]}")
        except Exception as e:
            print(f"Error on {url}: {e}")

if __name__ == "__main__":
    run_inference_from_env()
