# Stage 1: Build (instala dependências)
FROM python:3.11-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# Stage 2: Runtime
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY . .

COPY --from=builder /root/.local /root/.local

ENV PATH=/root/.local/bin:$PATH

EXPOSE 8003

CMD ["python", "app.py"]

# Healthcheck — porta 8003 (targeting-service)
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8003/health || exit 1
