# Use lightweight Python base image
FROM python:3.10-slim

# Set working directory inside container
WORKDIR /app

# Copy project files
COPY app/ /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Set default command
CMD ["python", "main.py"]

