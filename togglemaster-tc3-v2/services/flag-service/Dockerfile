# Stage 1: Build (instala dependências)
FROM python:3.11-slim AS builder

WORKDIR /app

# Copiar dependências primeiro
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# Stage 2: Runtime
FROM python:3.11-slim

WORKDIR /app

# Instalar curl para healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Copiar código da aplicação
COPY . .

# Copiar dependências do builder
COPY --from=builder /root/.local /root/.local

# Ajustar PATH para encontrar os pacotes instalados
ENV PATH=/root/.local/bin:$PATH

# Expor a porta
EXPOSE 8002

# Comando de inicialização
CMD ["python", "app.py"]

# Healthcheck — porta 8002 (flag-service)
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8002/health || exit 1
