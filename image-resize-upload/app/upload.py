import cv2
import requests

def upload_image(image):
    # Simulate upload by POSTing to dummy endpoint (you can use http://httpbin.org/post)
    _, buf = cv2.imencode('.jpg', image)
    response = requests.post("http://httpbin.org/post", files={"file": buf.tobytes()})
    return "success" if response.status_code == 200 else "fail"

