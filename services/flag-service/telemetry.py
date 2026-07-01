"""
ToggleMaster — Módulo compartilhado de instrumentação OpenTelemetry
====================================================================

Por que um módulo compartilhado em vez de copiar para cada serviço?
- Os 3 serviços Python (flag, targeting, analytics) precisam EXATAMENTE da
  mesma inicialização. Copiar 70 linhas em 3 lugares = 3 lugares para errar.
- Cada serviço importa este módulo no início do seu app.py com
  `from telemetry import init_telemetry`.

O que este módulo faz (em ordem):
1. Lê variáveis de ambiente (OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT)
2. Configura o TracerProvider e MeterProvider apontando para o OTel Collector
3. Auto-instrumenta Flask, Requests, Psycopg2, Botocore (não precisamos
   decorar HANDLER POR HANDLER — a auto-instrumentação injeta spans em
   TODA chamada das libs).
4. Inicia o servidor de métricas Prometheus na porta 9464 (formato compatível
   com `prometheus.io/scrape: true`).

IMPORTANTE: as funções `instrument_*` são idempotentes E podem ser chamadas
SOMENTE depois de criar `app = Flask(__name__)`. Por isso o init_telemetry
recebe o app como parâmetro.
"""

import logging
import os

log = logging.getLogger(__name__)


def init_telemetry(flask_app=None, service_name: str | None = None) -> None:
    """
    Inicializa OpenTelemetry para o microsserviço.

    Parâmetros:
        flask_app:    instância do Flask (ou None se não for um serviço HTTP)
        service_name: nome do serviço; se omitido lê de OTEL_SERVICE_NAME

    Se a env var DISABLE_OTEL=true estiver setada, NADA é feito (útil em
    rodadas locais sem o coletor).
    """
    if os.getenv("DISABLE_OTEL", "false").lower() == "true":
        log.info("OpenTelemetry desabilitado via DISABLE_OTEL=true")
        return

    service_name = service_name or os.getenv("OTEL_SERVICE_NAME", "unknown-service")
    endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://otel-opentelemetry-collector.observability.svc.cluster.local:4318",
    )

    try:
        # --- 1. Resource attributes (vão em TODO span/metric/log) ---
        from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION

        resource = Resource.create({
            SERVICE_NAME: service_name,
            SERVICE_VERSION: os.getenv("SERVICE_VERSION", "1.0.0"),
            "deployment.environment": os.getenv("DEPLOYMENT_ENV", "production"),
            "service.namespace": "togglemaster",
        })

        # --- 2. TracerProvider (traces) ---
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )

        provider = TracerProvider(resource=resource)
        provider.add_span_processor(
            BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces"))
        )
        trace.set_tracer_provider(provider)

        # --- 3. MeterProvider (métricas) ---
        # 2 leitores: 1 que exporta para o Collector via OTLP E outro que
        # expõe /metrics no formato Prometheus na porta 9464. Por que os 2?
        # - OTLP: roteia para Prometheus + Datadog (caminho oficial OTel)
        # - /metrics: backup que funciona MESMO se o coletor cair. Util para
        #   o Prometheus continuar scrapando direto em uma falha do OTel.
        from opentelemetry import metrics
        from opentelemetry.sdk.metrics import MeterProvider
        from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
        from opentelemetry.exporter.otlp.proto.http.metric_exporter import (
            OTLPMetricExporter,
        )
        from opentelemetry.exporter.prometheus import PrometheusMetricReader
        from prometheus_client import start_http_server

        # /metrics na porta 9464 (default do PrometheusMetricReader)
        prom_reader = PrometheusMetricReader()
        start_http_server(port=9464, addr="0.0.0.0")

        # OTLP para o coletor a cada 30s
        otlp_reader = PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=f"{endpoint}/v1/metrics"),
            export_interval_millis=30_000,
        )

        # IMPORTANTE: os buckets DEFAULT do histogram OTel são pensados para
        # MILISSEGUNDOS (0, 5, 10, ..., 10000). Como medimos em SEGUNDOS, sem
        # uma View os buckets ficariam errados e o histogram_quantile do
        # alerta HighLatency (> 2s) daria valores sem sentido. A View abaixo
        # define explicitamente fronteiras em segundos adequadas a uma API web.
        from opentelemetry.sdk.metrics.view import View, ExplicitBucketHistogramAggregation

        latency_view = View(
            instrument_name="http_request_duration_seconds",
            aggregation=ExplicitBucketHistogramAggregation(
                boundaries=[
                    0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5,
                    0.75, 1.0, 2.0, 5.0, 10.0,
                ]
            ),
        )

        meter_provider = MeterProvider(
            resource=resource,
            metric_readers=[prom_reader, otlp_reader],
            views=[latency_view],
        )
        metrics.set_meter_provider(meter_provider)

        # --- 4. Auto-instrumentação ---
        if flask_app is not None:
            from opentelemetry.instrumentation.flask import FlaskInstrumentor
            FlaskInstrumentor().instrument_app(flask_app)
            # IMPORTANTE: além da auto-instrumentação (que gera spans/traces),
            # registramos métricas HTTP CUSTOMIZADAS com nomes DETERMINÍSTICOS.
            #
            # Por quê? A auto-instrumentação do OTel emite `http.server.duration`
            # que, ao passar pelo Prometheus, vira `http_server_duration_milliseconds`
            # (ou variações conforme a versão e a convenção semântica). Esse nome
            # é IMPREVISÍVEL entre versões. Como nossos alertas e o dashboard
            # dependem de um nome ESTÁVEL, criamos as nossas próprias métricas:
            #   - http_requests_total           (counter, com label http_response_status_code)
            #   - http_request_duration_seconds  (histogram, em segundos)
            # Esses nomes batem exatamente com o PromQL em 06-prometheus-rules.yaml.
            _register_flask_http_metrics(flask_app, service_name)

        # Requests (chamadas HTTP de saída — auth-service chama flag-service, etc.)
        try:
            from opentelemetry.instrumentation.requests import RequestsInstrumentor
            RequestsInstrumentor().instrument()
        except ImportError:
            pass

        # Psycopg2 (chamadas a PostgreSQL viram spans automáticos)
        try:
            from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
            Psycopg2Instrumentor().instrument()
        except ImportError:
            pass

        # Boto3/SDK AWS (SQS, DynamoDB do analytics-service)
        try:
            from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
            BotocoreInstrumentor().instrument()
        except ImportError:
            pass

        # Logging: injeta trace_id em todos os logs do Python
        try:
            from opentelemetry.instrumentation.logging import LoggingInstrumentor
            LoggingInstrumentor().instrument(set_logging_format=True)
        except ImportError:
            pass

        log.info(
            "OpenTelemetry inicializado",
            extra={
                "otel_service_name": service_name,
                "otel_endpoint": endpoint,
            },
        )

    except Exception as e:
        # FALHA do OTel JAMAIS pode derrubar a aplicação — log e segue.
        log.error("Falha ao inicializar OpenTelemetry (continuando sem): %s", e)


def _register_flask_http_metrics(flask_app, service_name: str) -> None:
    """
    Registra métricas HTTP customizadas via before_request/after_request do Flask.

    Cria duas métricas com nomes ESTÁVEIS (não dependem da convenção semântica
    do OTel, que varia entre versões):

      http_requests_total
        - tipo: counter
        - labels: service, http_request_method, http_route, http_response_status_code
        - uso: taxa de requisições (RPS) e taxa de erro 5xx

      http_request_duration_seconds
        - tipo: histogram (em SEGUNDOS)
        - labels: service, http_request_method, http_route
        - uso: latência p95 via histogram_quantile

    Esses nomes/labels são EXATAMENTE os que aparecem em:
      - gitops/base/observability/06-prometheus-rules.yaml
      - gitops/base/observability/07-grafana-dashboard.yaml
    """
    import time
    from flask import request
    from opentelemetry import metrics

    meter = metrics.get_meter("togglemaster.http", "1.0.0")

    # NOTA SOBRE NOMES: o exporter Prometheus adiciona AUTOMATICAMENTE o sufixo
    # `_total` a counters e `_bucket/_sum/_count` a histograms. Por isso o
    # counter é criado como "http_requests" (sem _total) — o Prometheus o
    # expõe como "http_requests_total". Se criássemos já com "_total", viraria
    # "http_requests_total_total" (bug conhecido). O histogram vira
    # "http_request_duration_seconds_bucket/_sum/_count".
    requests_total = meter.create_counter(
        name="http_requests",
        description="Total de requisições HTTP processadas",
        unit="1",
    )
    request_duration = meter.create_histogram(
        name="http_request_duration_seconds",
        description="Duração das requisições HTTP em segundos",
        unit="s",
    )

    @flask_app.before_request
    def _start_timer():
        request._otel_start_time = time.perf_counter()

    @flask_app.after_request
    def _record_metrics(response):
        try:
            elapsed = time.perf_counter() - getattr(
                request, "_otel_start_time", time.perf_counter()
            )
            # Usa a rota (regra de URL) e não o path bruto, para evitar
            # explosão de cardinalidade (ex: /flags/<name> em vez de /flags/abc).
            route = request.url_rule.rule if request.url_rule else "unmatched"
            base_attrs = {
                "service": service_name,
                "http_request_method": request.method,
                "http_route": route,
            }
            requests_total.add(
                1,
                {**base_attrs, "http_response_status_code": str(response.status_code)},
            )
            request_duration.record(elapsed, base_attrs)
        except Exception:
            # Nunca deixar a coleta de métrica quebrar a resposta ao usuário
            pass
        return response
