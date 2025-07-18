FROM python:3.10-slim

WORKDIR /app_c

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .
COPY mobilenetv2-10.onnx .
COPY mobilenetv2-12-qdq.onnx .
COPY imagenet_classes.txt .
COPY input_file.txt .

ENTRYPOINT ["python", "inference.py"]

