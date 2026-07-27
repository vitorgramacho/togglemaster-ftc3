
import logging
import os

log = logging.getLogger(__name__)

def init_telemetry(flask_app=None, service_name: str | None = None) -> None:
    
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

        try:
            start_http_server(port=9464, addr="0.0.0.0")
        except OSError as e:
            log.warning(
                "porta 9464 indisponível (outro worker do gunicorn já a expõe); "
                "seguindo sem /metrics neste worker: %s", e
            )

        # OTLP para o coletor a cada 30s
        otlp_reader = PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=f"{endpoint}/v1/metrics"),
            export_interval_millis=30_000,
        )

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

    import time
    from flask import request
    from opentelemetry import metrics

    meter = metrics.get_meter("togglemaster.http", "1.0.0")

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
