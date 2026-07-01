# =============================================================================
# Imagem mínima para o pod self-healing-webhook
# ---------------------------------------------------------------------------
# Tudo o que precisa: Python 3.11 + cliente Kubernetes oficial.
# NÃO embarcamos kubectl/curl porque a comunicação com o K8s API server é
# feita via biblioteca + token do ServiceAccount (in-cluster auth).
# =============================================================================
FROM python:3.11-slim

WORKDIR /app

# pip-install antes do COPY do código pra aproveitar cache do build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Usuário não-root (boas práticas de container)
RUN groupadd -r app && useradd -r -g app -d /app app \
    && chown -R app:app /app

COPY --chown=app:app main.py .

USER app

EXPOSE 8080

# `python -u` força stdout unbuffered -> logs aparecem imediatamente no Loki
CMD ["python", "-u", "main.py"]

# Health check do próprio container (independente do K8s probe)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request, sys; urllib.request.urlopen('http://localhost:8080/health', timeout=2); sys.exit(0)" || exit 1
