module evaluation-service

go 1.25

require (
	github.com/aws/aws-sdk-go-v2 v1.30.5
	github.com/aws/aws-sdk-go-v2/config v1.27.33
	github.com/aws/aws-sdk-go-v2/credentials v1.17.33
	github.com/aws/aws-sdk-go-v2/service/sqs v1.34.6
	github.com/joho/godotenv v1.5.1
	github.com/redis/go-redis/v9 v9.7.3

	// ===== OpenTelemetry (Fase 4) =====
	github.com/prometheus/client_golang v1.20.5
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.55.0
	go.opentelemetry.io/otel v1.30.0
	go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp v1.30.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.30.0
	go.opentelemetry.io/otel/exporters/prometheus v0.52.0
	go.opentelemetry.io/otel/sdk v1.30.0
	go.opentelemetry.io/otel/sdk/metric v1.30.0
)
