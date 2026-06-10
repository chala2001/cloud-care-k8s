FROM python:3.12-slim

WORKDIR /app

# Install dependencies first (layer caching — only rebuilds if requirements.txt changes)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ app/

EXPOSE 8001

# Use uvicorn with one worker per container (Kubernetes handles horizontal scaling)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]