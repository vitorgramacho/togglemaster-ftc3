
FROM python:3.11-slim

WORKDIR /app


COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt


RUN groupadd -r -g 10001 app && useradd -r -u 10001 -g app -d /app app \
    && chown -R app:app /app

COPY --chown=app:app main.py .


USER 10001

EXPOSE 8080

# `python -u` força stdout unbuffered -> logs aparecem imediatamente no Loki
CMD ["python", "-u", "main.py"]

# Health check do próprio container (independente do K8s probe)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request, sys; urllib.request.urlopen('http://localhost:8080/health', timeout=2); sys.exit(0)" || exit 1
