FROM python:3.9-slim

WORKDIR /app

# Install requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files
COPY app/ ./app/
COPY models/ ./models/
COPY data/ ./data/

CMD ["python", "app/main.py"]

