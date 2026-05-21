# =============================================================================
# Dockerfile — flag-service (Python 3.11)
#
# Correções aplicadas:
#  - Pacotes instalados em /app/.local (não /root/.local) via --prefix.
#  - Usuário não-root (app:app) no runtime — corrige gosec/Trivy HIGH.
#  - CMD usa gunicorn com 2 workers e graceful timeout.
# =============================================================================

# Stage 1: Build
FROM python:3.11-slim AS builder

WORKDIR /app

COPY requirements.txt .
# Instala para /app/.local para ser copiado para o runtime como usuário não-root.
RUN pip install --no-cache-dir --prefix=/app/.local -r requirements.txt

# Stage 2: Runtime
FROM python:3.11-slim

WORKDIR /app

# Instalar curl apenas para healthcheck (sem cache de listas apt).
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r app && useradd -r -g app -d /app app \
    && chown -R app:app /app

# Copiar dependências instaladas pelo builder.
COPY --from=builder --chown=app:app /app/.local /app/.local

# Copiar código da aplicação.
COPY --chown=app:app . .

ENV PATH=/app/.local/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER app

EXPOSE 8002

# gunicorn: 2 workers síncronos, graceful timeout 30s.
CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "2", \
     "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", "app:app"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8002/health || exit 1
