import requests
from PIL import Image
import numpy as np
import onnxruntime as ort
import platform
import io
from utils import preprocess, load_labels

def run_inference_from_file(input_file="input_file.txt"):
    arch = platform.machine()
    model_path = "mobilenetv2-12-qdq.onnx" if arch == "aarch64" else "mobilenetv2-10.onnx"

    session = ort.InferenceSession(model_path)
    labels = load_labels("imagenet_classes.txt")

    with open(input_file, 'r') as f:
        urls = [line.strip() for line in f if line.strip()]

    for idx, url in enumerate(urls):
        try:
            print(f"\n Fetching {idx+1}/{len(urls)}: {url}")
            response = requests.get(url, timeout=10)
            response.raise_for_status()

            input_tensor = preprocess(response.content)
            outputs = session.run(None, {session.get_inputs()[0].name: input_tensor})
            prediction = int(np.argmax(outputs[0]))

            print(f" Prediction: class_id={prediction}, label={labels[prediction]}")
        except Exception as e:
            print(f" Error on {url}: {e}")

if __name__ == "__main__":
    run_inference_from_file()




