FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app

# Create non-root system user
RUN useradd --system --uid 10001 --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code, services, and static UI assets
COPY app.py .
COPY services/ ./services/
COPY static/ ./static/

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "-k", "uvicorn.workers.UvicornWorker", "--keep-alive", "65", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
