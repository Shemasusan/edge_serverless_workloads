import requests
import cv2
import numpy as np

def download_and_resize(url):
    resp = requests.get(url, timeout=5)
    img_arr = np.asarray(bytearray(resp.content), dtype=np.uint8)
    img = cv2.imdecode(img_arr, cv2.IMREAD_COLOR)
    
    if img is None:
        raise ValueError(f"Failed to decode image from URL: {url}")
    
    resized = cv2.resize(img, (224, 224))
    return resp.content, resized

