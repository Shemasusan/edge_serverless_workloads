from PIL import Image
import numpy as np
import io

def preprocess(image_bytes):
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    image = image.resize((224, 224))
    img_data = np.array(image).astype("float32") / 255.0
    img_data = img_data.transpose(2, 0, 1)  # CHW
    img_data = np.expand_dims(img_data, axis=0)  # NCHW
    return img_data

def load_labels(label_path):
    with open(label_path, "r") as f:
        return [line.strip() for line in f.readlines()]

