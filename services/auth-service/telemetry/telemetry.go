// Package telemetry — inicialização do OpenTelemetry para serviços Go
// ===================================================================
//
// Este pacote provê uma função `Init` que:
//   1. Configura um TracerProvider apontando para o OTel Collector via OTLP/HTTP
//   2. Configura um MeterProvider que envia métricas via OTLP E expõe
//      /metrics em :9464 (formato Prometheus) — backup para o caso do
//      OTel Collector cair.
//   3. Retorna um http.Handler que é um WRAPPER do mux original adicionando
//      spans automáticos a cada request (otelhttp middleware).
//
// Por que separar do main.go?
//   - O auth-service e o evaluation-service compartilham EXATAMENTE a mesma
//     lógica de bootstrap. Em vez de copiar 80 linhas no main.go de cada
//     um, isolamos aqui. Cada serviço importa "./telemetry" do seu próprio
//     contexto de build.
//
// Variáveis de ambiente respeitadas:
//   OTEL_SERVICE_NAME            — nome do serviço (ex: auth-service)
//   OTEL_EXPORTER_OTLP_ENDPOINT  — endpoint do coletor (default OTLP http)
//   DISABLE_OTEL=true            — desliga TODA a instrumentação (debug local)
package telemetry

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/exporters/prometheus"
	metricapi "go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Shutdown é a função retornada por Init para flush final dos buffers.
// Chame-a em defer no main(). Sem isso, spans em buffer NÃO chegam ao
// coletor quando o processo termina (kill, SIGTERM no rolling update).
type Shutdown func(context.Context) error

// noopShutdown é o que retornamos quando OTel está desligado.
func noopShutdown(context.Context) error { return nil }

// Init prepara o OTel para um serviço Go.
//
// Retornos:
//   - shutdown: função de cleanup
//   - error:    se a inicialização falhar (não fatal — ver chamadas no main)
func Init(ctx context.Context, serviceName string) (Shutdown, error) {
	if os.Getenv("DISABLE_OTEL") == "true" {
		log.Println("OpenTelemetry desabilitado via DISABLE_OTEL=true")
		return noopShutdown, nil
	}

	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "otel-opentelemetry-collector.observability.svc.cluster.local:4318"
	}
	// As libs OTel esperam "host:port" SEM esquema. Tiramos se vier por engano.
	endpoint = stripScheme(endpoint)

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(envOr("SERVICE_VERSION", "1.0.0")),
			semconv.DeploymentEnvironment(envOr("DEPLOYMENT_ENV", "production")),
			semconv.ServiceNamespace("togglemaster"),
		),
		resource.WithFromEnv(),
		resource.WithProcess(),
		resource.WithHost(),
	)
	if err != nil {
		return noopShutdown, err
	}

	// -------- Traces --------
	traceExp, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(endpoint),
		otlptracehttp.WithInsecure(), // dentro do cluster, mTLS não é necessário
	)
	if err != nil {
		return noopShutdown, err
	}
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithBatcher(traceExp,
			sdktrace.WithBatchTimeout(5*time.Second),
			sdktrace.WithMaxExportBatchSize(512),
		),
	)
	otel.SetTracerProvider(tracerProvider)

	// Propagator: W3C TraceContext (padrão de mercado) + Baggage
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// -------- Metrics --------
	// 2 leitores:
	//  a) OTLP -> Collector -> Prometheus/Datadog
	//  b) /metrics local (Prometheus scrape direto, fallback)
	metricExp, err := otlpmetrichttp.New(ctx,
		otlpmetrichttp.WithEndpoint(endpoint),
		otlpmetrichttp.WithInsecure(),
	)
	if err != nil {
		return noopShutdown, err
	}
	promReader, err := prometheus.New()
	if err != nil {
		return noopShutdown, err
	}
	meterProvider := metric.NewMeterProvider(
		metric.WithResource(res),
		metric.WithReader(promReader),
		metric.WithReader(metric.NewPeriodicReader(metricExp,
			metric.WithInterval(30*time.Second),
		)),
	)
	otel.SetMeterProvider(meterProvider)

	// Sobe o /metrics em :9464 numa goroutine (parecido com o prometheus-client)
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttpHandler())
		s := &http.Server{
			Addr:              ":9464",
			Handler:           mux,
			ReadHeaderTimeout: 5 * time.Second,
		}
		log.Println("Prometheus /metrics escutando em :9464")
		if err := s.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("Erro no servidor de métricas: %v", err)
		}
	}()

	log.Printf("OpenTelemetry inicializado para %q (endpoint=%s)", serviceName, endpoint)

	shutdown := func(ctx context.Context) error {
		// Importante: chamar AMBOS para fazer flush final
		_ = tracerProvider.Shutdown(ctx)
		_ = meterProvider.Shutdown(ctx)
		return nil
	}
	return shutdown, nil
}

// WrapHandler embrulha um http.Handler com:
//  1) o middleware otelhttp (gera spans para o tracing distribuído / Service Map)
//  2) um middleware de MÉTRICAS CUSTOMIZADAS com nomes DETERMINÍSTICOS
//     (http_requests_total e http_request_duration_seconds), idênticos aos
//     emitidos pelos serviços Python. Sem isso, o otelhttp emitiria
//     `http.server.request.duration` cuja tradução para Prometheus é
//     imprevisível entre versões, e os alertas/dashboard ficariam vazios.
func WrapHandler(handler http.Handler, serverName string) http.Handler {
	meter := otel.GetMeterProvider().Meter("togglemaster.http")

	// Counter: Prometheus adiciona o sufixo `_total` -> http_requests_total
	requestsTotal, _ := meter.Int64Counter(
		"http_requests",
		metricapi.WithDescription("Total de requisições HTTP processadas"),
		metricapi.WithUnit("1"),
	)
	// Histogram em segundos, com buckets explícitos adequados a uma API web
	requestDuration, _ := meter.Float64Histogram(
		"http_request_duration_seconds",
		metricapi.WithDescription("Duração das requisições HTTP em segundos"),
		metricapi.WithUnit("s"),
		metricapi.WithExplicitBucketBoundaries(
			0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5,
			0.75, 1.0, 2.0, 5.0, 10.0,
		),
	)

	serviceName := envOr("OTEL_SERVICE_NAME", serverName)

	metricsMiddleware := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			// Captura o status code via ResponseWriter wrapper
			rw := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rw, r)
			elapsed := time.Since(start).Seconds()

			attrs := metricapi.WithAttributes(
				attribute.String("service", serviceName),
				attribute.String("http_request_method", r.Method),
				attribute.String("http_route", r.URL.Path),
			)
			statusAttrs := metricapi.WithAttributes(
				attribute.String("service", serviceName),
				attribute.String("http_request_method", r.Method),
				attribute.String("http_route", r.URL.Path),
				attribute.String("http_response_status_code", strconv.Itoa(rw.status)),
			)
			requestsTotal.Add(r.Context(), 1, statusAttrs)
			requestDuration.Record(r.Context(), elapsed, attrs)
		})
	}

	// Ordem: otelhttp por fora (cria o span raiz), métricas por dentro.
	return otelhttp.NewHandler(metricsMiddleware(handler), serverName)
}

// statusRecorder captura o status code escrito pelo handler, para podermos
// rotular a métrica http_requests_total com http_response_status_code.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// WrapTransport embrulha o http.RoundTripper para que chamadas HTTP DE SAÍDA
// propaguem o trace context (header `traceparent` do W3C) para o próximo
// serviço. É a metade "client" do tracing distribuído — sem isso, cada
// serviço cria seu próprio trace isolado e o Service Map fica desconexo.
func WrapTransport(base http.RoundTripper) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return otelhttp.NewTransport(base)
}

// --- helpers ---

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func stripScheme(s string) string {
	for _, p := range []string{"http://", "https://"} {
		if len(s) > len(p) && s[:len(p)] == p {
			return s[len(p):]
		}
	}
	return s
}
